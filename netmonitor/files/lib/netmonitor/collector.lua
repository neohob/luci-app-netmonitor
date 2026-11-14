-- Collector core: one poll = conntrack deltas -> device/target attribution
-- -> samples + session upserts, guarded by the free-space check.
local conntrack = require 'netmonitor.conntrack'
local neigh = require 'netmonitor.neigh'
local dns = require 'netmonitor.dns'
local sni = require 'netmonitor.sni'
local asn = require 'netmonitor.asn'
local service = require 'netmonitor.service'
local session = require 'netmonitor.session'
local live = require 'netmonitor.live'
local disk = require 'netmonitor.disk'
local db = require 'netmonitor.db'
local schema = require 'netmonitor.schema'
local sql = require 'netmonitor.sql'
local json = require 'netmonitor.json'
local timeutil = require 'netmonitor.timeutil'

local M = {}

-- Production default; tests pass opts.rundir (F18: no env override).
M.RUNDIR = '/var/run/netmonitor'
M.RETENTION_EVERY = 60

function M.state_file(rundir)
	return (rundir or M.RUNDIR) .. '/state.json'
end

function M.write_state(rundir, st)
	local path = M.state_file(rundir)
	local tmp = path .. '.tmp'
	local f = io.open(tmp, 'w')
	if not f then return false end
	f:write(json.encode(st))
	f:close()
	return os.rename(tmp, path)
end

function M.read_state(rundir)
	local f = io.open(M.state_file(rundir), 'r')
	if not f then return nil end
	local text = f:read('*a')
	f:close()
	return json.decode(text)
end

-- Gate collection on a configured, writable path with enough space (A1/A8).
function M.preflight(cfg, fsops)
	if not cfg.db_path or cfg.db_path == '' then
		return { ok = false, state = 'need_wizard', error = 'need_path' }
	end
	local v = disk.validate_path(cfg.db_path, cfg, fsops)
	if not v.ok then
		local st = (v.error == 'insufficient_space') and 'disk_pause' or 'path_error'
		return { ok = false, state = st, error = v.error, check = v }
	end
	return { ok = true, check = v }
end

local function non_routable(ip)
	if ip:match('^22[4-9]%.') or ip:match('^23%d%.') or ip:match('^255%.')
		or ip:match('^127%.') or ip:match('^169%.254%.') or ip == '0.0.0.0' then
		return true
	end
	local l = ip:lower()
	return l:match('^ff%x%x:') ~= nil or l:match('^fe80:') ~= nil or l == '::1'
end

local function is_lan(snap, ip)
	return neigh.mac_for(snap, ip) ~= nil or snap.own[ip] == true
end

-- Returns mac, device_ip, remote_ip, upload_direction or nil to skip.
function M.classify(e, snap)
	local o, r = e.orig, e.reply
	local mac = not snap.own[o.src] and neigh.mac_for(snap, o.src)
	if mac then
		if is_lan(snap, o.dst) or non_routable(o.dst) then return nil end
		return mac, o.src, o.dst, 'orig'
	end
	mac = not snap.own[r.src] and neigh.mac_for(snap, r.src)
	if mac then
		if is_lan(snap, o.src) or non_routable(o.src) then return nil end
		return mac, r.src, o.src, 'reply'
	end
	return nil
end

function M.new(cfg, opts)
	opts = opts or {}
	local ctx = {
		cfg = cfg,
		db_file = opts.db_file or disk.db_file(cfg.db_path),
		rundir = opts.rundir or M.RUNDIR,
		sources = opts.sources or {},
		statfs = opts.statfs,
		prime = opts.prime ~= false,
		flows = nil,
		sess = session.new(),
		live = live.new(),
		dns = dns.new(),
		sni = sni.new(),
		asn = asn.new(),
		service = service.new(),
		last_retention = 0,
		sni_status = nil,
		asn_status = nil,
		service_status = nil,
	}
	return ctx
end

