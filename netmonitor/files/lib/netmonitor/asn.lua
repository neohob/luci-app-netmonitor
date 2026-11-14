-- Offline ASN org lookup via GeoLite2-ASN.mmdb (lua-maxminddb soft-dep).
local json = require 'netmonitor.json'

local M = {}

M.DEFAULT_PATH = '/overlay/netmonitor/GeoLite2-ASN.mmdb'
M.DEFAULT_URL = 'https://cdn.jsdelivr.net/npm/geolite2-asn/GeoLite2-ASN.mmdb.gz'
M.STATUS_FILE = '/overlay/netmonitor/asn-update.status'
M.CRON_TAG = 'netmonitor-asn-update'
M.MIN_BYTES = 1024 * 1024

function M.new()
	return { cache = {}, db = nil, path = nil, mtime = nil, hits = 0, misses = 0 }
end

function M.binding_available()
	local ok = pcall(require, 'maxminddb')
	return ok == true
end

local function file_stat(path)
	if not path or path == '' then return nil end
	local f = io.open(path, 'r')
	if not f then return nil end
	local size = f:seek('end')
	f:close()
	local p = io.popen("date -r " .. string.format('%q', path) .. " +%s 2>/dev/null")
	local mtime = p and tonumber(p:read('*l')) or nil
	if p then p:close() end
	return { size = size, mtime = mtime, path = path }
end

function M.read_status()
	local f = io.open(M.STATUS_FILE, 'r')
	if not f then return nil end
	local text = f:read('*a')
	f:close()
	return json.decode(text)
end

function M.write_status(st)
	local dir = M.STATUS_FILE:match('^(.+)/[^/]+$')
	if dir then os.execute('mkdir -p ' .. string.format('%q', dir) .. ' 2>/dev/null') end
	local tmp = M.STATUS_FILE .. '.tmp'
	local f = io.open(tmp, 'w')
	if not f then return false end
	f:write(json.encode(json.object(st)))
	f:close()
	return os.rename(tmp, M.STATUS_FILE) and true or false
end

-- Shorten noisy RIR org strings for UI labels.
function M.normalize_org(org, asn_num)
	if type(org) == 'string' then
		org = org:gsub('^%s+', ''):gsub('%s+$', '')
		if org ~= '' then
			-- Keep first clause before comma for long legal names.
			local short = org:match('^([^,]+)')
			if short and #short >= 2 then org = short end
			if #org > 48 then org = org:sub(1, 45) .. '...' end
			return org
		end
	end
	if asn_num then return 'AS' .. tostring(asn_num) end
	return nil
end

local function open_db(state, path)
	if not path or path == '' then return nil, 'no_path' end
	local st = file_stat(path)
	if not st or not st.size or st.size < M.MIN_BYTES then return nil, 'missing_db' end
	if state.db and state.path == path and state.mtime == st.mtime then
		return state.db
	end
	local ok, maxminddb = pcall(require, 'maxminddb')
	if not ok or not maxminddb then return nil, 'no_binding' end
	local db, err = maxminddb.open(path)
	if not db then return nil, err or 'open_failed' end
	state.db, state.path, state.mtime = db, path, st.mtime
	state.cache = {}
	return db
end

function M.lookup(state, ip, cfg)
	if (tonumber(cfg and cfg.asn_enable) or 1) == 0 then return nil end
	if not ip or ip == '' then return nil end
	local cached = state.cache[ip]
	if cached ~= nil then
		return cached ~= false and cached or nil
	end
	local path = (cfg and cfg.asn_path ~= '' and cfg.asn_path) or M.DEFAULT_PATH
	local db, err = open_db(state, path)
	if not db then
		state.cache[ip] = false
		state.last_error = err
		state.misses = (state.misses or 0) + 1
		return nil
	end
	local ok, res = pcall(function() return db:lookup(ip) end)
	if not ok or not res then
		state.cache[ip] = false
		state.misses = (state.misses or 0) + 1
		return nil
	end
	local org, asn_num
	ok, org = pcall(function() return res:get('autonomous_system_organization') end)
	if not ok then org = nil end
	ok, asn_num = pcall(function() return res:get('autonomous_system_number') end)
	if not ok then asn_num = nil end
	local name = M.normalize_org(org, asn_num)
	if name then
		state.cache[ip] = name
		state.hits = (state.hits or 0) + 1
		return name
	end
	state.cache[ip] = false
	state.misses = (state.misses or 0) + 1
	return nil
