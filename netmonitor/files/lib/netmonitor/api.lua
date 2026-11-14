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
local json = require 'netmonitor.json'

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

local function pair_rows(path, since)
	-- Prefer targets.display when resolved; else backfill from ip_names (DNS/SNI sniff),
	-- so older IP-keyed rows light up after names are learned.
	return q(path, string.format([[
SELECT s.device, s.target, s.up, s.down, d.ip, d.hostname,
  COALESCE(CASE WHEN t.unresolved = 0 THEN t.display END, n.name, n2.name, t.display, s.target) AS display,
  CASE WHEN t.unresolved = 0 OR n.name IS NOT NULL OR n2.name IS NOT NULL THEN 0 ELSE 1 END AS unresolved,
  COALESCE(CASE WHEN t.unresolved = 0 THEN t.source END, n.source, n2.source, t.source, 'ip') AS source
FROM (SELECT device, target, SUM(bytes_up) AS up, SUM(bytes_down) AS down
      FROM traffic_samples WHERE ts >= %s GROUP BY device, target) s
LEFT JOIN devices d ON d.mac = s.device
LEFT JOIN targets t ON t.key = s.target
LEFT JOIN ip_names n ON n.ip = s.target
LEFT JOIN ip_names n2 ON t.ip IS NOT NULL AND n2.ip = t.ip;]], db.quote(since)))
end

local function storage_stats(path)
	local r = q(path, 'SELECT COUNT(*) AS n FROM traffic_samples;')[1] or {}
	local n = tonumber(r.n) or 0
	local size = file_size(path) + file_size(path .. '-wal')
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
		clock_unsynced = env.now < M.CLOCK_SANE_AFTER,
		disk = st.disk,
	}
	for _, w in ipairs(st.warnings or {}) do out.warnings[#out.warnings + 1] = w end
	if cfg.db_path == '' then
		out.state = 'need_wizard'
		return out
	end
	local exists, path = have_db(env)
	if exists then out.db_bytes = file_size(path) + file_size(path .. '-wal') end
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
	return out
end

function M.topology(args, env)
	local since, key = resolve(env, args)
	if not since then return key end
	local exists, path = have_db(env)
	local rows, info = {}, { devices = {}, targets = {} }
	local stats
	if exists then
		for _, r in ipairs(pair_rows(path, since)) do
			rows[#rows + 1] = { device = r.device, target = r.target,
				up = tonumber(r.up) or 0, down = tonumber(r.down) or 0 }
			info.devices[r.device] = { ip = r.ip, hostname = r.hostname }
			info.targets[r.target] = { display = r.display, unresolved = tonumber(r.unresolved),
				source = r.source or ((tonumber(r.unresolved) == 1) and 'ip' or 'dns') }
		end
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
	local per, top = {}, {}
	for _, r in ipairs(pair_rows(path, since)) do
		local p = per[r.device] or { up = 0, down = 0 }
		local up, down = tonumber(r.up) or 0, tonumber(r.down) or 0
		p.up, p.down = p.up + up, p.down + down
		per[r.device] = p
		local t = top[r.device]
		if not t or up + down > t.bytes then
			top[r.device] = { bytes = up + down, display = r.display or r.target }
		end
	end
	local known = q(path, 'SELECT mac, ip, hostname, last_seen FROM devices WHERE last_seen >= '
		.. db.quote(since) .. ' OR mac IN (SELECT DISTINCT device FROM traffic_samples WHERE ts >= '
		.. db.quote(since) .. ');')
	local rows = {}
	for _, d in ipairs(known) do
		local p = per[d.mac] or { up = 0, down = 0 }
		rows[#rows + 1] = { mac = d.mac, ip = d.ip, hostname = d.hostname, last_seen = d.last_seen,
			bytes_up = p.up, bytes_down = p.down, top_target = top[d.mac] and top[d.mac].display }
	end
	local list = topology.devices(rows, live_view(M.runtime(env)))
	return { range = key, since = since, devices = json.array(list) }
end

local function valid_mac(mac)
	return type(mac) == 'string' and mac:match('^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$') ~= nil
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
	local days = json.array()
	for d in pairs(dayset) do days[#days + 1] = d end
	table.sort(days, function(a, b) return a > b end)

	-- Default to today (router local calendar); may be empty if no sessions yet.
	local today = timeutil.day_key((env and env.now) or os.time())
	local day = args.day
	if not day or day == '' then day = today end
	local dev = q(path, 'SELECT mac, ip, hostname, first_seen, last_seen FROM devices WHERE mac = ' .. qm .. ';')[1]
	local out = { mac = mac, device = dev, days = days, day = day, sessions = json.array() }
	if not day then return out end
	local ds = timeutil.parse_day(day)
	if not ds then return { error = 'bad_day' } end
	local de = timeutil.next_day_start(ds)

	local sessions = q(path, string.format([[
SELECT s.device, s.target, s.started_at, s.last_seen_at, s.bytes_up, s.bytes_down, s.closed,
       t.display, t.unresolved
FROM sessions s LEFT JOIN targets t ON t.key = s.target
WHERE s.device = %s AND s.started_at < %s AND s.last_seen_at >= %s;]], qm, db.quote(de), db.quote(ds)))

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
			qm, db.quote(ds), db.quote(de)))
	end

	local grouped = detail.build(sessions, samples, { day = day, sort = args.sort })
	if grouped[1] then
		local merged, stripped = detail.merge_by_display(grouped[1].rows, { max_flat = 400 })
		out.sessions = json.array(merged)
		out.bytes_up, out.bytes_down, out.bytes_total =
			grouped[1].bytes_up, grouped[1].bytes_down, grouped[1].bytes_total
		if stripped then out.children_omitted = true end
	end
	out.approximate = true
	return out
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

