-- Parse /proc/net/nf_conntrack (or `conntrack -L`) and compute byte deltas.
local M = {}

M.PATH = '/proc/net/nf_conntrack'

-- Returns entry with orig/reply tuples, or nil for unparsable lines.
function M.parse_line(line)
	local e = { orig = {}, reply = {} }
	local dir
	local l3, proto
	for tok in line:gmatch('%S+') do
		local k, v = tok:match('^([%w_]+)=(.*)$')
		if k then
			if k == 'src' then
				dir = (dir == nil) and e.orig or e.reply
			end
			if dir and (k == 'src' or k == 'dst' or k == 'sport' or k == 'dport'
				or k == 'bytes' or k == 'packets') then
				if k == 'bytes' or k == 'packets' then dir[k] = tonumber(v) else dir[k] = v end
			elseif k == 'zone' then
				e.zone = v
			end
		elseif not dir then
			if tok == 'ipv4' or tok == 'ipv6' then l3 = tok
			elseif not proto and tok:match('^%a[%w%-]*$') then proto = tok end
		end
	end
	if not e.orig.src or not e.reply.src then return nil end
	e.l3 = l3
	e.proto = proto or 'unknown'
	e.has_bytes = e.orig.bytes ~= nil and e.reply.bytes ~= nil
	e.key = table.concat({ e.proto, e.orig.src, e.orig.dst,
		e.orig.sport or '-', e.orig.dport or '-', e.zone or '0' }, '|')
	return e
end

-- Returns entries list and stats { total, with_bytes }.
function M.parse(text)
	local entries, total, with_bytes = {}, 0, 0
	for line in tostring(text or ''):gmatch('[^\n]+') do
		local e = M.parse_line(line)
		if e then
			total = total + 1
			if e.has_bytes then with_bytes = with_bytes + 1 end
			entries[#entries + 1] = e
		end
	end
	return entries, { total = total, with_bytes = with_bytes }
end

-- Degraded when flows exist but none carry byte counters (ADR-008).
function M.degraded(stats, readable)
	if not readable then return true, 'no_conntrack' end
	if stats.total > 0 and stats.with_bytes == 0 then return true, 'no_byte_counters' end
	return false
end

function M.read(path)
	local f = io.open(path or M.PATH, 'r')
	if not f then return nil end
	local text = f:read('*a')
	f:close()
	return text
end

-- Polls a vanished flow keeps its baseline. /proc/net/nf_conntrack reads are
-- not atomic (offloaded long-lived flows drop out of single reads); without
-- the baseline a reappearing flow would count its whole lifetime as a delta.
M.MISS_GRACE = 120

-- Compare against the previous snapshot { [key] = {orig=, reply=, miss=} }.
-- Only keys never seen before contribute their absolute counters. A counter
-- that went backwards rebases with zero delta rather than recounting.
function M.deltas(prev, entries)
	local snap, out = {}, {}
	for _, e in ipairs(entries) do
		if e.has_bytes and not snap[e.key] then
			local p = prev and prev[e.key]
			local d_orig, d_reply = e.orig.bytes, e.reply.bytes
			if p and e.orig.bytes >= p.orig and e.reply.bytes >= p.reply then
				d_orig = e.orig.bytes - p.orig
				d_reply = e.reply.bytes - p.reply
			elseif p then
				d_orig, d_reply = 0, 0
			end
			snap[e.key] = { orig = e.orig.bytes, reply = e.reply.bytes }
			if d_orig > 0 or d_reply > 0 then
				out[#out + 1] = { entry = e, d_orig = d_orig, d_reply = d_reply }
			end
		end
	end
	for k, p in pairs(prev or {}) do
		if not snap[k] then
			local miss = (p.miss or 0) + 1
			if miss <= M.MISS_GRACE then
				snap[k] = { orig = p.orig, reply = p.reply, miss = miss }
			end
		end
	end
	return snap, out
end

return M
