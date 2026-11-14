-- DNS-only destination attribution from the dnsmasq query log (ADR-002).
local M = {}

M.QUERY_TTL = 60          -- seconds a query waits for its answers
M.ANSWER_TTL = 24 * 3600  -- seconds an IP->name mapping stays valid
M.MAX_LOG = 1024 * 1024   -- truncate the tmpfs log beyond this size

function M.new()
	return { queries = {}, by_ip = {}, by_client = {}, chain = nil, offset = 0 }
end

local function is_ip(v)
	return v:match('^%d+%.%d+%.%d+%.%d+$') ~= nil
		or (v:find(':', 1, true) ~= nil and v:match('^[%x:%.]+$') ~= nil)
end

-- Feed log lines. CNAME chains are attributed to the name the client asked
-- for, so "reply a.com is <CNAME>" + "reply cdn.net is 1.2.3.4" maps the IP
-- to a.com.
function M.feed(state, text, now)
	for line in tostring(text or ''):gmatch('[^\n]+') do
		local qname, client = line:match('query%[[%w]+%]%s+(%S+)%s+from%s+(%S+)')
		if qname then
			state.queries[qname:lower()] = { client = client, ts = now }
		else
			local verb, name, value = line:match('%s(%a+)%s+(%S+)%s+is%s+(%S+)%s*$')
			if verb == 'reply' or verb == 'cached' then
				name = name:lower()
				local q = state.queries[name]
				local c = state.chain
				if q then
					c = { root = name, client = q.client }
				elseif not (c and (c.cname_pending or c.current == name)) then
					c = { root = name }
				end
				c.current = name
				c.cname_pending = (value == '<CNAME>')
				state.chain = c
				if is_ip(value) then
					state.by_ip[value] = { name = c.root, ts = now }
					if c.client then
						state.by_client[c.client .. '|' .. value] = { name = c.root, ts = now }
					end
				end
			end
		end
	end
end

function M.lookup(state, client_ip, ip, now)
	local hit = state.by_client[(client_ip or '') .. '|' .. ip] or state.by_ip[ip]
	if hit and (not now or now - hit.ts <= M.ANSWER_TTL) then return hit.name end
	return nil
end

function M.prune(state, now)
	for k, q in pairs(state.queries) do
		if now - q.ts > M.QUERY_TTL then state.queries[k] = nil end
	end
	for _, tbl in ipairs({ state.by_ip, state.by_client }) do
		for k, v in pairs(tbl) do
			if now - v.ts > M.ANSWER_TTL then tbl[k] = nil end
		end
	end
end

-- Tail the log from the saved offset; truncate when it grows too large.
function M.read_log(state, path)
	local f = io.open(path, 'r')
	if not f then return '' end
	local size = f:seek('end')
	if size < state.offset then state.offset = 0 end
	f:seek('set', state.offset)
	local text = f:read('*a') or ''
	f:close()
	local last_nl = text:match('.*()\n')
	if not last_nl then return '' end
	state.offset = state.offset + last_nl
	text = text:sub(1, last_nl)
	-- Rotate without unlink: dnsmasq keeps the old inode if we os.remove(); the new
	-- empty path then stays forever empty (all targets 「未解析」). Truncate in place
	-- and ask dnsmasq to reopen via HUP when possible.
	if state.offset >= M.MAX_LOG then
		local w = io.open(path, 'w')
		if w then w:close() end
		state.offset = 0
		os.execute('/etc/init.d/dnsmasq reload >/dev/null 2>&1 || killall -HUP dnsmasq 2>/dev/null || true')
	end
	return text
end

-- Runtime health for DNS attribution (F6): missing log → more IP+未解析.
function M.health(path)
	if type(path) ~= 'string' or path == '' then
		return { ok = false, warning = 'dns_log_missing' }
	end
	local f = io.open(path, 'r')
	if not f then return { ok = false, warning = 'dns_log_missing' } end
	f:close()
	return { ok = true }
end

-- Destination identity for a remote IP (domain preferred, else IP).
-- Optional sni_hit: { name=, source='sni'|'http_host' } from the SNI probe cache.
-- Optional service_label: cloud/CDN CIDR hit (never overrides DNS/SNI).
-- Optional asn_name: GeoLite2-ASN org (tag only; display stays IP).
function M.target_for(state, client_ip, ip, now, sni_hit, service_label, asn_name)
	local name = M.lookup(state, client_ip, ip, now)
	if name then
		return { key = name, kind = 'domain', display = name, ip = ip,
			unresolved = 0, source = 'dns' }
	end
	if sni_hit and sni_hit.name then
		local src = sni_hit.source or 'sni'
		return { key = sni_hit.name, kind = 'domain', display = sni_hit.name, ip = ip,
			unresolved = 0, source = src }
	end
	if service_label and service_label ~= '' then
		return { key = ip, kind = 'ip', display = service_label, ip = ip,
			unresolved = 0, source = 'service' }
	end
	if asn_name and asn_name ~= '' then
		-- Keep IP as session key and display so ASN orgs do not mega-merge.
		return { key = ip, kind = 'ip', display = ip, ip = ip,
			unresolved = 0, source = 'asn', asn_org = asn_name }
	end
	return { key = ip, kind = 'ip', display = ip, ip = ip, unresolved = 1, source = 'ip' }
end

function M.load_persisted(state, rows, now)
	for _, r in ipairs(rows or {}) do
		if r.ip and r.name and (r.source == 'dns' or not r.source) then
			local ts = tonumber(r.updated_at) or now or 0
			if not state.by_ip[r.ip] or (state.by_ip[r.ip].ts or 0) < ts then
				state.by_ip[r.ip] = { name = r.name, ts = ts, persisted = ts }
			end
		end
	end
end

return M
