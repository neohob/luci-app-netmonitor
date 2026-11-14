package.path = './netmonitor/files/lib/?.lua;./tests/lua/?.lua;' .. package.path
local H = require 'helper'
local service = require 'netmonitor.service'
local dns = require 'netmonitor.dns'

H.case('SVC1', 'cidr_to_range and ip_to_u32', function()
	H.eq(service.ip_to_u32('1.2.3.4'), 16909060)
	local s, e = service.cidr_to_range('1.1.1.0/24')
	H.eq(s, service.ip_to_u32('1.1.1.0'))
	H.eq(e, service.ip_to_u32('1.1.1.255'))
	s, e = service.cidr_to_range('8.8.8.8')
	H.eq(s, e)
end)

H.case('SVC2', 'first-priority wins on overlap', function()
	local text = select(1, service.build_map({
		{ label = 'Cloudflare', text = '1.1.1.0/24\n' },
		{ label = 'Other', text = '1.1.1.0/25\n' },
	}))
	local dir = H.tmpdir()
	local path = dir .. '/services.map'
	local f = assert(io.open(path, 'w')); f:write(text); f:close()
	local st = service.new()
	H.eq(service.lookup(st, '1.1.1.10', { service_enable = 1, service_path = path }), 'Cloudflare')
	H.rmrf(dir)
end)

H.case('SVC3', 'lookup hit/miss and enable gate', function()
	local text = select(1, service.build_map({
		{ label = '字节跳动', text = '10.0.0.0/8\n' },
		{ label = 'AWS', text = '3.0.0.0/8\n' },
	}))
	local dir = H.tmpdir()
	local path = dir .. '/services.map'
	local f = assert(io.open(path, 'w')); f:write(text); f:close()
	local st = service.new()
	H.eq(service.lookup(st, '10.1.2.3', { service_enable = 1, service_path = path }), '字节跳动')
	H.eq(service.lookup(st, '3.5.6.7', { service_enable = 1, service_path = path }), 'AWS')
	H.eq(service.lookup(st, '8.8.8.8', { service_enable = 1, service_path = path }), nil)
	H.eq(service.lookup(st, '10.1.2.3', { service_enable = 0, service_path = path }), nil)
	H.rmrf(dir)
end)

H.case('SVC4', 'dns.target_for prefers DNS then SNI then service then ASN', function()
	local st = dns.new()
	st.by_ip['1.1.1.1'] = { name = 'one.one.one.one', ts = 100 }
	local t = dns.target_for(st, '10.0.0.2', '1.1.1.1', 100, nil, 'Cloudflare', 'CLOUDFLARE')
	H.eq(t.source, 'dns')
	H.eq(t.display, 'one.one.one.one')
	t = dns.target_for(dns.new(), '10.0.0.2', '8.8.8.8', 100,
		{ name = 'dns.google', source = 'sni' }, 'Google Cloud', 'GOOGLE')
	H.eq(t.source, 'sni')
	t = dns.target_for(dns.new(), '10.0.0.2', '8.8.8.8', 100, nil, 'Google Cloud', 'GOOGLE')
	H.eq(t.source, 'service')
	H.eq(t.display, 'Google Cloud')
	H.eq(t.key, '8.8.8.8')
	t = dns.target_for(dns.new(), '10.0.0.2', '8.8.8.8', 100, nil, nil, 'GOOGLE')
	H.eq(t.source, 'asn')
	H.eq(t.display, '8.8.8.8')
	H.eq(t.asn_org, 'GOOGLE')
end)
