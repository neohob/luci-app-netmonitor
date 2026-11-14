-- LAN identity sources: `ip neigh`, DHCP leases, router's own addresses.
local M = {}

M.LEASES = '/tmp/dhcp.leases'

local function iface_set(lan_ifaces)
	local set = {}
	for i in tostring(lan_ifaces or ''):gmatch('[^%s,]+') do set[i] = true end
	return set
end

-- `ip neigh show` lines: "<ip> dev <if> lladdr <mac> <STATE>"
function M.parse_neigh(text, lan_ifaces)
	local ifs = iface_set(lan_ifaces)
	local map = {}
	for line in tostring(text or ''):gmatch('[^\n]+') do
		local ip, dev, mac = line:match('^(%S+)%s+dev%s+(%S+)%s+lladdr%s+(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)')
		if ip and ifs[dev] and not line:match('FAILED') then
			map[ip] = mac:lower()
		end
	end
	return map
end

-- dnsmasq lease lines: "<expiry> <mac> <ip> <hostname|*> <clientid>"
function M.parse_leases(text)
	local by_mac, by_ip = {}, {}
	for line in tostring(text or ''):gmatch('[^\n]+') do
		local _, mac, ip, host = line:match('^(%d+)%s+(%S+)%s+(%S+)%s+(%S+)')
		if mac then
			mac = mac:lower()
			local h = (host ~= '*') and host or nil
			by_mac[mac] = { ip = ip, hostname = h }
			by_ip[ip] = mac
		end
	end
	return by_mac, by_ip
end

-- `ip -o addr show` lines: "2: br-lan    inet 192.168.1.1/24 ..."
function M.parse_addrs(text)
	local set = {}
	for line in tostring(text or ''):gmatch('[^\n]+') do
		local addr = line:match('%sinet6?%s+([^/%s]+)')
		if addr then set[addr] = true end
	end
	return set
end

local function read_cmd(cmd)
	local p = io.popen(cmd .. ' 2>/dev/null')
	if not p then return '' end
	local out = p:read('*a')
	p:close()
	return out
end

local function read_file(path)
	local f = io.open(path, 'r')
	if not f then return '' end
	local out = f:read('*a')
	f:close()
	return out
end

-- Live sources on the router; tests pass text fixtures to the parse_* calls.
function M.snapshot(lan_ifaces)
	local leases_by_mac, leases_by_ip = M.parse_leases(read_file(M.LEASES))
	return {
		neigh = M.parse_neigh(read_cmd('ip neigh show'), lan_ifaces),
		leases = leases_by_mac,
		lease_ip = leases_by_ip,
		own = M.parse_addrs(read_cmd('ip -o addr show')),
	}
end

-- MAC for a LAN IP, or nil when the IP is not a LAN client.
function M.mac_for(snap, ip)
	return snap.neigh[ip] or snap.lease_ip[ip]
end

return M
