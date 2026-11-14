-- Storage path validation and free-space write guard (ADR-005).
local config = require 'netmonitor.config'

local M = {}

local MiB = 1024 * 1024

M.DB_NAME = 'netmonitor.db'

function M.db_file(dir)
	return (dir:gsub('/+$', '')) .. '/' .. M.DB_NAME
end

function M.parse_df(text)
	local last
	for line in tostring(text or ''):gmatch('[^\n]+') do last = line end
	if not last then return nil end
	local fs, blocks, used, avail, _, mount =
		last:match('^(%S+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%S+)%s+(.-)%s*$')
	if not fs then return nil end
	return {
		fs = fs, mount = mount,
		total = tonumber(blocks) * 1024,
		used = tonumber(used) * 1024,
		free = tonumber(avail) * 1024,
	}
end

function M.statfs(path)
	local p = io.popen('df -Pk ' .. config.shell_quote(path) .. ' 2>/dev/null')
	if not p then return nil end
	local out = p:read('*a')
	p:close()
	return M.parse_df(out)
end

-- Resolve symlink path; nil if missing. Prefer realpath, then readlink -f.
function M.realpath(path, runner)
	runner = runner or function(cmd)
		local p = io.popen(cmd)
		if not p then return nil end
		local out = p:read('*l')
		p:close()
		return out
	end
	local q = config.shell_quote(path)
	local out = runner('realpath ' .. q .. ' 2>/dev/null')
		or runner('readlink -f ' .. q .. ' 2>/dev/null')
	if out and out ~= '' then return out end
	return nil
end

-- Writes pause when free space drops below max(reserve_min_mb, reserve_pct%).
function M.reserve_bytes(total, cfg)
	local floor_b = (cfg.reserve_min_mb or 100) * MiB
	local pct_b = total * (cfg.reserve_pct or 5) / 100
	return math.max(floor_b, pct_b)
end

-- Free-space gate for the collector. statfs failure is unavailable, not
-- "disk full" (F3).
function M.check(path, cfg, statfs)
	local st = (statfs or M.statfs)(path)
	if not st then
		return { ok = false, paused = false, unavailable = true, error = 'statfs_failed' }
	end
	local reserve = M.reserve_bytes(st.total, cfg)
	return {
		ok = st.free >= reserve,
		paused = st.free < reserve,
		unavailable = false,
		free = st.free, total = st.total, reserve = reserve,
		fs = st.fs, mount = st.mount,
	}
end

local function default_fsops()
	return {
		mkdir = function(dir)
			return os.execute('mkdir -p ' .. config.shell_quote(dir) .. ' 2>/dev/null')
		end,
		probe_write = function(dir)
			local probe = dir .. '/.netmonitor-probe'
			local f = io.open(probe, 'w')
			if not f then return false end
			local ok = f:write('ok') and true
			f:close()
			os.remove(probe)
			return ok
		end,
		statfs = M.statfs,
		realpath = M.realpath,
		-- Read-only: directory exists and is writable (no mkdir / no create).
		is_dir = function(dir)
			local p = io.popen('test -d ' .. config.shell_quote(dir) .. ' && echo yes')
			local out = p and p:read('*l')
			if p then p:close() end
			return out == 'yes'
		end,
		is_writable = function(dir)
			local p = io.popen('test -w ' .. config.shell_quote(dir) .. ' && echo yes')
			local out = p and p:read('*l')
			if p then p:close() end
			return out == 'yes'
		end,
	}
end

local function basic_path_ok(dir, res)
	if type(dir) ~= 'string' or dir == '' then res.error = 'need_path'; return false end
	if not dir:match('^/') then res.error = 'path_not_absolute'; return false end
	if dir:match('%.%.') then res.error = 'path_invalid'; return false end
	return true
end

local function apply_space_and_warnings(res, st, cfg)
	res.free, res.total, res.fs, res.mount = st.free, st.total, st.fs, st.mount
	res.reserve = M.reserve_bytes(st.total, cfg)
	if st.free < res.reserve then res.error = 'insufficient_space'; return false end
	local mount = st.mount or ''
	if mount == '/' or mount == '/overlay' or mount == '/rom' or (st.fs and st.fs:match('overlay')) then
		res.warnings[#res.warnings + 1] = 'overlay'
	end
	if st.fs == 'tmpfs' or mount == '/tmp' or mount:match('^/tmp/') then
		res.warnings[#res.warnings + 1] = 'volatile'
	end
	return true
end

-- Resolve path for safety (F7). Reject if realpath fails for an existing node
-- that is a symlink escape, or if resolved path still contains '..'.
local function resolve_for_check(dir, fsops, res, must_exist)
	local rp_fn = fsops.realpath or M.realpath
	local resolved = rp_fn(dir)
	if resolved then
		if resolved:match('%.%.') then res.error = 'path_invalid'; return nil end
		res.resolved = resolved
		return resolved
	end
	if must_exist then
		res.error = 'path_missing'
		return nil
	end
	-- Parent must resolve when creating a new directory (prepare_path).
	local parent = dir:match('^(.+)/[^/]+/?$') or '/'
	local pref = rp_fn(parent)
	if not pref then res.error = 'path_invalid'; return nil end
	if pref:match('%.%.') then res.error = 'path_invalid'; return nil end
	res.resolved = (pref:gsub('/+$', '')) .. '/' .. (dir:match('([^/]+)/?$') or '')
	return dir
end

-- Read-only path inspection for check_path (F1). Never mkdir / never write.
function M.inspect_path(dir, cfg, fsops)
	fsops = fsops or default_fsops()
	local res = { ok = false, warnings = {} }
	if not basic_path_ok(dir, res) then return res end
	if not resolve_for_check(dir, fsops, res, true) then return res end
	local target = res.resolved or dir
	if not fsops.is_dir(target) then res.error = 'path_missing'; return res end
	if not fsops.is_writable(target) then res.error = 'path_not_writable'; return res end
	local st = fsops.statfs(target)
	if not st then res.error = 'statfs_failed'; return res end
	if not apply_space_and_warnings(res, st, cfg) then return res end
	res.ok = true
	return res
end

-- Mutating validation for prepare_path / set_config / preflight (write ACL).
-- Creates the directory and writes a probe file.
function M.validate_path(dir, cfg, fsops)
	fsops = fsops or default_fsops()
	local res = { ok = false, warnings = {} }
	if not basic_path_ok(dir, res) then return res end
	if not resolve_for_check(dir, fsops, res, false) then return res end
	fsops.mkdir(dir)
	local rp_fn = fsops.realpath or M.realpath
	local resolved = rp_fn(dir)
	if not resolved or resolved:match('%.%.') then
		res.error = 'path_invalid'
		return res
	end
	res.resolved = resolved
	if not fsops.probe_write(resolved) then res.error = 'path_not_writable'; return res end
	local st = fsops.statfs(resolved)
	if not st then res.error = 'statfs_failed'; return res end
	if not apply_space_and_warnings(res, st, cfg) then return res end
	res.ok = true
	return res
end

return M
