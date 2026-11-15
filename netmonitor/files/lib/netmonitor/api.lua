-- ubus method implementations (served by /usr/libexec/rpcd/netmonitor).
-- env = { cfg, now, rundir?, db_file?, fsops?, statfs?, runner?, saver?, uci_get? }
local config = require 'netmonitor.config'
local collector = require 'netmonitor.collector'
local db = require 'netmonitor.db'
local disk = require 'netmonitor.disk'
local timeutil = require 'netmonitor.timeutil'
local topology = require 'netmonitor.topology'
local detail = require 'netmonitor.detail'
local asn = require 'netmonitor.asn'
local service = require 'netmonitor.service'
local json = require 'netmonitor.json'
local rollup = require 'netmonitor.rollup'

local M = {}

M.DEFAULT_ROWS_PER_DAY = 50000
M.DEFAULT_ROW_BYTES = 120
M.CLOCK_SANE_AFTER = 1704067200 -- 2024-01-01; earlier means NTP has not synced

local function db_file(env)
	if env.db_file then return env.db_file end
	if not env.cfg.db_path or env.cfg.db_path == '' then return nil end
	return disk.db_file(env.cfg.db_path)
end

local function have_db(env)
	local f = db_file(env)
	return f and db.exists(f), f
end

local function file_size(path)
	local f = io.open(path, 'r')
	if not f then return 0 end
	local s = f:seek('end')
	f:close()
	return s or 0
end

local function q(path, sql)
	local rows, err = db.query(path, sql)
	if not rows then error({ code = 'db_error', detail = err }) end
	return rows
end

-- Collector state from its run file; stale state means the daemon is down.
function M.runtime(env)
	local st = collector.read_state(env.rundir) or { state = 'stopped' }
	local iv = tonumber(st.interval) or env.cfg.interval
	if st.state == 'running' or st.state == 'disk_pause' then
		if env.now - (tonumber(st.updated) or 0) > 3 * iv + 10 then
			st.state = 'stopped'
			st.stale = true
		end
	end
	return st
end

local function live_view(st)
	local out = { devices = {}, pairs = {} }
	if st.state ~= 'running' and st.state ~= 'disk_pause' then return out end
	for mac, v in pairs(st.live or {}) do out.devices[mac] = v end
	for _, p in ipairs(st.live_pairs or {}) do out.pairs[p] = true end
	return out
end

local function resolve(env, args)
	local key = (args and args.range) or '1h'
	local since, err = timeutil.resolve_range(key, env.now, env.cfg)
	if not since then
		return nil, { error = err, range = key,
			allowed_ranges = timeutil.allowed_ranges(env.now, env.cfg) }
	end
	return since, key
end

-- Short TTL cache: overview used to call topology+devices in parallel, each
-- scanning the same multi-hour sample range (~10s). LuCI RPC budget is ~20s.
local pair_cache = { key = nil, at = 0, rows = nil }
local PAIR_CACHE_TTL = 8

local function pair_rows(path, since)
	local ck = tostring(path) .. '\0' .. tostring(since)
	local now = os.time()
	if pair_cache.key == ck and pair_cache.rows and (now - pair_cache.at) < PAIR_CACHE_TTL then
		return pair_cache.rows
	end
	-- Prefer domain/service displays; never use ASN org as the display name.
	local rows = q(path, string.format([[
SELECT s.device, s.target, s.up, s.down, d.ip, d.hostname,
  COALESCE(
    CASE WHEN t.source IN ('dns','sni','http_host','service') THEN t.display END,
    CASE WHEN n.source IN ('dns','sni','http_host','service') THEN n.name END,
    CASE WHEN n2.source IN ('dns','sni','http_host','service') THEN n2.name END,
    CASE WHEN t.source = 'asn' THEN COALESCE(t.ip, s.target) END,
    t.display, s.target
  ) AS display,
  CASE
    WHEN t.source IN ('dns','sni','http_host','service','asn') THEN 0
    WHEN n.source IN ('dns','sni','http_host','service','asn') THEN 0
    WHEN n2.source IN ('dns','sni','http_host','service','asn') THEN 0
    WHEN t.unresolved = 0 THEN 0
    ELSE 1
  END AS unresolved,
  COALESCE(
    CASE WHEN t.source IN ('dns','sni','http_host','service','asn') THEN t.source END,
    CASE WHEN n.source IN ('dns','sni','http_host','service','asn') THEN n.source END,
    CASE WHEN n2.source IN ('dns','sni','http_host','service','asn') THEN n2.source END,
    t.source, 'ip'
  ) AS source,
  COALESCE(
    CASE WHEN n.source = 'asn' THEN n.name END,
    CASE WHEN n2.source = 'asn' THEN n2.name END
  ) AS asn_org
FROM (SELECT device, target, SUM(bytes_up) AS up, SUM(bytes_down) AS down
      FROM traffic_samples INDEXED BY idx_samples_ts_device_target
      WHERE ts >= %s GROUP BY device, target) s
LEFT JOIN devices d ON d.mac = s.device
LEFT JOIN targets t ON t.key = s.target
LEFT JOIN ip_names n ON n.ip = s.target
LEFT JOIN ip_names n2 ON t.ip IS NOT NULL AND n2.ip = t.ip;]], db.quote(since)))
	pair_cache.key, pair_cache.at, pair_cache.rows = ck, now, rows
	return rows
