-- TLS SNI / HTTP Host parsers + DNS-over-SNI priority.
local H = require 'helper'
local sni = require 'netmonitor.sni'
local dns = require 'netmonitor.dns'

local function build_client_hello(hostname)
	local name = hostname
	local sni_list = string.char(0) .. string.char(0, #name) .. name
	local sni_ext = string.char(0, 0) .. string.char(0, #sni_list + 2)
		.. string.char(0, #sni_list) .. sni_list
	local body = string.char(0x03, 0x03) .. string.rep('\0', 32) .. string.char(0)
		.. string.char(0, 2) .. string.char(0x00, 0x2f)
		.. string.char(1) .. string.char(0)
		.. string.char(0, #sni_ext) .. sni_ext
	local hs = string.char(0x01) .. string.char(0, 0, #body) .. body
	return string.char(0x16, 0x03, 0x01) .. string.char(math.floor(#hs / 256), #hs % 256) .. hs
end

H.case('S1', 'parse_tls_sni extracts hostname', function()
	H.eq(sni.parse_tls_sni(build_client_hello('api.example.com')), 'api.example.com')
	H.eq(sni.parse_tls_sni(build_client_hello('Yeelink-Cloud.cn')), 'yeelink-cloud.cn')
	H.eq(sni.parse_tls_sni(''), nil)
end)

H.case('S2', 'parse_http_host extracts Host', function()
	H.eq(sni.parse_http_host('GET / HTTP/1.1\r\nHost: iot.mi.com\r\n\r\n'), 'iot.mi.com')
	H.eq(sni.parse_http_host('not http'), nil)
end)

H.case('S3', 'DNS wins over SNI; SNI fills unresolved', function()
	local st = dns.new()
	dns.feed(st, 'query[A] foo.bar from 192.168.1.2\ndnsmasq: reply foo.bar is 1.2.3.4\n', 100)
	local t = dns.target_for(st, '192.168.1.2', '1.2.3.4', 100, { name = 'sni.example', source = 'sni' })
	H.eq(t.source, 'dns')
	H.eq(t.display, 'foo.bar')
	local t2 = dns.target_for(st, '192.168.1.2', '9.9.9.9', 100, { name = 'sni.only', source = 'sni' })
	H.eq(t2.source, 'sni')
	H.eq(t2.unresolved, 0)
end)
