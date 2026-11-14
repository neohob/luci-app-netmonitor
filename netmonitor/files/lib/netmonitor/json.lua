-- Minimal JSON codec (Lua 5.1+). Empty tables encode as []; wrap with
-- json.object() when an empty table must encode as {}.
local M = {}

local array_mt = { __json_array = true }
local object_mt = { __json_object = true }

function M.array(t)
	return setmetatable(t or {}, array_mt)
end

function M.object(t)
	return setmetatable(t or {}, object_mt)
end

local escapes = {
	['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
	['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function encode_string(s)
	return '"' .. s:gsub('[%c"\\]', function(c)
		return escapes[c] or string.format('\\u%04x', c:byte())
	end) .. '"'
end

local function is_array(t)
	local mt = getmetatable(t)
	if mt == array_mt then return true end
	if mt == object_mt then return false end
	local n = 0
	for k in pairs(t) do
		if type(k) ~= 'number' or k <= 0 or k % 1 ~= 0 then return false end
		n = n + 1
	end
	return n == #t
end

local encode

local function encode_number(v)
	if v ~= v or v == math.huge or v == -math.huge then return 'null' end
	if v % 1 == 0 and v > -2^53 and v < 2^53 then
		return string.format('%.0f', v)
	end
	return string.format('%.14g', v)
end

function encode(v)
	local t = type(v)
	if t == 'nil' then return 'null'
	elseif t == 'boolean' then return v and 'true' or 'false'
	elseif t == 'number' then return encode_number(v)
	elseif t == 'string' then return encode_string(v)
	elseif t == 'table' then
		local out = {}
		if is_array(v) then
			for i = 1, #v do out[i] = encode(v[i]) end
			return '[' .. table.concat(out, ',') .. ']'
		end
		local keys = {}
		for k in pairs(v) do keys[#keys + 1] = tostring(k) end
		table.sort(keys)
		for _, k in ipairs(keys) do
			local val = v[k]
			if val == nil then val = v[tonumber(k)] end
			out[#out + 1] = encode_string(k) .. ':' .. encode(val)
		end
		return '{' .. table.concat(out, ',') .. '}'
	end
	error('cannot encode ' .. t)
end

M.encode = encode

local function utf8_char(cp)
	if cp < 0x80 then return string.char(cp) end
	if cp < 0x800 then
		return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
	end
	if cp < 0x10000 then
		return string.char(0xE0 + math.floor(cp / 0x1000),
			0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
	end
	return string.char(0xF0 + math.floor(cp / 0x40000),
		0x80 + math.floor(cp / 0x1000) % 0x40,
		0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

function M.decode(s)
	local pos = 1

	local function fail(msg)
		error(string.format('json: %s at %d', msg, pos))
	end

	local function ws()
		pos = s:find('[^ \t\r\n]', pos) or (#s + 1)
	end

	local value

	local function str()
		pos = pos + 1
		local buf = {}
		while true do
			local c = s:sub(pos, pos)
			if c == '' then fail('unterminated string') end
			if c == '"' then pos = pos + 1; break end
			if c == '\\' then
				local e = s:sub(pos + 1, pos + 1)
				local map = { b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }
				if e == 'u' then
					local cp = tonumber(s:sub(pos + 2, pos + 5), 16)
					if not cp then fail('bad unicode escape') end
					pos = pos + 6
					if cp >= 0xD800 and cp <= 0xDBFF and s:sub(pos, pos + 1) == '\\u' then
						local lo = tonumber(s:sub(pos + 2, pos + 5), 16)
						if lo and lo >= 0xDC00 and lo <= 0xDFFF then
							cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
							pos = pos + 6
						end
					end
					buf[#buf + 1] = utf8_char(cp)
				else
					buf[#buf + 1] = map[e] or e
					pos = pos + 2
				end
			else
				local j = s:find('["\\]', pos) or (#s + 1)
				buf[#buf + 1] = s:sub(pos, j - 1)
				pos = j
			end
		end
		return table.concat(buf)
	end

	function value()
		ws()
		local c = s:sub(pos, pos)
		if c == '{' then
			pos = pos + 1
			local obj = M.object()
			ws()
			if s:sub(pos, pos) == '}' then pos = pos + 1; return obj end
			while true do
				ws()
				if s:sub(pos, pos) ~= '"' then fail('expected key') end
				local k = str()
				ws()
				if s:sub(pos, pos) ~= ':' then fail('expected :') end
				pos = pos + 1
				obj[k] = value()
				ws()
				local d = s:sub(pos, pos)
				pos = pos + 1
				if d == '}' then return obj end
				if d ~= ',' then fail('expected , or }') end
			end
		elseif c == '[' then
			pos = pos + 1
			local arr = M.array()
			ws()
			if s:sub(pos, pos) == ']' then pos = pos + 1; return arr end
			while true do
				arr[#arr + 1] = value()
				ws()
				local d = s:sub(pos, pos)
				pos = pos + 1
				if d == ']' then return arr end
				if d ~= ',' then fail('expected , or ]') end
			end
		elseif c == '"' then
			return str()
		elseif s:sub(pos, pos + 3) == 'true' then pos = pos + 4; return true
		elseif s:sub(pos, pos + 4) == 'false' then pos = pos + 5; return false
		elseif s:sub(pos, pos + 3) == 'null' then pos = pos + 4; return nil
		else
			local num = s:match('^-?%d+%.?%d*[eE]?[-+]?%d*', pos)
			if not num or num == '' then fail('unexpected character') end
			pos = pos + #num
			return tonumber(num)
		end
	end

	local ok, res = pcall(function()
		local v = value()
		ws()
		if pos <= #s then fail('trailing data') end
		return v
	end)
	if not ok then return nil, res end
	return res
end

return M