end

local function rows_to_info(pair)
	local rows, info = {}, { devices = {}, targets = {} }
	for _, r in ipairs(pair) do
		rows[#rows + 1] = { device = r.device, target = r.target,
			up = tonumber(r.up) or 0, down = tonumber(r.down) or 0 }
		info.devices[r.device] = { ip = r.ip, hostname = r.hostname }
		info.targets[r.target] = { display = r.display, unresolved = tonumber(r.unresolved),
			source = r.source or ((tonumber(r.unresolved) == 1) and 'ip' or 'dns'),
			asn_org = r.asn_org }
	end
	return rows, info
end

-- Include devices with in-range last_seen even when they have zero samples (F3 / A8).
local function devices_from_pairs(path, since, pair, live)
	local per, top = {}, {}
	for _, r in ipairs(pair) do
		local p = per[r.device] or { up = 0, down = 0 }
		local up, down = tonumber(r.up) or 0, tonumber(r.down) or 0
		p.up, p.down = p.up + up, p.down + down
		per[r.device] = p
		local t = top[r.device]
		if not t or up + down > t.bytes then
			top[r.device] = { bytes = up + down, display = r.display or r.target }
		end
	end
	local qs = db.quote(since)
	local known = q(path, 'SELECT mac, ip, hostname, last_seen FROM devices WHERE last_seen >= '
		.. qs .. ' OR mac IN (SELECT DISTINCT device FROM traffic_samples WHERE ts >= '
		.. qs .. ');')
	local rows = {}
	for _, d in ipairs(known) do
		local p = per[d.mac] or { up = 0, down = 0 }
		rows[#rows + 1] = {
			mac = d.mac, ip = d.ip, hostname = d.hostname, last_seen = d.last_seen,
			bytes_up = p.up, bytes_down = p.down,
			top_target = top[d.mac] and top[d.mac].display,
		}
	end
	return topology.devices(rows, live)
end

local function storage_stats(path)
	local r = q(path, 'SELECT COUNT(*) AS n FROM traffic_samples;')[1] or {}
	local n = tonumber(r.n) or 0
	local size = file_size(path) + file_size(path .. '-wal') + file_size(path .. '-shm')
	local bpr = (n > 1000) and size / n or M.DEFAULT_ROW_BYTES
	return { rows = n, db_bytes = size, row_bytes = bpr }
end

