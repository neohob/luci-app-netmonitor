-- W1–W3: wizard gating and free-space write pause.
local H = require 'helper'
local api = require 'netmonitor.api'
local collector = require 'netmonitor.collector'
local disk = require 'netmonitor.disk'
local db = require 'netmonitor.db'

H.case('W1', 'set_config without path, collector start refused, status need_wizard', function()
	local rundir = H.tmpdir()
	local saved, ran = nil, {}
	local env = {
		cfg = H.cfg({ db_path = '' }), now = os.time(), rundir = rundir,
		saver = function(c) saved = c end,
		runner = function(cmd) ran[#ran + 1] = cmd end,
		cron_runner = false,
		uci_get = function() return nil end,
	}
	local r = api.call('set_config', { interval = 5, idle_gap = 60 }, env)
	H.eq(r.ok, true, 'set_config ok')
	H.ok(saved and saved.db_path == '', 'saved without path')
	H.eq(#ran, 0, 'no collector restart without path')

	local c = api.call('collector', { action = 'start' }, env)
	H.eq(c.ok, false, 'start refused')
	H.eq(c.error, 'need_path', 'start error')
	H.eq(c.state, 'need_wizard', 'start state')
	H.eq(#ran, 0, 'init script not invoked')

	local pre = collector.preflight(env.cfg)
	H.eq(pre.ok, false, 'preflight')

	local s = api.call('status', {}, env)
	H.eq(s.state, 'need_wizard', 'status state')

	local bad = api.call('set_config', { db_path = '/mnt/usb' },
		{ cfg = env.cfg, now = env.now, rundir = rundir, saver = env.saver, runner = env.runner,
			cron_runner = false,
			fsops = H.fsops(10 * H.GiB, 32 * H.GiB, false) })
	H.eq(bad.ok, false, 'unwritable path rejected')
	H.eq(bad.error, 'path_not_writable', 'unwritable error')
	H.rmrf(rundir)
end)

H.case('W2', 'free=50MiB on 2GiB volume pauses writes, status disk_pause', function()
	local cfg = H.cfg({ db_path = '/mnt/usb' })
	local chk = disk.check('/mnt/usb', cfg, H.statfs(50 * H.MiB, 2 * H.GiB))
	H.eq(chk.paused, true, 'check paused')
	H.eq(chk.reserve, 2 * H.GiB * 5 / 100, 'reserve = max(100MiB, 5% of 2GiB) = 102.4MiB')
	H.eq(disk.check('/mnt/usb', cfg, H.statfs(50 * H.MiB, 1 * H.GiB)).reserve, 100 * H.MiB, '100MiB floor on 1GiB')

	local dir, file = H.new_db()
	cfg.db_path = dir
	local ctx = collector.new(cfg, {
		db_file = file, rundir = dir, prime = false,
		statfs = H.statfs(50 * H.MiB, 2 * H.GiB),
		sources = {
			conntrack = function() return H.fixture('conntrack_basic.txt') end,
			neigh = function() return H.neigh_snapshot() end,
			dns = function() return H.fixture('dnsmasq.log') end,
		},
	})
	local now = os.time()
	local res = collector.poll(ctx, now)
	H.eq(res.paused, true, 'poll paused')
	H.eq(res.samples, 0, 'no samples written')
	H.eq(#(res.changed or {}), 0, 'F4: no session stitch while paused')
	local nopen = 0
	for _ in pairs(ctx.sess.open) do nopen = nopen + 1 end
	H.eq(nopen, 0, 'F4: no open sessions while paused')
	local rows = db.query(file, 'SELECT COUNT(*) AS n FROM traffic_samples;')
	H.eq(rows[1].n, 0, 'db untouched')
	local st = collector.status_payload(ctx, res, now)
	H.eq(st.state, 'disk_pause', 'state')
	-- F3: statfs_failed is path_error, not disk_pause
	local ctx2 = collector.new(cfg, {
		db_file = file, rundir = dir, prime = false,
		statfs = function() return nil end,
		sources = ctx.sources,
	})
	local res2 = collector.poll(ctx2, now)
	H.eq(res2.unavailable, true, 'statfs unavailable')
	local st2 = collector.status_payload(ctx2, res2, now)
	H.eq(st2.state, 'path_error', 'F3: not disk_pause')
	collector.write_state(dir, st)
	local s = api.call('status', {}, { cfg = cfg, now = now, rundir = dir, db_file = file,
		uci_get = function() return nil end })
	H.eq(s.state, 'disk_pause', 'ubus status')

	local pre = collector.preflight(cfg, H.fsops(50 * H.MiB, 2 * H.GiB))
	H.eq(pre.ok, false, 'preflight blocks start on insufficient space')
	H.eq(pre.error, 'insufficient_space', 'preflight error')
	H.rmrf(dir)
end)

H.case('W3', 'free=200MiB allows sample write', function()
	local dir, file = H.new_db()
	local cfg = H.cfg({ db_path = dir })
	local chk = disk.check(dir, cfg, H.statfs(200 * H.MiB, 2 * H.GiB))
	H.eq(chk.paused, false, 'not paused')
	local ctx = collector.new(cfg, {
		db_file = file, rundir = dir, prime = false,
		statfs = H.statfs(200 * H.MiB, 2 * H.GiB),
		sources = {
			conntrack = function() return H.fixture('conntrack_basic.txt') end,
			neigh = function() return H.neigh_snapshot() end,
			dns = function() return H.fixture('dnsmasq.log') end,
		},
	})
	local res = collector.poll(ctx, os.time())
	H.eq(res.paused, false, 'poll not paused')
	H.ok(res.error == nil, 'write error: ' .. tostring(res.error))
	H.ok(res.samples > 0, 'samples written')
	local rows = db.query(file, 'SELECT COUNT(*) AS n FROM traffic_samples;')
	H.eq(rows[1].n, res.samples, 'rows in db')
	H.rmrf(dir)
end)