-- Disk-use estimate for a retention window, from observed row rate when
-- the DB has history, else a conservative default.
function M.estimate(args, env)
	args = args or {}
	local cfg = {}
	for k, v in pairs(env.cfg) do cfg[k] = v end
	cfg.retention_value = tonumber(args.retention_value) or cfg.retention_value
	cfg.retention_unit = args.retention_unit or cfg.retention_unit
	if not timeutil.UNITS[cfg.retention_unit] then return { error = 'bad_retention_unit' } end
	local seconds = env.now - timeutil.retention_cutoff(env.now, cfg)
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
	local est = math.floor(rows_per_day * row_bytes * seconds / 86400)
	local out = { retention_seconds = seconds, rows_per_day = math.floor(rows_per_day),
		row_bytes = math.floor(row_bytes), estimated_bytes = est, observed = observed }
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
	local patch = {}
	for k, v in pairs(args) do if k ~= 'confirm' then patch[k] = v end end
	local cfg, err = config.validate(env.cfg, patch)
	if not cfg then return { ok = false, error = err } end

	local out = { ok = true, warnings = json.array() }
	if patch.db_path and patch.db_path ~= '' then
		local v = disk.validate_path(cfg.db_path, cfg, env.fsops)
		if not v.ok then return { ok = false, error = v.error } end
		for _, w in ipairs(v.warnings) do out.warnings[#out.warnings + 1] = w end
	end

	local old_cut = timeutil.retention_cutoff(env.now, env.cfg)
	local new_cut = timeutil.retention_cutoff(env.now, cfg)
	if new_cut > old_cut then
		local exists, path = have_db(env)
		local pending = 0
		if exists then
			local r = q(path, 'SELECT COUNT(*) AS n FROM traffic_samples WHERE ts < ' .. db.quote(new_cut) .. ';')[1]
			pending = tonumber(r and r.n) or 0
		end
		if pending > 0 and not confirm then
			return { ok = false, need_confirm = true, pending_delete_rows = pending,
				estimate = M.estimate({ retention_value = cfg.retention_value,
					retention_unit = cfg.retention_unit }, env) }
		end
		out.pending_delete_rows = pending
	end

	local saver = env.saver or config.save
	saver(cfg)
	env.cfg = cfg
	-- Keep ASN cron in sync with settings (PassWall-style visible schedule).
	-- Tests set cron_runner=false to skip; production uses os.execute.
	if env.cron_runner ~= false then
		pcall(asn.sync_cron, cfg, env.cron_runner or os.execute)
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
	device_detail = { mac = 'aa:bb:cc:dd:ee:ff', day = '2026-01-01', sort = 'time' },
	get_config = json.object(),
	estimate = { retention_value = 30, retention_unit = 'day', db_path = '/mnt/usb' },
	check_path = { path = '/mnt/usb' },
	prepare_path = { path = '/mnt/usb' },
	set_config = { db_path = '/mnt/usb', interval = 5, idle_gap = 60,
		retention_value = 30, retention_unit = 'day', enabled = 1, sni_enable = 1,
		asn_enable = 1, asn_auto_update = 1, asn_week_time = '*', asn_day_time = 4,
		asn_path = '/overlay/netmonitor/GeoLite2-ASN.mmdb',
		asn_url = 'https://cdn.jsdelivr.net/npm/geolite2-asn/GeoLite2-ASN.mmdb.gz',
		confirm = true },
	update_asn = json.object(),
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