function M.status(args, env)
	local cfg = env.cfg
	local st = M.runtime(env)
	local out = {
		state = st.state,
		degraded = st.degraded == true,
		degraded_reason = st.degraded_reason,
		error = st.error,
		warnings = json.array(),
		db_path = cfg.db_path,
		interval = cfg.interval,
		idle_gap = cfg.idle_gap,
		retention_value = cfg.retention_value,
		retention_unit = cfg.retention_unit,
		allowed_ranges = timeutil.allowed_ranges(env.now, cfg),
		now = env.now,
		today = timeutil.day_key(env.now),
		current_month = timeutil.month_key(env.now),
		clock_unsynced = env.now < M.CLOCK_SANE_AFTER,
		disk = st.disk,
	}
	for _, w in ipairs(st.warnings or {}) do out.warnings[#out.warnings + 1] = w end
	if cfg.db_path == '' then
		out.state = 'need_wizard'
		return out
	end
	local exists, path = have_db(env)
	if exists then
		-- Main DB + SQLite WAL/SHM sidecar files (actual on-disk footprint).
		out.db_bytes = file_size(path) + file_size(path .. '-wal') + file_size(path .. '-shm')
	end
	if not out.disk then
		local chk = disk.check(cfg.db_path, cfg, env.statfs)
		if chk.total then out.disk = chk end
	end
	local uget = env.uci_get or function(k)
		local p = io.popen('uci -q get ' .. k .. ' 2>/dev/null')
		local v = p and p:read('*l')
		if p then p:close() end
		return v
	end
	if uget('firewall.@defaults[0].flow_offloading') == '1' then
		out.warnings[#out.warnings + 1] = 'flow_offloading'
	end
	-- DNS log runtime health (F6): missing log → attribution falls back to IP.
	local dns_mod = require 'netmonitor.dns'
	local dh = dns_mod.health(cfg.dns_log)
	if not dh.ok and dh.warning then
		local dup = false
		for _, w in ipairs(out.warnings) do if w == dh.warning then dup = true end end
		if not dup then out.warnings[#out.warnings + 1] = dh.warning end
	end
	out.sni = st.sni or { enabled = (tonumber(cfg.sni_enable) or 1) ~= 0,
		available = false, mode = 'dns_only' }
	if out.sni.enabled and not out.sni.available then
		local dup = false
		for _, w in ipairs(out.warnings) do if w == 'sni_unavailable' then dup = true end end
		if not dup then out.warnings[#out.warnings + 1] = 'sni_unavailable' end
	end
	out.asn = st.asn or asn.status(nil, cfg)
	if out.asn.enabled and not out.asn.available then
		local dup = false
		for _, w in ipairs(out.warnings) do if w == 'asn_unavailable' then dup = true end end
		if not dup then out.warnings[#out.warnings + 1] = 'asn_unavailable' end
	end
	if out.asn.update and out.asn.update.state == 'error' then
		local dup = false
		for _, w in ipairs(out.warnings) do if w == 'asn_update_failed' then dup = true end end
		if not dup then out.warnings[#out.warnings + 1] = 'asn_update_failed' end
	end
	out.service = st.service or service.status(nil, cfg)
	if out.service.enabled and not out.service.available then
		local dup = false
		for _, w in ipairs(out.warnings) do if w == 'service_unavailable' then dup = true end end
		if not dup then out.warnings[#out.warnings + 1] = 'service_unavailable' end
	end
	if out.service.update and out.service.update.state == 'error' then
		local dup = false
		for _, w in ipairs(out.warnings) do if w == 'service_update_failed' then dup = true end end
		if not dup then out.warnings[#out.warnings + 1] = 'service_update_failed' end
	end
	return out
end

function M.topology(args, env)
	local since, key = resolve(env, args)
	if not since then return key end
	local exists, path = have_db(env)
	local rows, info = {}, { devices = {}, targets = {} }
	local stats
	if exists then
		rows, info = rows_to_info(pair_rows(path, since))
		local c = q(path, 'SELECT COUNT(*) AS n FROM traffic_samples WHERE ts >= ' .. db.quote(since) .. ';')[1] or {}
		stats = storage_stats(path)
		stats.range_rows = tonumber(c.n) or 0
		stats.range_bytes = math.floor(stats.range_rows * stats.row_bytes)
	end
	local topo = topology.build(rows, info, live_view(M.runtime(env)))
	topo.range = key
	topo.since = since
	topo.storage = stats
	return topo
end

function M.devices(args, env)
	local since, key = resolve(env, args)
	if not since then return key end
	local exists, path = have_db(env)
	if not exists then return { range = key, since = since, devices = json.array() } end
	local live = live_view(M.runtime(env))
	local list = devices_from_pairs(path, since, pair_rows(path, since), live)
	return { range = key, since = since, devices = json.array(list) }
end

-- Single heavy scan for the overview page (topology + device grid). Avoids
-- LuCI firing two full-range GROUP BY queries that together exceed RPC timeout.
function M.overview(args, env)
	local since, key = resolve(env, args)
	if not since then return key end
	local exists, path = have_db(env)
	local live = live_view(M.runtime(env))
	local rows, info = {}, { devices = {}, targets = {} }
	local stats
	local pair = {}
	if exists then
		pair = pair_rows(path, since)
		rows, info = rows_to_info(pair)
		local c = q(path, 'SELECT COUNT(*) AS n FROM traffic_samples WHERE ts >= ' .. db.quote(since) .. ';')[1] or {}
		stats = storage_stats(path)
		stats.range_rows = tonumber(c.n) or 0
		stats.range_bytes = math.floor(stats.range_rows * stats.row_bytes)
	end
	local topo = topology.build(rows, info, live)
	topo.range = key
	topo.since = since
	topo.storage = stats
	local list = exists and devices_from_pairs(path, since, pair, live) or {}
	return {
		range = key,
		since = since,
		topology = topo,
		devices = json.array(list),
	}
end

local function valid_mac(mac)
	return type(mac) == 'string' and mac:match('^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$') ~= nil
end

-- Display / source resolution shared by device_detail list queries.
local DETAIL_DISPLAY = [[COALESCE(
  CASE WHEN t.source IN ('dns','sni','http_host','service') THEN t.display END,
  CASE WHEN n.source IN ('dns','sni','http_host','service') THEN n.name END,
  CASE WHEN t.source = 'asn' THEN COALESCE(t.ip, s.target) END,
  t.display, s.target
)]]
local DETAIL_SOURCE = [[COALESCE(
  CASE WHEN t.source IN ('dns','sni','http_host','service','asn') THEN t.source END,
  CASE WHEN n.source IN ('dns','sni','http_host','service','asn') THEN n.source END,
  t.source, 'ip'
)]]
local DETAIL_UNRESOLVED = [[CASE
  WHEN t.source IN ('dns','sni','http_host','service','asn') THEN 0
  WHEN n.source IN ('dns','sni','http_host','service','asn') THEN 0
  WHEN t.unresolved = 0 THEN 0
  ELSE 1
END]]

local DETAIL_PAGE_DEFAULT = 80
local DETAIL_PAGE_MAX = 200
-- Below this session count, return the full merged day (with children when small).
local DETAIL_FULL_MAX = 500

local function detail_order_sql(sort)
	-- Order fully-aggregated display groups (each row = one destination, all-day).
	if sort == 'time' then return 'started_at DESC, display ASC'
	elseif sort == 'target' then return 'display ASC, started_at DESC'
	elseif sort == 'up' then return 'bytes_up DESC, started_at DESC'
	elseif sort == 'down' then return 'bytes_down DESC, started_at DESC'
	elseif sort == 'duration' then return 'duration DESC, started_at DESC'
	end
	return 'bytes_total DESC, started_at DESC'
end

local function detail_join_from()
	return [[FROM sessions s
LEFT JOIN targets t ON t.key = s.target
LEFT JOIN ip_names n ON n.ip = COALESCE(t.ip, CASE WHEN s.target GLOB '*.*.*.*' THEN s.target END)]]
end

function M.device_detail(args, env)
	args = args or {}
	if not valid_mac(args.mac) then return { error = 'bad_mac' } end
	local mac = args.mac:lower()
	local exists, path = have_db(env)
	if not exists then return { mac = mac, days = json.array(), sessions = json.array() } end
	local qm = db.quote(mac)

	local dayset = {}
	-- 15-minute buckets keep day keys exact for any timezone offset.
	for _, r in ipairs(q(path, 'SELECT DISTINCT started_at / 900 AS b FROM sessions WHERE device = ' .. qm
		.. ' UNION SELECT DISTINCT last_seen_at / 900 FROM sessions WHERE device = ' .. qm .. ';')) do
		dayset[timeutil.day_key(tonumber(r.b) * 900)] = true
	end
	for _, r in ipairs(q(path, 'SELECT started_at, last_seen_at FROM sessions WHERE device = ' .. qm
		.. ' AND last_seen_at - started_at > 86400;')) do
		local t = tonumber(r.started_at)
		while t <= tonumber(r.last_seen_at) do
			dayset[timeutil.day_key(t)] = true
			t = timeutil.next_day_start(t)
		end
	end
	-- Calendar chips: current calendar month only (A4).
	local now = (env and env.now) or os.time()
	local cur_month = timeutil.month_key(now)
	local days = json.array()
	for d in pairs(dayset) do
		if tostring(d):sub(1, 7) == cur_month then days[#days + 1] = d end
	end
	table.sort(days, function(a, b) return a > b end)

	-- Default to today (router local calendar); may be empty if no sessions yet.
	local today = timeutil.day_key(now)
	local day = args.day
	if not day or day == '' then day = today end
	local dev = q(path, 'SELECT mac, ip, hostname, first_seen, last_seen FROM devices WHERE mac = ' .. qm .. ';')[1]
	local out = { mac = mac, device = dev, days = days, day = day, sessions = json.array() }
	if not day then return out end
	local ds = timeutil.parse_day(day)
	if not ds then return { error = 'bad_day' } end
	-- Reject days outside the current calendar month.
	if timeutil.month_key(ds) ~= cur_month then
		return { error = 'bad_day', mac = mac, days = days, day = day }
	end
	local de = timeutil.next_day_start(ds)
	local qds, qde = db.quote(ds), db.quote(de)
	local day_where = string.format('s.device = %s AND s.started_at < %s AND s.last_seen_at >= %s', qm, qde, qds)

	local tot = q(path, string.format(
		'SELECT COALESCE(SUM(bytes_up),0) AS u, COALESCE(SUM(bytes_down),0) AS d, COUNT(*) AS n FROM sessions s WHERE %s;',
		day_where))[1]
	out.bytes_up = tonumber(tot and tot.u) or 0
	out.bytes_down = tonumber(tot and tot.d) or 0
	out.bytes_total = out.bytes_up + out.bytes_down
	out.session_count = tonumber(tot and tot.n) or 0
	out.approximate = true

	local limit = math.floor(tonumber(args.limit) or DETAIL_PAGE_DEFAULT)
	if limit < 1 then limit = DETAIL_PAGE_DEFAULT end
	if limit > DETAIL_PAGE_MAX then limit = DETAIL_PAGE_MAX end
	local offset = math.floor(tonumber(args.offset) or 0)
	if offset < 0 then offset = 0 end
	out.limit, out.offset = limit, offset

	local qfilter = tostring(args.q or ''):gsub('[%%_\'\\]', '')
	local filter_sql = ''
	if qfilter ~= '' then
		local like = db.quote('%' .. qfilter .. '%')
		filter_sql = string.format(' WHERE display LIKE %s OR target LIKE %s', like, like)
	end

	-- Expand one destination: return every timed session for that display today.
	local children_of = tostring(args.children_of or '')
	if children_of ~= '' then
		local sql = string.format([[
SELECT target, display, source, asn_org, bytes_up, bytes_down, bytes_total,
  duration, started_at, last_seen_at, unresolved, active
FROM (
  SELECT
    s.target AS target,
    %s AS display,
    %s AS source,
    CASE WHEN n.source = 'asn' THEN n.name END AS asn_org,
    s.bytes_up AS bytes_up,
    s.bytes_down AS bytes_down,
    s.bytes_up + s.bytes_down AS bytes_total,
    s.last_seen_at - s.started_at AS duration,
    s.started_at AS started_at,
    s.last_seen_at AS last_seen_at,
    %s AS unresolved,
    CASE WHEN s.closed = 0 THEN 1 ELSE 0 END AS active
  %s
  WHERE %s
)
WHERE display = %s
ORDER BY started_at DESC
LIMIT 2000;]],
			DETAIL_DISPLAY, DETAIL_SOURCE, DETAIL_UNRESOLVED,
			detail_join_from(), day_where, db.quote(children_of))
		local rows = q(path, sql)
		local sessions = json.array()
		for _, r in ipairs(rows) do
			local up = tonumber(r.bytes_up) or 0
			local down = tonumber(r.bytes_down) or 0
			sessions[#sessions + 1] = {
				target = r.target,
				display = r.display,
				source = r.source,
				asn_org = r.asn_org,
				bytes_up = up,
				bytes_down = down,
				bytes_total = up + down,
				duration = tonumber(r.duration) or 0,
				started_at = tonumber(r.started_at) or 0,
				last_seen_at = tonumber(r.last_seen_at) or 0,
				unresolved = tonumber(r.unresolved) == 1,
				active = tonumber(r.active) == 1,
				split = false,
			}
		end
		out.sessions = sessions
		out.has_more = false
		out.paged = false
		out.children_of = children_of
		return out
	end

	-- Busy days: page by destination (display). Each returned row is a FULL
	-- day aggregate for that destination (all its sessions summed) — never a
	-- partial slice of one destination's sessions. Day header totals still
	-- come from the cheap SUM above.
	if out.session_count > DETAIL_FULL_MAX or offset > 0 or qfilter ~= '' then
		local order = detail_order_sql(args.sort)
		local sql = string.format([[
SELECT display, target, source, asn_org, bytes_up, bytes_down, bytes_total,
  duration, started_at, last_seen_at, unresolved, active, session_count
FROM (
  SELECT
    %s AS display,
    MIN(s.target) AS target,
    MIN(%s) AS source,
    MAX(CASE WHEN n.source = 'asn' THEN n.name END) AS asn_org,
    SUM(s.bytes_up) AS bytes_up,
    SUM(s.bytes_down) AS bytes_down,
    SUM(s.bytes_up) + SUM(s.bytes_down) AS bytes_total,
    SUM(s.last_seen_at - s.started_at) AS duration,
    MIN(s.started_at) AS started_at,
    MAX(s.last_seen_at) AS last_seen_at,
    MIN(%s) AS unresolved,
    MAX(CASE WHEN s.closed = 0 THEN 1 ELSE 0 END) AS active,
    COUNT(*) AS session_count
  %s
  WHERE %s
  GROUP BY display
)%s
ORDER BY %s
LIMIT %d OFFSET %d;]],
			DETAIL_DISPLAY, DETAIL_SOURCE, DETAIL_UNRESOLVED,
			detail_join_from(), day_where, filter_sql, order, limit + 1, offset)
		local rows = q(path, sql)
		local has_more = #rows > limit
		if has_more then rows[#rows] = nil end
		local sessions = json.array()
		for _, r in ipairs(rows) do
			local up = tonumber(r.bytes_up) or 0
			local down = tonumber(r.bytes_down) or 0
			sessions[#sessions + 1] = {
				target = r.target,
				display = r.display,
				source = r.source,
				asn_org = r.asn_org,
				bytes_up = up,
				bytes_down = down,
				bytes_total = up + down,
				duration = tonumber(r.duration) or 0,
				started_at = tonumber(r.started_at) or 0,
				last_seen_at = tonumber(r.last_seen_at) or 0,
				unresolved = tonumber(r.unresolved) == 1,
				active = tonumber(r.active) == 1,
				session_count = tonumber(r.session_count) or 1,
				split = false,
			}
		end
		out.sessions = sessions
		out.has_more = has_more
		out.children_omitted = true
		out.paged = true
		return out
	end

	local sessions = q(path, string.format([[
SELECT s.device, s.target, s.started_at, s.last_seen_at, s.bytes_up, s.bytes_down, s.closed,
  %s AS display,
  %s AS unresolved,
  %s AS source,
  CASE WHEN n.source = 'asn' THEN n.name END AS asn_org
%s
WHERE %s;]], DETAIL_DISPLAY, DETAIL_UNRESOLVED, DETAIL_SOURCE, detail_join_from(), day_where))

	-- Samples are only needed to apportion bytes for sessions that cross
	-- midnight. Loading a full day of traffic_samples (tens of thousands of
	-- rows) for a busy device was hanging rpcd/LuCI and kicking the user out.
	local samples = {}
	local need_samples = false
	for _, s in ipairs(sessions) do
		local a, b = tonumber(s.started_at), tonumber(s.last_seen_at)
		if a and b and timeutil.day_key(a) ~= timeutil.day_key(b) then
			need_samples = true
			break
		end
	end
	if need_samples then
		samples = q(path, string.format(
			'SELECT target, ts, bytes_up, bytes_down FROM traffic_samples WHERE device = %s AND ts >= %s AND ts < %s;',
			qm, qds, qde))
	end

	local grouped = detail.build(sessions, samples, { day = day, sort = args.sort })
	if grouped[1] then
		local merged, stripped = detail.merge_by_display(grouped[1].rows, { max_flat = 400 })
		out.sessions = json.array(merged)
		-- Prefer exact day totals from the cheap SUM above; fall back to build.
		if out.session_count == 0 then
			out.bytes_up, out.bytes_down, out.bytes_total =
				grouped[1].bytes_up, grouped[1].bytes_down, grouped[1].bytes_total
		end
		if stripped then out.children_omitted = true end
	end
	out.has_more = false
	out.paged = false
	return out
end

function M.device_months(args, env)
	args = args or {}
	if not valid_mac(args.mac) then return { error = 'bad_mac' } end
	local mac = args.mac:lower()
	local exists, path = have_db(env)
	if not exists then return { mac = mac, months = json.array() } end
	local rows = q(path, 'SELECT DISTINCT month FROM monthly_traffic WHERE device = '
		.. db.quote(mac) .. ' ORDER BY month DESC;')
	local months = json.array()
	for _, r in ipairs(rows) do months[#months + 1] = r.month end
	return { mac = mac, months = months }
end

function M.device_month_summary(args, env)
	args = args or {}
	if not valid_mac(args.mac) then return { error = 'bad_mac' } end
	local month = tostring(args.month or '')
	if not timeutil.parse_month(month) then return { error = 'bad_month' } end
	local mac = args.mac:lower()
	local exists, path = have_db(env)
	if not exists then return { mac = mac, month = month, rows = json.array() } end
	local other = rollup.OTHER_TARGET
	local rows = q(path, string.format([[
SELECT target, display, bytes_up, bytes_down,
  (bytes_up + bytes_down) AS bytes_total
FROM monthly_traffic
WHERE device = %s AND month = %s
ORDER BY
  CASE WHEN target = %s THEN 1 ELSE 0 END ASC,
  (bytes_up + bytes_down) DESC,
  target ASC;]], db.quote(mac), db.quote(month), db.quote(other)))
	local out = json.array()
	local up_t, down_t = 0, 0
	for _, r in ipairs(rows) do
		local up = tonumber(r.bytes_up) or 0
		local down = tonumber(r.bytes_down) or 0
		up_t, down_t = up_t + up, down_t + down
		out[#out + 1] = {
			target = r.target,
			display = r.display,
			bytes_up = up,
			bytes_down = down,
			bytes_total = up + down,
			other = r.target == other,
		}
	end
	return {
		mac = mac,
		month = month,
		rows = out,
		bytes_up = up_t,
		bytes_down = down_t,
		bytes_total = up_t + down_t,
	}
end

function M.get_config(args, env)
	local c = {}
	for k in pairs(config.SETTABLE) do c[k] = env.cfg[k] end
	c.retention_units = json.array({ 'hour', 'day', 'week', 'month', 'year' })
	c.ranges = json.array({})
	for _, r in ipairs(timeutil.RANGES) do c.ranges[#c.ranges + 1] = r.key end
	c.allowed_ranges = timeutil.allowed_ranges(env.now, env.cfg)
	c.reserve_min_mb = env.cfg.reserve_min_mb
	c.reserve_pct = env.cfg.reserve_pct
	return c
end


-- Disk-use estimate for detail retention = current calendar month (UCI
-- retention_* no longer change the purge window; args kept for API compat).
function M.estimate(args, env)
	args = args or {}
	local cfg = {}
	for k, v in pairs(env.cfg) do cfg[k] = v end
	-- Legacy args accepted for API compat; they do not change calendar-month cutoff.
	if args.retention_unit then
		if not timeutil.UNITS[args.retention_unit] then return { error = 'bad_retention_unit' } end
		cfg.retention_unit = args.retention_unit
	end
	if args.retention_value ~= nil then
		cfg.retention_value = tonumber(args.retention_value) or cfg.retention_value
	end
	local cutoff = timeutil.retention_cutoff(env.now, cfg) -- month_start
	-- Estimate a full calendar month of detail (not "elapsed so far" / not UCI days).
	local month_secs = timeutil.next_month_start(env.now) - cutoff
	local rows_per_day, row_bytes, observed = M.DEFAULT_ROWS_PER_DAY, M.DEFAULT_ROW_BYTES, false
	local exists, path = have_db(env)
	if exists then
		local s = storage_stats(path)
		local r = q(path, 'SELECT COUNT(*) AS n, MIN(ts) AS t0 FROM traffic_samples WHERE ts >= '
			.. db.quote(env.now - 86400) .. ';')[1] or {}
		local n, t0 = tonumber(r.n) or 0, tonumber(r.t0)
		if n > 0 and t0 and env.now - t0 >= 600 then
			rows_per_day = n * 86400 / (env.now - t0)
			row_bytes = s.row_bytes
			observed = true
		end
	end
	local est = math.floor(rows_per_day * row_bytes * month_secs / 86400)
	local out = {
		retention_seconds = month_secs,
		detail_retention = 'calendar_month',
		rows_per_day = math.floor(rows_per_day),
		row_bytes = math.floor(row_bytes),
		estimated_bytes = est,
		observed = observed,
	}
	local dir = args.db_path or cfg.db_path
	if dir and dir ~= '' then
		local chk = disk.check(dir, cfg, env.statfs)
		if chk.total then
			out.free, out.total, out.reserve = chk.free, chk.total, chk.reserve
			out.fits = est <= chk.free - chk.reserve
		end
	end
	return out
end

-- Read-only path check (F1): never mkdir / never write probe.
function M.check_path(args, env)
	args = args or {}
	local v = disk.inspect_path(args.path, env.cfg, env.fsops)
	if v.ok then
		v.estimate = M.estimate({ db_path = args.path }, env)
	end
	v.warnings = json.array(v.warnings)
	return v
end

-- Write ACL: create dir + write probe for wizard/settings (F1).
function M.prepare_path(args, env)
	args = args or {}
	local v = disk.validate_path(args.path, env.cfg, env.fsops)
	if v.ok then
		v.estimate = M.estimate({ db_path = args.path }, env)
	end
	v.warnings = json.array(v.warnings)
	return v
end

local function restart(env, action)
	local runner = env.runner or os.execute
	if action == 'stop' then
		return runner('/etc/init.d/netmonitor stop >/dev/null 2>&1')
	end
	return runner('/etc/init.d/netmonitor enable >/dev/null 2>&1; /etc/init.d/netmonitor restart >/dev/null 2>&1')
end

function M.set_config(args, env)
	args = args or {}
	local confirm = args.confirm
	-- Only accept known UCI keys. LuCI/rpcd also injects ubus_rpc_session etc.
	local patch = {}
	for k, v in pairs(args) do
		if config.SETTABLE[k] then patch[k] = v end
	end
	local cfg, err = config.validate(env.cfg, patch)
	if not cfg then return { ok = false, error = err } end

	local out = { ok = true, warnings = json.array() }
	if patch.db_path and patch.db_path ~= '' then
		local v = disk.validate_path(cfg.db_path, cfg, env.fsops)
		if not v.ok then return { ok = false, error = v.error } end
		for _, w in ipairs(v.warnings) do out.warnings[#out.warnings + 1] = w end
	end

	-- Detail purge is calendar-month only; UCI retention_* no longer shortens
	-- the cutoff, so "shorten retention" confirm against rolling days is gone (F2).
	local _ = confirm -- accepted for API compat; unused under calendar-month retention
	out.detail_retention = 'calendar_month'

	local saver = env.saver or config.save
	saver(cfg)
	env.cfg = cfg
	-- Keep ASN cron in sync with settings (PassWall-style visible schedule).
	-- Tests set cron_runner=false to skip; production uses os.execute.
	if env.cron_runner ~= false then
		pcall(asn.sync_cron, cfg, env.cron_runner or os.execute)
		pcall(service.sync_cron, cfg, env.cron_runner or os.execute)
	end
	-- Honour enabled=0 / stop intent (F8).
	if cfg.db_path == '' then
		-- no collector without path
	elseif cfg.enabled == 0 then
		restart(env, 'stop')
	else
		restart(env, 'restart')
	end
	return out
end

function M.update_asn(args, env)
	return asn.start_update(env.cfg, env.runner)
end

function M.update_service(args, env)
	return service.start_update(env.cfg, env.runner)
end

function M.collector(args, env)
	local action = (args and args.action) or 'start'
	if action ~= 'start' and action ~= 'stop' and action ~= 'restart' then
		return { ok = false, error = 'bad_action' }
	end
	if action ~= 'stop' then
		local pre = collector.preflight(env.cfg, env.fsops)
		if not pre.ok then return { ok = false, error = pre.error, state = pre.state } end
	end
	restart(env, action)
	return { ok = true }
end

-- Empty method signatures must be JSON objects {}, not [] (Lua empty table pitfall).
M.METHODS = {
	status = json.object(),
	topology = { range = '1h' },
	devices = { range = '1h' },
	overview = { range = '1h' },
	device_detail = { mac = 'aa:bb:cc:dd:ee:ff', day = '2026-01-01', sort = 'traffic',
		limit = 80, offset = 0, q = '', children_of = '' },
	device_months = { mac = 'aa:bb:cc:dd:ee:ff' },
	device_month_summary = { mac = 'aa:bb:cc:dd:ee:ff', month = '2026-10' },
	get_config = json.object(),
	estimate = { retention_value = 30, retention_unit = 'day', db_path = '/mnt/usb' },
	check_path = { path = '/mnt/usb' },
	prepare_path = { path = '/mnt/usb' },
	set_config = { db_path = '/mnt/usb', interval = 5, idle_gap = 60,
		retention_value = 30, retention_unit = 'day', enabled = 1, sni_enable = 1,
		asn_enable = 1, asn_auto_update = 1, asn_week_time = '*', asn_day_time = 4,
		asn_path = '/overlay/netmonitor/GeoLite2-ASN.mmdb',
		asn_url = 'https://cdn.jsdelivr.net/npm/geolite2-asn/GeoLite2-ASN.mmdb.gz',
		service_enable = 1, service_auto_update = 1, service_week_time = '*',
		service_day_time = 5, service_path = '/overlay/netmonitor/services.map',
		confirm = true },
	update_asn = json.object(),
	update_service = json.object(),
	collector = { action = 'start' },
}

function M.call(method, args, env)
	local fn = M.METHODS[method] and M[method]
	if not fn then return { error = 'unknown_method' } end
	local ok, res = pcall(fn, args or {}, env)
	if not ok then
		if type(res) == 'table' then return { error = res.code, detail = res.detail } end
		return { error = 'internal', detail = tostring(res) }
	end
	return res
end

return M
