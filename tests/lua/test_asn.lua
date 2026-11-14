-- ASN normalize + priority vs DNS/SNI + config validation.
local H = require 'helper'
local asn = require 'netmonitor.asn'
local config = require 'netmonitor.config'
local dns = require 'netmonitor.dns'

H.case('ASN1', 'normalize_org shortens legal names', function()
	H.eq(asn.normalize_org('Google LLC', 15169), 'Google LLC')
	H.eq(asn.normalize_org('Alibaba (US) Technology Co., Ltd.', 45102), 'Alibaba (US) Technology Co.')
	H.eq(asn.normalize_org(nil, 15169), 'AS15169')
	H.eq(asn.normalize_org('', nil), nil)
end)

H.case('ASN2', 'config accepts asn options', function()
	local cur = config.normalize({})
	local cfg, err = config.validate(cur, {
		asn_enable = 1, asn_auto_update = 1, asn_week_time = '*', asn_day_time = 4,
		asn_path = '/overlay/netmonitor/GeoLite2-ASN.mmdb',
		asn_url = 'https://cdn.jsdelivr.net/npm/geolite2-asn/GeoLite2-ASN.mmdb.gz',
	})
	H.eq(err, nil)
	H.eq(cfg.asn_enable, 1)
	H.eq(cfg.asn_day_time, 4)
end)

H.case('ASN3', 'config rejects bad asn url/hour', function()
	local cur = config.normalize({})
	local _, err = config.validate(cur, { asn_url = 'ftp://x' })
	H.eq(err, 'bad_asn_url')
	_, err = config.validate(cur, { asn_day_time = 25 })
	H.eq(err, 'bad_asn_day_time')
end)

H.case('ASN4', 'dns.target_for prefers DNS then SNI then ASN', function()
	local st = dns.new()
	st.by_ip['1.1.1.1'] = { name = 'one.one.one.one', ts = 100 }
	local t = dns.target_for(st, '10.0.0.2', '1.1.1.1', 100, nil, 'CLOUDFLARE')
	H.eq(t.source, 'dns')
	H.eq(t.display, 'one.one.one.one')
	t = dns.target_for(dns.new(), '10.0.0.2', '8.8.8.8', 100, { name = 'dns.google', source = 'sni' }, 'GOOGLE')
	H.eq(t.source, 'sni')
	t = dns.target_for(dns.new(), '10.0.0.2', '8.8.8.8', 100, nil, 'GOOGLE')
	H.eq(t.source, 'asn')
	H.eq(t.key, '8.8.8.8')
	H.eq(t.display, 'GOOGLE')
	H.eq(t.unresolved, 0)
end)
