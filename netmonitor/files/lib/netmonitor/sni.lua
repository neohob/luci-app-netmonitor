-- Lightweight TLS SNI / HTTP Host extraction from a short tcpdump capture.
-- Soft-dep: tcpdump. Without it, available() is false and callers stay DNS-only.
-- Lua 5.1 compatible (OpenWrt).
local M = {}

M.COOLDOWN_OK = 30 * 60
M.COOLDOWN_FAIL = 10 * 60
M.CAPTURE_SECS = 2
M.CAPTURE_COUNT = 40
M.MAX_PROBE_PER_POLL = 8

function M.new()
	return { by_ip = {}, cooldown = {}, last_probe = 0, stats = { ok = 0, fail = 0, runs = 0 } }
end

function M.available()
	local p = io.popen('command -v tcpdump 2>/dev/null')
	local path = p and p:read('*l') or ''
	if p then p:close() end
	return path ~= nil and path ~= ''
end

local function u16be(s, i)
	local a, b = s:byte(i, i + 1)
	if not a or not b then return nil end
	return a * 256 + b
end

local function u32_le(b, o)
	local a, c, d, e = b:byte(o, o + 3)
	if not e then return nil end
	return a + c * 256 + d * 65536 + e * 16777216
end

local function u32_be(b, o)
	local a, c, d, e = b:byte(o, o + 3)
	if not e then return nil end
	return e + d * 256 + c * 65536 + a * 16777216
end

-- Extract SNI hostname from a TLS record blob.
function M.parse_tls_sni(payload)
	if type(payload) ~= 'string' or #payload < 44 then return nil end
	local i = 1
	while i + 4 <= #payload do
		local ct = payload:byte(i)
		local len = u16be(payload, i + 3)
		if not len or i + 4 + len - 1 > #payload then break end
		if ct == 0x16 and len >= 4 then
			local hs = i + 5
			if payload:byte(hs) == 0x01 then
				local hs_len = payload:byte(hs + 1) * 65536 + (u16be(payload, hs + 2) or 0)
				local body = hs + 4
				local body_end = math.min(hs + 4 + hs_len - 1, i + 4 + len)
				local p = body + 2 + 32
				if p <= body_end then
					local sid_len = payload:byte(p) or 0
					p = p + 1 + sid_len
					if p + 1 <= body_end then
						local cs_len = u16be(payload, p) or 0
						p = p + 2 + cs_len
						if p <= body_end then
							local comp_len = payload:byte(p) or 0
							p = p + 1 + comp_len
							if p + 1 <= body_end then
								local ext_len = u16be(payload, p) or 0
								p = p + 2
								local ext_end = math.min(p + ext_len - 1, body_end)
								while p + 3 <= ext_end do
									local etype = u16be(payload, p)
									local elen = u16be(payload, p + 2)
									p = p + 4
									if not etype or not elen or p + elen - 1 > ext_end then break end
									if etype == 0 and elen >= 5 then
										local q = p + 2
										local q_end = p + elen - 1
										while q + 2 <= q_end do
											local ntype = payload:byte(q)
											local nlen = u16be(payload, q + 1)
											q = q + 3
											if not nlen or q + nlen - 1 > q_end then break end
											if ntype == 0 then
												local name = payload:sub(q, q + nlen - 1)
												if name:match('^[%w%._%-]+$') and #name >= 1 and #name <= 253 then
													return name:lower()
												end
											end
											q = q + nlen
										end
									end
									p = p + elen
								end
							end
						end
					end
				end
			end
		end
		i = i + 5 + len
	end
	return nil
end