function M.init_db(ctx)
	local ok, err = schema.apply(ctx.db_file, db)
	if not ok then return nil, err end
	local rows = db.query(ctx.db_file,
		'SELECT device, target, started_at, last_seen_at, bytes_up, bytes_down FROM sessions WHERE closed = 0;')
	session.restore(ctx.sess, rows)
	local names = db.query(ctx.db_file, 'SELECT ip, name, source, updated_at FROM ip_names;') or {}
	dns.load_persisted(ctx.dns, names, os.time())
	asn.load_persisted(ctx.asn, names)
	for _, r in ipairs(names) do
		if r.source == 'sni' or r.source == 'http_host' then
			sni.remember(ctx.sni, r.ip, r.name, r.source, tonumber(r.updated_at) or os.time())
		end
	end
	return true
end

local function source(ctx, name, default)
	local fn = ctx.sources[name]
	if fn then return fn(ctx) end
	return default(ctx)
end

local function default_conntrack() return conntrack.read() end
local function default_neigh(ctx) return neigh.snapshot(ctx.cfg.lan_ifaces) end
local function default_dns(ctx) return dns.read_log(ctx.dns, ctx.cfg.dns_log) end

function M.build_sql(ts, devices, targets, pairs_list, changed, ip_name_rows)
	local out = { 'BEGIN;' }
	for mac, d in pairs(devices) do
		out[#out + 1] = sql.upsert_device(mac, d.ip, d.hostname, ts, ts)
	end
	for key, t in pairs(targets) do
		local ra = (tonumber(t.unresolved) == 0) and ts or nil
		out[#out + 1] = sql.upsert_target(key, t.kind, t.display, t.ip, t.unresolved, t.source, ra)
	end
	for _, p in ipairs(pairs_list) do
		out[#out + 1] = sql.insert_sample(p.device, p.target, ts, p.up, p.down)
	end
	for _, s in ipairs(changed) do
		out[#out + 1] = sql.upsert_session(s)
	end
	for _, n in ipairs(ip_name_rows or {}) do
		out[#out + 1] = sql.upsert_ip_name(n.ip, n.name, n.source, n.ts or ts)
	end
	out[#out + 1] = 'COMMIT;'
	return table.concat(out, '\n')
end

function M.retention_sql(cutoff)
	local c = db.quote(cutoff)
	return table.concat({
		'BEGIN;',
		'DELETE FROM traffic_samples WHERE ts < ' .. c .. ';',
		'DELETE FROM sessions WHERE last_seen_at < ' .. c .. ';',
		'DELETE FROM devices WHERE last_seen < ' .. c .. ';',
		'DELETE FROM targets WHERE key NOT IN (SELECT DISTINCT target FROM sessions);',
		'COMMIT;',
	}, '\n')
end

function M.retention_pass(db_file, cfg, now)
	local cutoff = timeutil.retention_cutoff(now, cfg)
	local ok, err = db.exec(db_file, M.retention_sql(cutoff))
	return ok, err, cutoff
end

-- One sampling cycle. Returns a result table describing what happened.
function M.poll(ctx, now)
	local cfg = ctx.cfg
	local res = { ts = now, samples = 0, degraded = false, paused = false }

	local text = source(ctx, 'conntrack', default_conntrack)
	local entries, stats = conntrack.parse(text)
	res.degraded, res.degraded_reason = conntrack.degraded(stats, text ~= nil)

	dns.feed(ctx.dns, source(ctx, 'dns', default_dns), now)
	dns.prune(ctx.dns, now)
	local snap = source(ctx, 'neigh', default_neigh)

	local snapshot, deltas = conntrack.deltas(ctx.flows, entries)
	local primed = ctx.flows == nil and ctx.prime
	ctx.flows = snapshot
	if primed then
		res.primed = true
		deltas = {}
	end

	local agg, order, devices, targets = {}, {}, {}, {}
	local unresolved_ips, unresolved_seen = {}, {}
	local ip_name_rows = {}
	for _, d in ipairs(deltas) do
		local mac, dev_ip, remote, dir = M.classify(d.entry, snap)
		if mac then
			local sni_hit = sni.lookup(ctx.sni, remote, now)
			local service_label, asn_name = nil, nil
			if not dns.lookup(ctx.dns, dev_ip, remote, now) and not (sni_hit and sni_hit.name) then
				service_label = service.lookup(ctx.service, remote, cfg)
				if not service_label then
					asn_name = asn.lookup(ctx.asn, remote, cfg)
				end
			end
			local t = dns.target_for(ctx.dns, dev_ip, remote, now, sni_hit, service_label, asn_name)
			if tonumber(t.unresolved) == 1 and not unresolved_seen[remote] then
				unresolved_seen[remote] = true
				unresolved_ips[#unresolved_ips + 1] = remote
			end
			-- Queue DNS/SNI/service/ASN names for persistence
			if t.source == 'dns' and t.ip and t.display then
				ip_name_rows[#ip_name_rows + 1] = { ip = t.ip, name = t.display, source = 'dns', ts = now }
			elseif (t.source == 'sni' or t.source == 'http_host') and t.ip and t.display then
				ip_name_rows[#ip_name_rows + 1] = { ip = t.ip, name = t.display, source = t.source, ts = now }
			elseif t.source == 'service' and t.ip and t.display then
				ip_name_rows[#ip_name_rows + 1] = { ip = t.ip, name = t.display, source = 'service', ts = now }
			elseif t.source == 'asn' and t.ip and t.asn_org then
				ip_name_rows[#ip_name_rows + 1] = { ip = t.ip, name = t.asn_org, source = 'asn', ts = now }
			end
			local up = (dir == 'orig') and d.d_orig or d.d_reply
			local down = (dir == 'orig') and d.d_reply or d.d_orig
			local k = mac .. '\t' .. t.key
			local a = agg[k]
			if not a then
				a = { device = mac, target = t.key, up = 0, down = 0 }
				agg[k] = a
				order[#order + 1] = a
			end
			a.up = a.up + up
			a.down = a.down + down
			local lease = snap.leases and snap.leases[mac]
			devices[mac] = { ip = dev_ip, hostname = lease and lease.hostname }
			targets[t.key] = t
		end
	end

	-- Wire sniff: DNS answers + SNI/Host for unresolved (best-effort; may block briefly).
	-- Needed when dnsmasq query-log is empty (common with ujail) or mosdns/passwall is in path.
	local probe = sni.probe_unresolved(ctx.sni, unresolved_ips, cfg, now, ctx.dns)
	res.sni = probe
	ctx.sni_status = sni.status(ctx.sni, cfg)
	if probe and not probe.skipped and probe.found and probe.found > 0 then
		for ip, hit in pairs(ctx.dns.by_ip) do
			if hit.ts == now then
				ip_name_rows[#ip_name_rows + 1] = { ip = ip, name = hit.name, source = 'dns', ts = now }
			end
		end
		for ip, hit in pairs(ctx.sni.by_ip) do
			if hit.ts == now then
				ip_name_rows[#ip_name_rows + 1] = { ip = ip, name = hit.name, source = hit.source, ts = now }
			end
		end
	end

	-- Service CIDR then ASN for IPs still unresolved after DNS + SNI.
	local service_found, asn_found = 0, 0
	for _, ip in ipairs(unresolved_ips) do
		if not dns.lookup(ctx.dns, nil, ip, now) and not sni.lookup(ctx.sni, ip, now) then
			local label = service.lookup(ctx.service, ip, cfg)
			if label then
				service_found = service_found + 1
				ip_name_rows[#ip_name_rows + 1] = { ip = ip, name = label, source = 'service', ts = now }
				if targets[ip] and tonumber(targets[ip].unresolved) == 1 then
					targets[ip].display = label
					targets[ip].unresolved = 0
					targets[ip].source = 'service'
				end
			else
				local org = asn.lookup(ctx.asn, ip, cfg)
				if org then
					asn_found = asn_found + 1
					ip_name_rows[#ip_name_rows + 1] = { ip = ip, name = org, source = 'asn', ts = now }
					if targets[ip] and tonumber(targets[ip].unresolved) == 1 then
						targets[ip].display = ip
						targets[ip].unresolved = 0
						targets[ip].source = 'asn'
						targets[ip].asn_org = org
					end
				end
			end
		end
	end
	res.service = { found = service_found }
	res.asn = { found = asn_found }
	ctx.service_status = service.status(ctx.service, cfg)
	ctx.asn_status = asn.status(ctx.asn, cfg)

	-- Disk gate before stitch/live/SQL so pause does not skew sessions (F4).
	local chk = disk.check(cfg.db_path, cfg, ctx.statfs)
	res.disk = chk
	if chk.unavailable then
		res.unavailable = true
		res.error = chk.error or 'statfs_failed'
		res.pairs = order
		res.changed = {}
	elseif chk.paused then
		res.paused = true
		res.pairs = order
		res.changed = {}
	else
		local changed = session.stitch(ctx.sess, now, order, cfg.idle_gap)
		live.record(ctx.live, now, order, math.max(3 * cfg.interval, 10))
		res.pairs = order
		res.changed = changed
		if #order > 0 or #changed > 0 or #ip_name_rows > 0 then
			local ok, err = db.exec(ctx.db_file, M.build_sql(now, devices, targets, order, changed, ip_name_rows))
			if not ok then
				res.error = err
				res.db_error = true
			else
				res.samples = #order
			end
		end
	end

	-- Retention: only advance timer on success (F9).
	if not res.paused and not res.unavailable and not res.db_error
		and now - ctx.last_retention >= M.RETENTION_EVERY then
		local rok, rerr = M.retention_pass(ctx.db_file, cfg, now)
		if rok then
			ctx.last_retention = now
		else
			res.error = res.error or rerr
			res.retention_error = true
		end
	end
	return res
end

function M.live_snapshot(ctx, now)
	local iv = ctx.cfg.interval
	return live.snapshot(ctx.live, now, math.max(3 * iv, 10), 2 * iv + 1)
end

function M.status_payload(ctx, res, now)
	local snap = M.live_snapshot(ctx, now)
	local pairs_live = {}
	for k in pairs(snap.pairs) do pairs_live[#pairs_live + 1] = k end
	-- F21: retention failure is not a write pause / db_error — samples may still write.
	local state = 'running'
	if res.unavailable then state = 'path_error'
	elseif res.db_error then state = 'db_error'
	elseif res.paused then state = 'disk_pause' end
	local warnings = {}
	for _, w in ipairs(ctx.warnings or {}) do warnings[#warnings + 1] = w end
	if res.retention_error then warnings[#warnings + 1] = 'retention_failed' end
	local dh = dns.health(ctx.cfg.dns_log)
	if not dh.ok and dh.warning then warnings[#warnings + 1] = dh.warning end
	local ss = ctx.sni_status or sni.status(ctx.sni, ctx.cfg)
	if (tonumber(ctx.cfg.sni_enable) or 1) ~= 0 and not ss.available then
		warnings[#warnings + 1] = 'sni_unavailable'
	end
	local as = ctx.asn_status or asn.status(ctx.asn, ctx.cfg)
	if (tonumber(ctx.cfg.asn_enable) or 1) ~= 0 and not as.available then
		warnings[#warnings + 1] = 'asn_unavailable'
	end
	if as.update and as.update.state == 'error' then
		warnings[#warnings + 1] = 'asn_update_failed'
	end
	local svc = ctx.service_status or service.status(ctx.service, ctx.cfg)
	if (tonumber(ctx.cfg.service_enable) or 1) ~= 0 and not svc.available then
		warnings[#warnings + 1] = 'service_unavailable'
	end
	if svc.update and svc.update.state == 'error' then
		warnings[#warnings + 1] = 'service_update_failed'
	end
	return {
		state = state,
		updated = now,
		interval = ctx.cfg.interval,
		degraded = res.degraded,
		degraded_reason = res.degraded_reason,
		error = res.db_error and res.error or (res.unavailable and res.error) or nil,
		retention_error = res.retention_error == true,
		retention_detail = res.retention_error and res.error or nil,
		disk = res.disk,
		warnings = warnings,
		sni = ss,
		asn = as,
		service = svc,
		live = json.object(snap.devices),
		live_pairs = pairs_live,
	}
end

return M
