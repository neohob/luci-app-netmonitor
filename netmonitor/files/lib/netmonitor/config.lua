-- UCI-backed configuration for netmonitor.main.
local timeutil = require 'netmonitor.timeutil'

local M = {}

M.DEFAULTS = {
	enabled = 1,
	db_path = '',
	interval = 5,
	idle_gap = 60,
	retention_value = 30,
	retention_unit = 'day',
	reserve_min_mb = 100,
	reserve_pct = 5,
	lan_ifaces = 'br-lan',
	dns_log = '/tmp/netmonitor-dnsmasq.log',
	manage_dnsmasq = 1,
	enable_acct = 1,
	sni_enable = 1,
}

local NUMERIC = {
	enabled = true, interval = true, idle_gap = true, retention_value = true,
	reserve_min_mb = true, reserve_pct = true, manage_dnsmasq = true, enable_acct = true,
	sni_enable = true,
}

-- Settable from the UI; everything else is UCI-only.
M.SETTABLE = { db_path = true, interval = true, idle_gap = true,
	retention_value = true, retention_unit = true, enabled = true, sni_enable = true }

local function shell_quote(s)
	return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end
M.shell_quote = shell_quote

function M.normalize(raw)
	local cfg = {}
	for k, v in pairs(M.DEFAULTS) do cfg[k] = v end
	for k, v in pairs(raw or {}) do
		if M.DEFAULTS[k] ~= nil then
			if NUMERIC[k] then cfg[k] = tonumber(v) or M.DEFAULTS[k]
			else cfg[k] = tostring(v) end
		end
	end
	return cfg
end

-- Read netmonitor.main via `uci show`; `reader` may be injected for tests.
function M.load(reader)
	local raw = {}
	local text = reader and reader() or nil
	if not text then
		local p = io.popen('uci -q show netmonitor.main 2>/dev/null')
		text = p and p:read('*a') or ''
		if p then p:close() end
	end
	for k, v in text:gmatch("netmonitor%.main%.([%w_]+)='([^\n]*)'") do
		raw[k] = v:gsub("'\\''", "'")
	end
	return M.normalize(raw)
end

-- Validate a patch against the current config; returns merged cfg or err.
function M.validate(cur, patch)
	local cfg = {}
	for k, v in pairs(cur) do cfg[k] = v end
	for k, v in pairs(patch or {}) do
		if not M.SETTABLE[k] then return nil, 'unknown_option:' .. k end
		cfg[k] = v
	end
	cfg = M.normalize(cfg)
	if cfg.interval < 1 or cfg.interval > 60 then return nil, 'bad_interval' end
	if cfg.idle_gap < 2 * cfg.interval or cfg.idle_gap > 3600 then return nil, 'bad_idle_gap' end
	if cfg.retention_value < 1 or cfg.retention_value % 1 ~= 0 then return nil, 'bad_retention' end
	if not timeutil.UNITS[cfg.retention_unit] then return nil, 'bad_retention_unit' end
	if cfg.db_path ~= '' and not cfg.db_path:match('^/') then return nil, 'path_not_absolute' end
	return cfg
end

-- Persist settable keys; `runner` (shell executor) may be injected for tests.
function M.save(cfg, runner)
	runner = runner or os.execute
	local cmds = {}
	for k in pairs(M.SETTABLE) do
		cmds[#cmds + 1] = string.format('uci -q set netmonitor.main.%s=%s', k, shell_quote(cfg[k]))
	end
	table.sort(cmds)
	cmds[#cmds + 1] = 'uci -q commit netmonitor'
	return runner(table.concat(cmds, ' && '))
end

return M
