-- Shared test helpers. Run from repo root: lua tests/lua/run_all.lua
package.path = './netmonitor/files/lib/?.lua;./tests/lua/?.lua;' .. package.path

local H = {}

H.ROOT = '.'
H.FIX = './tests/fixtures/'

function H.read(path)
	local f = assert(io.open(path, 'r'), 'missing ' .. path)
	local s = f:read('*a')
	f:close()
	return s
end

function H.fixture(name) return H.read(H.FIX .. name) end

function H.tmpdir()
	local p = io.popen('mktemp -d /tmp/nmtest.XXXXXX')
	local d = p:read('*l')
	p:close()
	return d
end

function H.rmrf(dir)
	if dir and dir:match('^/tmp/nmtest%.') then os.execute('rm -rf ' .. dir) end
end

local MiB = 1024 * 1024
H.MiB = MiB
H.GiB = 1024 * MiB

function H.statfs(free, total)
	return function() return { fs = '/dev/sda1', mount = '/mnt/usb', free = free, total = total, used = total - free } end
end

function H.fsops(free, total, writable, opts)
	opts = opts or {}
	local exists = opts.exists ~= false
	return {
		mkdir = function()
			if opts.on_mkdir then opts.on_mkdir() end
			return true
		end,
		probe_write = function()
			if opts.on_probe then opts.on_probe() end
			return writable ~= false
		end,
		statfs = H.statfs(free, total),
		realpath = function(p) return p end,
		is_dir = function() return exists end,
		is_writable = function() return writable ~= false and exists end,
	}
end

function H.neigh_snapshot()
	local neigh = require 'netmonitor.neigh'
	local by_mac, by_ip = neigh.parse_leases(H.fixture('leases.txt'))
	return {
		neigh = neigh.parse_neigh(H.fixture('neigh.txt'), 'br-lan'),
		leases = by_mac, lease_ip = by_ip,
		own = neigh.parse_addrs(H.fixture('addrs.txt')),
	}
end

function H.cfg(over)
	local config = require 'netmonitor.config'
	local c = config.normalize(over or {})
	return c
end

-- Fresh DB with schema in a temp dir; returns dir, db_file.
function H.new_db()
	local db = require 'netmonitor.db'
	local schema = require 'netmonitor.schema'
	local disk = require 'netmonitor.disk'
	local dir = H.tmpdir()
	local file = disk.db_file(dir)
	assert(schema.apply(file, db))
	return dir, file
end

-- Insert rows: samples { {device, target, ts, up, down} } plus device/target rows.
function H.seed(file, samples, devices, targets)
	local db = require 'netmonitor.db'
	local sqlb = require 'netmonitor.sql'
	local sql = { 'BEGIN;' }
	for _, d in ipairs(devices or {}) do
		sql[#sql + 1] = sqlb.upsert_device(d.mac, d.ip, d.hostname, d.first_seen or 0, d.last_seen or 0)
	end
	for _, t in ipairs(targets or {}) do
		sql[#sql + 1] = sqlb.upsert_target(t.key, t.kind or 'domain', t.display or t.key, t.ip, t.unresolved or 0)
	end
	for _, s in ipairs(samples or {}) do
		sql[#sql + 1] = sqlb.insert_sample(s[1], s[2], s[3], s[4], s[5])
	end
	sql[#sql + 1] = 'COMMIT;'
	assert(db.exec(file, table.concat(sql, '\n')))
end

-- Minimal assertion + case runner.
H.results = {}

function H.eq(a, b, msg)
	if a ~= b then
		error(string.format('%s: expected %s, got %s', msg or 'eq', tostring(b), tostring(a)), 2)
	end
end

function H.ok(v, msg)
	if not v then error(msg or 'assertion failed', 2) end
end

function H.case(id, desc, fn)
	local ok, err = pcall(fn)
	local line = string.format('%s %s — %s', id, ok and 'PASS' or 'FAIL', desc)
	if not ok then line = line .. '\n    ' .. tostring(err) end
	print(line)
	H.results[#H.results + 1] = { id = id, ok = ok }
end

function H.summary()
	local pass, fail = 0, 0
	for _, r in ipairs(H.results) do if r.ok then pass = pass + 1 else fail = fail + 1 end end
	print(string.format('lua: %d passed, %d failed', pass, fail))
	return fail == 0
end

return H
