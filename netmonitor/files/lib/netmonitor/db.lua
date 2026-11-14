-- SQLite access through the sqlite3 CLI (package sqlite3-cli).
local json = require 'netmonitor.json'
local config = require 'netmonitor.config'

local M = {}

-- Production default; tests may assign M.SQLITE (F18: no env override in package).
M.SQLITE = 'sqlite3'

function M.quote(v)
	local t = type(v)
	if v == nil then return 'NULL' end
	if t == 'number' then
		if v % 1 == 0 then return string.format('%.0f', v) end
		return string.format('%.6f', v)
	end
	if t == 'boolean' then return v and '1' or '0' end
	return "'" .. tostring(v):gsub("'", "''") .. "'"
end

function M.exists(path)
	local f = io.open(path, 'r')
	if f then f:close() return true end
	return false
end

local function run(path, sql, mode)
	local tmp = os.tmpname()
	local f = assert(io.open(tmp, 'w'))
	f:write(sql)
	f:close()
	local cmd = string.format("%s %s -bail -batch -cmd '.timeout 5000' %s < %s 2>&1; printf '\\nrc=%%s\\n' $?",
		M.SQLITE, mode or '', config.shell_quote(path), config.shell_quote(tmp))
	local p = io.popen(cmd)
	local out = p:read('*a')
	p:close()
	os.remove(tmp)
	local body, rc = out:match('^(.-)\n?\nrc=(%d+)%s*$')
	if not rc then return nil, out end
	if rc ~= '0' then return nil, body end
	return body
end

function M.exec(path, sql)
	local out, err = run(path, sql)
	if not out then return nil, err end
	return true
end

function M.query(path, sql)
	local out, err = run(path, sql, '-json')
	if not out then return nil, err end
	if out:match('^%s*$') then return json.array() end
	local rows, derr = json.decode(out)
	if rows == nil then return nil, derr end
	return rows
end

return M
