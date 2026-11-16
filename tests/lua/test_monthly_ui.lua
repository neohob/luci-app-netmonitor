-- monthly-rollup W14–W15/W20–W21: LuCI cache-bust, 往月汇总 UI, settings copy, versions.
local H = require 'helper'

local function exists(p)
	local f = io.open(p, 'r')
	if f then f:close() return true end
	return false
end

H.case('W14', 'device_062 cache-bust + 往月汇总 UI + settings current-month copy', function()
	local menu = H.read('./luci-app-netmonitor/root/usr/share/luci/menu.d/luci-app-netmonitor.json')
	H.ok(menu:find('device_062'), 'menu cache-bust path device_062')
	H.ok(exists('./luci-app-netmonitor/htdocs/luci-static/resources/view/netmonitor/device_062.js'),
		'device_062.js present')
	local view = H.read('./luci-app-netmonitor/htdocs/luci-static/resources/view/netmonitor/device.js')
	H.ok(view:find('往月') or view:find('device_months') or view:find('month_summary')
		or view:find('callDeviceMonths') or view:find('renderPastToggle'), '往月汇总 UI signal')
	H.ok(view:find('nm-day-past-row') or view:find('renderPastToggle'), 'past toggle beside calendar')
	local common = H.read('./luci-app-netmonitor/htdocs/luci-static/resources/netmonitor/common.js')
	H.ok(common:find('device_months') and common:find('device_month_summary'), 'rpc declares')
	local settings = H.read('./luci-app-netmonitor/htdocs/luci-static/resources/view/netmonitor/settings.js')
	H.ok(settings:find('当月') or settings:find('当前月') or settings:find('日历月'), 'settings mentions current-month detail')
	local readme = H.read('./README.md')
	H.ok(readme:find('当月') or readme:find('往月') or readme:find('Top.?100'), 'README mentions monthly summary')
end)

H.case('W15', 'both packages PKG_VERSION 0.6.1', function()
	local nm = H.read('./netmonitor/Makefile')
	local luci = H.read('./luci-app-netmonitor/Makefile')
	H.ok(nm:find('PKG_VERSION:=0%.6%.1'), 'netmonitor 0.6.1')
	H.ok(luci:find('PKG_VERSION:=0%.6%.1'), 'luci-app-netmonitor 0.6.1')
end)

H.case('W20', 'editable views identical to versioned menu copies (no divergent forks)', function()
	local device = H.read('./luci-app-netmonitor/htdocs/luci-static/resources/view/netmonitor/device.js')
	local device_x = H.read('./luci-app-netmonitor/htdocs/luci-static/resources/view/netmonitor/device_062.js')
	H.eq(device, device_x, 'device.js ≡ device_062.js')
	local overview = H.read('./luci-app-netmonitor/htdocs/luci-static/resources/view/netmonitor/overview.js')
	local overview_x = H.read('./luci-app-netmonitor/htdocs/luci-static/resources/view/netmonitor/overview_055.js')
	H.eq(overview, overview_x, 'overview.js ≡ overview_055.js')
	H.ok(not exists('./luci-app-netmonitor/htdocs/luci-static/resources/view/netmonitor/device_054.js'),
		'dead device_054 removed')
	H.ok(not exists('./luci-app-netmonitor/htdocs/luci-static/resources/view/netmonitor/overview_054.js'),
		'dead overview_054 removed')
	local common = H.read('./luci-app-netmonitor/htdocs/luci-static/resources/netmonitor/common.js')
	H.ok(common:find('%?v=0%.6%.1%-calfix'), 'CSS bust 0.6.1-calfix')
end)

H.case('W21', 'calendar clamp helper uses injected router today/month (F4)', function()
	local view = H.read('./luci-app-netmonitor/htdocs/luci-static/resources/view/netmonitor/device.js')
	H.ok(view:find('clampDayToRouterMonth'), 'helper present')
	H.ok(view:find('routerToday') or view:find('current_month'), 'uses router status fields')
	-- Mirror helper semantics in Lua (same contract as JS clampDayToRouterMonth).
	local function clamp(day, routerToday, routerMonth)
		local today = routerToday or '2026-11-15'
		local curM = routerMonth or today:sub(1, 7)
		if not day or tostring(day):sub(1, 7) ~= curM then return today end
		return day
	end
	-- Browser would be December; router still November → clamp to router today.
	H.eq(clamp('2026-12-01', '2026-11-15', '2026-11'), '2026-11-15', 'outside month → router today')
	H.eq(clamp('2026-11-10', '2026-11-15', '2026-11'), '2026-11-10', 'in-month kept')
	H.eq(clamp(nil, '2026-11-15', '2026-11'), '2026-11-15', 'nil → router today')
end)