function M.parse_http_host(payload)
	if type(payload) ~= 'string' or #payload < 10 then return nil end
	local head = payload:sub(1, math.min(2048, #payload))
	if not head:match('^%u+%s+%S+%s+HTTP/') then return nil end
	local host = head:match('\r?\n[Hh][Oo][Ss][Tt]:%s*([%w%._%-]+)')
	if host and #host <= 253 then return host:lower() end
	return nil
end

local function extract_from_frame(data, network)
	local ip_off
	if network == 1 then
		if #data < 14 then return nil end
		if data:byte(13) * 256 + data:byte(14) ~= 0x0800 then return nil end
		ip_off = 15
	elseif network == 113 then
		ip_off = 17
	elseif network == 12 then
		ip_off = 1
	else
		if #data >= 14 and data:byte(13) * 256 + data:byte(14) == 0x0800 then
			ip_off = 15
		else
			return nil
		end
	end
	if #data < ip_off + 20 then return nil end
	local ihl = (data:byte(ip_off) % 16) * 4
	if ihl < 20 then return nil end
	if data:byte(ip_off + 9) ~= 6 then return nil end
	local dst = string.format('%d.%d.%d.%d',
		data:byte(ip_off + 16), data:byte(ip_off + 17),
		data:byte(ip_off + 18), data:byte(ip_off + 19))
	local tcp_off = ip_off + ihl
	if #data < tcp_off + 13 then return nil end
	local doff = math.floor(data:byte(tcp_off + 12) / 16) * 4
	local payload = data:sub(tcp_off + doff)
	local dport = data:byte(tcp_off + 2) * 256 + data:byte(tcp_off + 3)
	local name, source
	if dport == 443 then
		name = M.parse_tls_sni(payload)
		source = name and 'sni' or nil
	elseif dport == 80 then
		name = M.parse_http_host(payload)
		source = name and 'http_host' or nil
	else
		name = M.parse_tls_sni(payload)
		if name then source = 'sni'
		else
			name = M.parse_http_host(payload)
			source = name and 'http_host' or nil
		end
	end
	if name and source then return dst, name, source end
	return nil
end

function M.parse_pcap(path)
	local f = io.open(path, 'rb')
	if not f then return {} end
	local gh = f:read(24)
	if not gh or #gh < 24 then f:close(); return {} end
	local magic = u32_le(gh, 1)
	local swap = (magic == 0xD4C3B2A1)
	local function u32(b, o)
		return swap and u32_be(b, o) or u32_le(b, o)
	end
	local network = u32(gh, 21)
	local hits = {}
	while true do
		local ph = f:read(16)
		if not ph or #ph < 16 then break end
		local incl = u32(ph, 9)
		if not incl or incl <= 0 or incl > 65535 then break end
		local data = f:read(incl)
		if not data or #data < incl then break end
		local dst, name, source = extract_from_frame(data, network)
		if dst then hits[dst] = { name = name, source = source } end
	end
	f:close()
	return hits
end

function M.lookup(state, ip, now)
	local hit = state.by_ip[ip]
	if hit and (not now or now - hit.ts <= 24 * 3600) then return hit end
	return nil
end

function M.remember(state, ip, name, source, now)
	state.by_ip[ip] = { name = name, source = source, ts = now }
	state.cooldown[ip] = now + M.COOLDOWN_OK
	state.stats.ok = (state.stats.ok or 0) + 1
end

function M.feed_hits(state, hits, now)
	for ip, h in pairs(hits or {}) do
		M.remember(state, ip, h.name, h.source, now)
	end
end

local function in_cooldown(state, ip, now)
	local until_t = state.cooldown[ip]
	return until_t and now < until_t
end

function M.capture(iface, secs)
	if not M.available() then return {}, 'sni_unavailable' end
	iface = iface and tostring(iface):match('^[%w%._%-]+$') or 'br-lan'
	secs = tonumber(secs) or M.CAPTURE_SECS
	local pcap = '/tmp/netmonitor-sni.' .. tostring(math.floor(os.time())) .. '.pcap'
	local cmd = string.format(
		'timeout %d tcpdump -i %s -c %d -nn -s 0 -w %s "tcp dst port 443 or tcp dst port 80" >/dev/null 2>&1',
		secs, iface, M.CAPTURE_COUNT, pcap)
	os.execute(cmd)
	local hits = M.parse_pcap(pcap)
	os.remove(pcap)
	return hits
end

function M.probe_unresolved(state, unresolved_ips, cfg, now)
	if (tonumber(cfg.sni_enable) or 1) == 0 then
		return { skipped = true, reason = 'disabled' }
	end
	if not M.available() then
		return { skipped = true, reason = 'sni_unavailable' }
	end
	local want = {}
	for _, ip in ipairs(unresolved_ips or {}) do
		if not in_cooldown(state, ip, now) and not state.by_ip[ip] then
			want[#want + 1] = ip
			if #want >= M.MAX_PROBE_PER_POLL then break end
		end
	end
	if #want == 0 then return { skipped = true, reason = 'nothing' } end
	if state.last_probe and now - state.last_probe < math.max(cfg.interval or 5, 5) then
		return { skipped = true, reason = 'rate' }
	end
	state.last_probe = now
	state.stats.runs = (state.stats.runs or 0) + 1
	local iface = (cfg.lan_ifaces or 'br-lan'):match('^[%w%._%-]+') or 'br-lan'
	local hits = M.capture(iface, M.CAPTURE_SECS)
	M.feed_hits(state, hits, now)
	local found = 0
	for _ in pairs(hits) do found = found + 1 end
	for _, ip in ipairs(want) do
		if not hits[ip] then
			state.cooldown[ip] = now + M.COOLDOWN_FAIL
			state.stats.fail = (state.stats.fail or 0) + 1
		end
	end
	return { skipped = false, found = found, wanted = #want }
end

function M.status(state, cfg)
	local en = (tonumber(cfg and cfg.sni_enable) or 1) ~= 0
	local avail = M.available()
	return {
		enabled = en,
		available = avail,
		mode = (not en and 'disabled') or (avail and 'sni_unresolved') or 'dns_only',
		ok = state and state.stats and state.stats.ok or 0,
		fail = state and state.stats and state.stats.fail or 0,
		runs = state and state.stats and state.stats.runs or 0,
	}
end

return M
