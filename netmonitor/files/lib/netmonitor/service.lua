-- Cloud/CDN service labels from CIDR map (metowolf + disposable packs).
local json = require 'netmonitor.json'

local M = {}

M.DEFAULT_PATH = '/overlay/netmonitor/services.map'
M.STATUS_FILE = '/overlay/netmonitor/services-update.status'
M.CRON_TAG = 'netmonitor-service-update'
M.MIN_BYTES = 64

function M.new()
	return { ranges = nil, path = nil, mtime = nil, hits = 0, misses = 0 }
end

local function file_stat(path)
	if not path or path == '' then return nil end
	local f = io.open(path, 'r')
	if not f then return nil end
	local size = f:seek('end')
	f:close()
	local p = io.popen('date -r ' .. string.format('%q', path) .. ' +%s 2>/dev/null')
	local mtime = p and tonumber(p:read('*l')) or nil
	if p then p:close() end
	return { size = size, mtime = mtime, path = path }
end

function M.ip_to_u32(ip)
	if type(ip) ~= 'string' then return nil end
	local a, b, c, d = ip:match('^(%d+)%.(%d+)%.(%d+)%.(%d+)$')
	if not a then return nil end
	a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
	if a > 255 or b > 255 or c > 255 or d > 255 then return nil end
	return a * 16777216 + b * 65536 + c * 256 + d
end

function M.u32_to_ip(n)
	n = math.floor(tonumber(n) or 0)
	local a = math.floor(n / 16777216) % 256
	local b = math.floor(n / 65536) % 256
	local c = math.floor(n / 256) % 256
	local d = n % 256
	return string.format('%d.%d.%d.%d', a, b, c, d)
end

function M.cidr_to_range(cidr)
	local ip, bits = tostring(cidr or ''):match('^([^/]+)/(%d+)$')
	if not ip then
		local u = M.ip_to_u32(cidr)
		if not u then return nil end
		return u, u
	end
	bits = tonumber(bits)
	local u = M.ip_to_u32(ip)
	if not u or not bits or bits < 0 or bits > 32 or bits % 1 ~= 0 then return nil end
	if bits == 0 then return 0, 4294967295 end
	local span = 2 ^ (32 - bits)
	local start = math.floor(u / span) * span
	return start, start + span - 1
end

