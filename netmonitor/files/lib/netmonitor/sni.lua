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
	if not host or #host > 253 then return nil end
	host = host:lower()
	-- Ignore Host: that is already an IP (useless for naming).
	if host:match('^%d+%.%d+%.%d+%.%d+$') then return nil end
	return host
end

-- Parse DNS name at offset; returns name, next_offset (handles compression).
local function dns_name(payload, off, depth)
	depth = depth or 0
	if depth > 8 or off > #payload then return nil, off end
	local labels, jumped = {}, false
	local next_off = off
	while off <= #payload do
		local len = payload:byte(off)
		if not len then return nil, next_off end
		if len == 0 then
			if not jumped then next_off = off + 1 end
			break
		end
		if len >= 0xc0 then
			local b2 = payload:byte(off + 1)
			if not b2 then return nil, next_off end
			local ptr = (len - 0xc0) * 256 + b2
			if not jumped then next_off = off + 2; jumped = true end
			off = ptr + 1
		else
			local lab = payload:sub(off + 1, off + len)
			if #lab < len then return nil, next_off end
			labels[#labels + 1] = lab:lower()
			off = off + 1 + len
			if not jumped then next_off = off end
		end
	end
	if #labels == 0 then return nil, next_off end
	return table.concat(labels, '.'), next_off
end

-- Extract A-record IP→name pairs from a DNS message (response preferred).
function M.parse_dns_message(payload)
	if type(payload) ~= 'string' or #payload < 12 then return {} end
	local flags = u16be(payload, 3)
	if not flags or math.floor(flags / 0x8000) ~= 1 then return {} end -- response only
	local qd = u16be(payload, 5) or 0
	local an = u16be(payload, 7) or 0
	if an < 1 then return {} end
	local off = 13
	local qname
	for _ = 1, qd do
		local n
		n, off = dns_name(payload, off)
		if not n then return {} end
		if not qname then qname = n end
		off = off + 4 -- qtype+qclass
	end
	local out = {}
	for _ = 1, an do
		local n
		n, off = dns_name(payload, off)
		if not n or off + 9 > #payload then break end
		local rtype = u16be(payload, off)
		local rdlen = u16be(payload, off + 8)
		off = off + 10
		if not rtype or not rdlen or off + rdlen - 1 > #payload then break end
		local name = n or qname
		if rtype == 1 and rdlen == 4 and name then -- A
			local a, b, c, d = payload:byte(off, off + 3)
			local ip = string.format('%d.%d.%d.%d', a, b, c, d)
			if not ip:match('^0%.') and not ip:match('^127%.') then
				out[ip] = { name = name, source = 'dns' }
			end
		end
		off = off + rdlen
	end
	return out
end

local function ipv4_at(data, off)
	return string.format('%d.%d.%d.%d',
		data:byte(off), data:byte(off + 1), data:byte(off + 2), data:byte(off + 3))
end

local function extract_from_frame(data, network, hits)
	local ip_off
	if network == 1 then
		if #data < 14 then return end
		if data:byte(13) * 256 + data:byte(14) ~= 0x0800 then return end
		ip_off = 15
	elseif network == 113 then
		ip_off = 17
	elseif network == 12 then
		ip_off = 1
	else
		if #data >= 14 and data:byte(13) * 256 + data:byte(14) == 0x0800 then
			ip_off = 15
		else
			return
		end
	end
	if #data < ip_off + 20 then return end
	local ihl = (data:byte(ip_off) % 16) * 4
	if ihl < 20 then return end
	local proto = data:byte(ip_off + 9)
	local l4 = ip_off + ihl

	if proto == 17 then -- UDP DNS
		if #data < l4 + 8 then return end
		local sport = data:byte(l4) * 256 + data:byte(l4 + 1)
		local dport = data:byte(l4 + 2) * 256 + data:byte(l4 + 3)
		if sport ~= 53 and dport ~= 53 then return end
		local dns_payload = data:sub(l4 + 8)
		for ip, h in pairs(M.parse_dns_message(dns_payload)) do
			hits[ip] = h
		end
		return
	end

	if proto ~= 6 then return end -- TCP
	if #data < l4 + 13 then return end
	local doff = math.floor(data:byte(l4 + 12) / 16) * 4
	local payload = data:sub(l4 + doff)
	local dport = data:byte(l4 + 2) * 256 + data:byte(l4 + 3)
	local dst = ipv4_at(data, ip_off + 16)
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
	if name and source then hits[dst] = { name = name, source = source } end
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
		extract_from_frame(data, network, hits)
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

M.DNS_READY = '/tmp/netmonitor-dns-ready.pcap'
M.DNS_PID = '/var/run/netmonitor/dns-sniff.pid'
M.DNS_SNIFF = '/usr/sbin/netmonitor-dns-sniff'

local function read_pid(path)
	local f = io.open(path, 'r')
	if not f then return nil end
	local n = tonumber((f:read('*l') or ''):match('%d+'))
	f:close()
	return n
end

local function alive(pid)
	if not pid then return false end
	local f = io.open('/proc/' .. tostring(pid) .. '/cmdline', 'r')
	if not f then return false end
	local cmd = f:read('*a') or ''
	f:close()
	return cmd:find('netmonitor-dns-sniff', 1, true) ~= nil
end

-- Start the package-bundled DNS sniffer as a child of the collector (not cron / not a
-- separate init service). Soft-dep: tcpdump + netmonitor-dns-sniff.
function M.start_dns_sniff(cfg, rundir)
	if (tonumber(cfg and cfg.sni_enable) or 1) == 0 then return false, 'disabled' end
	if not M.available() then return false, 'sni_unavailable' end
	local sniff = M.DNS_SNIFF
	local f = io.open(sniff, 'r')
	if not f then return false, 'no_sniff_bin' end
	f:close()
	rundir = rundir or '/var/run/netmonitor'
	os.execute('mkdir -p ' .. rundir)
	local pid = read_pid(M.DNS_PID)
	if alive(pid) then return true, 'already' end
	if pid then os.remove(M.DNS_PID) end
	local iface = ((cfg and cfg.lan_ifaces) or 'br-lan'):match('^[%w%._%-]+') or 'br-lan'
	-- Background child; pid file written by the sniff script itself.
	os.execute(string.format(
		'%s %s >/dev/null 2>&1 &',
		sniff, iface))
	return true, 'started'
end

function M.stop_dns_sniff()
	local pid = read_pid(M.DNS_PID)
	if pid then
		os.execute('kill ' .. tostring(pid) .. ' 2>/dev/null || true')
		os.remove(M.DNS_PID)
	end
	-- Reap leftover capture tcpdump owned by our sniff slices.
	os.execute('pkill -f "tcpdump .*-w /tmp/netmonitor-dns" 2>/dev/null || true')
	os.remove('/tmp/netmonitor-dns-capturing.pcap')
	-- leave ready pcap for one last ingest if any
end

-- Ingest continuous DNS sniffer output (written by netmonitor-dns-sniff child).
function M.ingest_dns_ready(dns_state, now)
	local path = M.DNS_READY
	local f = io.open(path, 'rb')
	if not f then return 0 end
	f:close()
	local hits = M.parse_pcap(path)
	os.remove(path)
	local n = 0
	for ip, h in pairs(hits) do
		if h.source == 'dns' and dns_state then
			dns_state.by_ip[ip] = { name = h.name, ts = now }
			n = n + 1
		end
	end
	return n
end

function M.capture_sni(iface, secs)
	if not M.available() then return {}, 'sni_unavailable' end
	iface = iface and tostring(iface):match('^[%w%._%-]+$') or 'br-lan'
	secs = tonumber(secs) or M.CAPTURE_SECS
	local pcap = '/tmp/netmonitor-sni.' .. tostring(math.floor(os.time())) .. '.pcap'
	local cmd = string.format(
		'timeout %d tcpdump -i %s -c %d -nn -s 0 -w %s '
		.. '"tcp dst port 443 or tcp dst port 80" >/dev/null 2>&1',
		secs, iface, M.CAPTURE_COUNT, pcap)
	os.execute(cmd)
	local hits = M.parse_pcap(pcap)
	os.remove(pcap)
	return hits
end

-- Merge continuous DNS file + occasional SNI/Host probe for unresolved IPs.
function M.probe_unresolved(state, unresolved_ips, cfg, now, dns_state)
	if (tonumber(cfg.sni_enable) or 1) == 0 then
		return { skipped = true, reason = 'disabled' }
	end
	local dns_n = M.ingest_dns_ready(dns_state, now)
	local found, sni_n = dns_n, 0

	if not M.available() then
		return { skipped = dns_n == 0, reason = 'sni_unavailable', found = found, dns = dns_n, sni = 0 }
	end

	local want = {}
	for _, ip in ipairs(unresolved_ips or {}) do
		if not in_cooldown(state, ip, now) and not state.by_ip[ip]
			and not (dns_state and dns_state.by_ip[ip]) then
			want[#want + 1] = ip
			if #want >= M.MAX_PROBE_PER_POLL then break end
		end
	end

	-- SNI probe only when there are unresolved IPs; rate-limited (DNS is continuous).
	if #want > 0 and (not state.last_probe or now - state.last_probe >= math.max(cfg.interval or 5, 5)) then
		state.last_probe = now
		state.stats.runs = (state.stats.runs or 0) + 1
		local iface = (cfg.lan_ifaces or 'br-lan'):match('^[%w%._%-]+') or 'br-lan'
		local hits = M.capture_sni(iface, M.CAPTURE_SECS)
		for ip, h in pairs(hits) do
			if h.source ~= 'dns' then
				M.remember(state, ip, h.name, h.source, now)
				sni_n = sni_n + 1
				found = found + 1
			end
		end
		for _, ip in ipairs(want) do
			if not hits[ip] and not (dns_state and dns_state.by_ip[ip]) then
				state.cooldown[ip] = now + M.COOLDOWN_FAIL
				state.stats.fail = (state.stats.fail or 0) + 1
			end
		end
	end

	if found == 0 and #want == 0 then
		return { skipped = true, reason = 'nothing', found = 0, dns = dns_n, sni = 0 }
	end
	return { skipped = false, found = found, dns = dns_n, sni = sni_n, wanted = #want }
end

function M.status(state, cfg)
	local en = (tonumber(cfg and cfg.sni_enable) or 1) ~= 0
	local avail = M.available()
	local sniff_on = alive(read_pid(M.DNS_PID))
	return {
		enabled = en,
		available = avail,
		dns_sniff = sniff_on,
		mode = (not en and 'disabled')
			or (avail and sniff_on and 'dns_sniff+sni')
			or (avail and 'sni_unresolved')
			or 'dns_only',
		ok = state and state.stats and state.stats.ok or 0,
		fail = state and state.stats and state.stats.fail or 0,
		runs = state and state.stats and state.stats.runs or 0,
	}
end

return M
