-- W18: package tree, LuCI package name and menu entry.
local H = require 'helper'
local json = require 'netmonitor.json'

local function exists(p)
	local f = io.open(p, 'r')
	if f then f:close() return true end
	return false
end

H.case('W18', 'luci-app-netmonitor package name + menu entry present', function()
	local mk = H.read('./luci-app-netmonitor/Makefile')
	H.ok(mk:find('PKG_NAME:=luci%-app%-netmonitor'), 'PKG_NAME')
	H.ok(mk:find('LUCI_DEPENDS:=[^\n]*%+netmonitor'), 'depends on netmonitor')
	H.ok(mk:find('luci%.mk'), 'uses luci.mk')
	local nm = H.read('./netmonitor/Makefile')
	H.ok(nm:find('PKG_NAME:=netmonitor'), 'collector package')
	H.ok(nm:find('BuildPackage,netmonitor'), 'BuildPackage')

	local menu = assert(json.decode(H.read('./luci-app-netmonitor/root/usr/share/luci/menu.d/luci-app-netmonitor.json')))
	local root = menu['admin/control/netmonitor']
	H.ok(root and root.title == '流量监控', 'menu root')
	H.eq(root.depends.acl[1], 'luci-app-netmonitor', 'menu gated by ACL')
	for _, v in ipairs({ 'overview', 'settings', 'device' }) do
		local e = menu['admin/control/netmonitor/' .. v]
		H.ok(e and e.action.path == 'netmonitor/' .. v, 'menu ' .. v)
		H.ok(exists('./luci-app-netmonitor/htdocs/luci-static/resources/view/netmonitor/' .. v .. '.js'), 'view ' .. v)
	end
	H.ok(exists('./luci-app-netmonitor/htdocs/luci-static/resources/netmonitor/topo.js'), 'topo helper')
	H.ok(exists('./netmonitor/files/lib/netmonitor/sql.lua'), 'sql helpers')
	H.ok(exists('./netmonitor/files/lib/netmonitor/schema.lua'), 'schema migrate')

	for _, f in ipairs({ 'netmonitor.config', 'netmonitor.init', 'netmonitor.uci-defaults',
		'netmonitor-collector', 'rpcd-netmonitor' }) do
		H.ok(exists('./netmonitor/files/' .. f), f)
	end
	local acl = H.read('./luci-app-netmonitor/root/usr/share/rpcd/acl.d/luci-app-netmonitor.json')
	H.ok(acl:find('prepare_path'), 'prepare_path on write ACL')
	H.ok(acl:find('update_asn'), 'update_asn on write ACL')
	H.ok(acl:find('check_path'), 'check_path listed')
	local cfg = H.read('./netmonitor/files/netmonitor.config')
	H.ok(cfg:find("option db_path ''"), 'db_path empty by default (wizard)')
	H.ok(cfg:find("option interval '5'"), 'interval 5s')
	H.ok(cfg:find("option idle_gap '60'"), 'idle gap 60s')
	H.ok(cfg:find("option reserve_min_mb '100'") and cfg:find("option reserve_pct '5'"), 'reserve policy')
end)