-- Insert [s,e] into non-overlapping list; existing ranges win (first-priority).
function M.insert_range(list, s, e, label)
	if not s or not e or s > e or not label or label == '' then return list end
	list = list or {}
	local out = {}
	local i = 1
	while i <= #list and list[i].e < s do
		out[#out + 1] = list[i]
		i = i + 1
	end
	local cur = s
	while i <= #list and list[i].s <= e do
		local r = list[i]
		if cur < r.s then
			local tip = math.min(e, r.s - 1)
			if cur <= tip then out[#out + 1] = { s = cur, e = tip, label = label } end
		end
		out[#out + 1] = r
		cur = math.max(cur, r.e + 1)
		i = i + 1
		if cur > e then break end
	end
	if cur <= e then out[#out + 1] = { s = cur, e = e, label = label } end
	while i <= #list do
		out[#out + 1] = list[i]
		i = i + 1
	end
	return out
end

function M.parse_cidr_lines(text, label, list)
	list = list or {}
	for raw in tostring(text or ''):gmatch('[^\r\n]+') do
		local line = raw:match('^%s*(.-)%s*$')
		if line ~= '' and not line:match('^#') then
			local s, e = M.cidr_to_range(line)
			if s then list = M.insert_range(list, s, e, label) end
		end
	end
	return list
end

-- Build map text from ordered sources: {{label=, text=}|{label=, path=}, ...}
function M.build_map(sources)
	local list = {}
	for _, src in ipairs(sources or {}) do
		local text = src.text
		if not text and src.path then
			local f = io.open(src.path, 'r')
			if f then text = f:read('*a'); f:close() end
		end
		if text and src.label then
			list = M.parse_cidr_lines(text, src.label, list)
		end
	end
	local lines = { '# netmonitor services.map — generated, do not edit',
		'# label|start_ip|end_ip' }
	for _, r in ipairs(list) do
		lines[#lines + 1] = string.format('%s|%s|%s', r.label, M.u32_to_ip(r.s), M.u32_to_ip(r.e))
	end
	return table.concat(lines, '\n') .. '\n', #list
end

function M.parse_map(text)
	local ranges = {}
	for line in tostring(text or ''):gmatch('[^\r\n]+') do
		if not line:match('^%s*#') and line:match('%S') then
			local lab, a, b = line:match('^([^|]+)|([^|]+)|([^|]+)%s*$')
			if lab then
				local s, e = M.ip_to_u32(a:match('^%s*(.-)%s*$')), M.ip_to_u32(b:match('^%s*(.-)%s*$'))
				lab = lab:match('^%s*(.-)%s*$')
				if s and e and lab ~= '' and s <= e then
					ranges[#ranges + 1] = { s = s, e = e, label = lab }
				end
			end
		end
	end
	return ranges
end

local function load_path(state, path)
	local st = file_stat(path)
	if not st or not st.size or st.size < M.MIN_BYTES then return nil, 'missing_map' end
	if state.ranges and state.path == path and state.mtime == st.mtime then
		return state.ranges
	end
	local f = io.open(path, 'r')
	if not f then return nil, 'open_failed' end
	local text = f:read('*a')
	f:close()
	local ranges = M.parse_map(text)
	state.ranges, state.path, state.mtime = ranges, path, st.mtime
	return ranges
end

function M.lookup(state, ip, cfg)
	if (tonumber(cfg and cfg.service_enable) or 1) == 0 then return nil end
	local u = M.ip_to_u32(ip)
	if not u then
		state.misses = (state.misses or 0) + 1
		return nil
	end
	local path = (cfg and cfg.service_path ~= '' and cfg.service_path) or M.DEFAULT_PATH
	local ranges, err = load_path(state, path)
	if not ranges then
		state.last_error = err
		state.misses = (state.misses or 0) + 1
		return nil
	end
	-- Binary search: rightmost range with s <= u, then verify e >= u.
	-- Ranges are non-overlapping after build, so at most one hit.
	local lo, hi, idx = 1, #ranges, nil
	while lo <= hi do
		local mid = math.floor((lo + hi) / 2)
		if ranges[mid].s <= u then
			idx = mid
			lo = mid + 1
		else
			hi = mid - 1
		end
	end
	if idx and ranges[idx].e >= u then
		state.hits = (state.hits or 0) + 1
		return ranges[idx].label
	end
	state.misses = (state.misses or 0) + 1
	return nil
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

function M.status(state, cfg)
	local enabled = (tonumber(cfg and cfg.service_enable) or 1) ~= 0
	local path = (cfg and cfg.service_path ~= '' and cfg.service_path) or M.DEFAULT_PATH
	local st = file_stat(path)
	local ranges_n = 0
	if state and state.ranges and state.path == path then
		ranges_n = #state.ranges
	elseif st then
		local tmp = M.new()
		local r = load_path(tmp, path)
		ranges_n = r and #r or 0
	end
	return {
		enabled = enabled,
		available = enabled and st ~= nil and (st.size or 0) >= M.MIN_BYTES,
		path = path,
		size = st and st.size or 0,
		mtime = st and st.mtime or nil,
		ranges = ranges_n,
		hits = state and state.hits or 0,
		misses = state and state.misses or 0,
		auto_update = (tonumber(cfg and cfg.service_auto_update) or 0) ~= 0,
		week_time = tostring((cfg and cfg.service_week_time) or '*'),
		day_time = tonumber(cfg and cfg.service_day_time) or 5,
		update = M.read_status(),
	}
end

function M.sync_cron(cfg, runner)
	runner = runner or os.execute
	local enable = (tonumber(cfg.service_auto_update) or 0) ~= 0
		and (tonumber(cfg.service_enable) or 1) ~= 0
	local hour = tonumber(cfg.service_day_time) or 5
	if hour < 0 or hour > 23 then hour = 5 end
	local week = tostring(cfg.service_week_time or '*')
	if week ~= '*' then
		local w = tonumber(week)
		if not w or w < 0 or w > 6 then week = '*' end
	end
	local line = string.format(
		'0 %d * * %s /usr/sbin/netmonitor-service-update >/dev/null 2>&1 # %s',
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

function M.start_update(cfg, runner)
	runner = runner or os.execute
	local cur = M.read_status()
	if cur and cur.state == 'running' then
		local ts = tonumber(cur.ts) or 0
		if os.time() - ts < 600 then
			return { ok = true, started = false, busy = true }
		end
	end
	M.write_status({ state = 'running', ts = os.time(), error = '', bytes = 0, ranges = 0 })
	local path = (cfg.service_path ~= '' and cfg.service_path) or M.DEFAULT_PATH
	local cmd = string.format(
		'/usr/sbin/netmonitor-service-update --path %s >/tmp/netmonitor-service-update.log 2>&1 &',
		string.format('%q', path))
	runner(cmd)
	return { ok = true, started = true }
end

-- CLI entry for the shell updater: argv paths via env NM_SERVICE_BUILD_LIST
-- Format of list file: label<TAB>path per line
function M.cli_build()
	local list_path = os.getenv('NM_SERVICE_BUILD_LIST')
	local out_path = os.getenv('NM_SERVICE_BUILD_OUT')
	if not list_path or not out_path then
		io.stderr:write('NM_SERVICE_BUILD_LIST / NM_SERVICE_BUILD_OUT required\n')
		os.exit(2)
	end
	local f = io.open(list_path, 'r')
	if not f then os.exit(1) end
	local sources = {}
	for line in f:lines() do
		local label, path = line:match('^([^\t]+)\t(.+)$')
		if label and path then sources[#sources + 1] = { label = label, path = path } end
	end
	f:close()
	local text, n = M.build_map(sources)
	local dir = out_path:match('^(.+)/[^/]+$')
	if dir then os.execute('mkdir -p ' .. string.format('%q', dir)) end
	local tmp = out_path .. '.tmp'
	local o = io.open(tmp, 'w')
	if not o then os.exit(1) end
	o:write(text)
	o:close()
	os.rename(tmp, out_path)
	io.write(tostring(n) .. '\n')
end

return M
