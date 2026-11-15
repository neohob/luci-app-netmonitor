-- monthly-rollup W1–W2: calendar month helpers.
local H = require 'helper'
local tu = require 'netmonitor.timeutil'

H.case('W1', 'month_key / month_start / next_month_start mid-month', function()
	local now = os.time({ year = 2026, month = 11, day = 15, hour = 14, min = 30, sec = 0 })
	H.eq(tu.month_key(now), '2026-11', 'month_key')
	local start = tu.month_start(now)
	H.eq(os.date('%Y-%m-%d %H:%M:%S', start), '2026-11-01 00:00:00', 'month_start local 1st 00:00')
	local nxt = tu.next_month_start(now)
	H.eq(os.date('%Y-%m-%d %H:%M:%S', nxt), '2026-12-01 00:00:00', 'next_month_start')
	H.eq(tu.prev_month_key(now), '2026-10', 'prev_month_key')
	local ps, pe = tu.prev_month_bounds(now)
	H.eq(os.date('%Y-%m-%d', ps), '2026-10-01', 'prev start')
	H.eq(os.date('%Y-%m-%d', pe), '2026-11-01', 'prev end = cur start')
	H.eq(tu.parse_month('2026-10'), ps, 'parse_month')
end)

H.case('W2', 'month bounds on last day 23:59 still same month_key; next crosses', function()
	local now = os.time({ year = 2026, month = 11, day = 30, hour = 23, min = 59, sec = 0 })
	H.eq(tu.month_key(now), '2026-11', 'same month_key')
	H.eq(os.date('%Y-%m-%d', tu.month_start(now)), '2026-11-01', 'start still 1st')
	H.eq(os.date('%Y-%m-%d', tu.next_month_start(now)), '2026-12-01', 'next crosses')
	-- December → January year roll
	local dec = os.time({ year = 2026, month = 12, day = 31, hour = 23, min = 59, sec = 0 })
	H.eq(tu.month_key(dec), '2026-12', 'dec key')
	H.eq(os.date('%Y-%m-%d', tu.next_month_start(dec)), '2027-01-01', 'year roll')
	H.eq(tu.prev_month_key(os.time({ year = 2027, month = 1, day = 5 })), '2026-12', 'jan prev')
end)

H.case('W23', 'parse_month rejects 2026-13 / 2026-00 (no normalize)', function()
	H.eq(tu.parse_month('2026-13'), nil, 'month 13')
	H.eq(tu.parse_month('2026-00'), nil, 'month 00')
	H.eq(tu.parse_month('2026-1'), nil, 'not zero-padded')
	H.ok(tu.parse_month('2026-10') ~= nil, 'valid October')
	H.ok(tu.parse_month('2026-01') ~= nil, 'valid January')
	H.eq(tu.parse_month('bad'), nil, 'garbage')
end)