end

function M.load_persisted(state, rows)
	for _, r in ipairs(rows or {}) do
		if r.ip and r.name and r.source == 'asn' then
			state.cache[r.ip] = r.name
		end
	end
end

function M.status(state, cfg)
	local enabled = (tonumber(cfg and cfg.asn_enable) or 1) ~= 0
	local path = (cfg and cfg.asn_path ~= '' and cfg.asn_path) or M.DEFAULT_PATH
	local binding = M.binding_available()
	local st = file_stat(path)
	local available = enabled and binding and st and st.size and st.size >= M.MIN_BYTES
	local upd = M.read_status() or {}
	return {
		enabled = enabled,
		available = available and true or false,
		binding = binding,
		path = path,
		size = st and st.size or nil,
		mtime = st and st.mtime or nil,
		auto_update = (tonumber(cfg and cfg.asn_auto_update) or 0) ~= 0,
		url = (cfg and cfg.asn_url ~= '' and cfg.asn_url) or M.DEFAULT_URL,
		week_time = tostring((cfg and cfg.asn_week_time) or '*'),
		day_time = tonumber(cfg and cfg.asn_day_time) or 4,
		hits = state and state.hits or 0,
		misses = state and state.misses or 0,
		last_error = state and state.last_error or nil,
		update = {
			state = upd.state or 'idle',
			ts = upd.ts,
			error = upd.error,
			bytes = upd.bytes,
		},
	}
end

-- Install or remove the dedicated crontab line for ASN DB refresh.
function M.sync_cron(cfg, runner)
	runner = runner or os.execute
	local enable = (tonumber(cfg.asn_auto_update) or 0) ~= 0
		and (tonumber(cfg.asn_enable) or 1) ~= 0
	local hour = tonumber(cfg.asn_day_time) or 4
	if hour < 0 or hour > 23 then hour = 4 end
	local week = tostring(cfg.asn_week_time or '*')
	if week ~= '*' then
		local w = tonumber(week)
		if not w or w < 0 or w > 6 then week = '*' end
	end
	local line = string.format('0 %d * * %s /usr/sbin/netmonitor-asn-update >/dev/null 2>&1 # %s',
		hour, week, M.CRON_TAG)
	local cmd
	if enable then
		cmd = string.format([[
tmp=$(mktemp)
crontab -l 2>/dev/null | grep -v '# %s' > "$tmp" || true
echo %s >> "$tmp"
crontab "$tmp"
rm -f "$tmp"
]], M.CRON_TAG, string.format('%q', line))
	else
		cmd = string.format([[
tmp=$(mktemp)
crontab -l 2>/dev/null | grep -v '# %s' > "$tmp" || true
crontab "$tmp" 2>/dev/null || true
rm -f "$tmp"
]], M.CRON_TAG)
	end
	return runner(cmd)
end

-- Start update in background (rpcd-friendly). Returns immediately.
function M.start_update(cfg, runner)
	runner = runner or os.execute
	local cur = M.read_status()
	if cur and cur.state == 'running' then
		local ts = tonumber(cur.ts) or 0
		if os.time() - ts < 600 then
			return { ok = true, started = false, busy = true }
		end
	end
	M.write_status({ state = 'running', ts = os.time(), error = '', bytes = 0 })
	local path = (cfg.asn_path ~= '' and cfg.asn_path) or M.DEFAULT_PATH
	local url = (cfg.asn_url ~= '' and cfg.asn_url) or M.DEFAULT_URL
	local cmd = string.format(
		'/usr/sbin/netmonitor-asn-update --path %s --url %s >/tmp/netmonitor-asn-update.log 2>&1 &',
		string.format('%q', path), string.format('%q', url))
	runner(cmd)
	return { ok = true, started = true }
end

return M
