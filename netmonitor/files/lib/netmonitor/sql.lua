-- Shared SQL fragment builders (F13: one dialect for collector + tests).
local db = require 'netmonitor.db'

local M = {}

function M.upsert_device(mac, ip, hostname, first_seen, last_seen)
	local q = db.quote
	return string.format(
		'INSERT INTO devices(mac, ip, hostname, first_seen, last_seen) VALUES (%s, %s, %s, %s, %s) '
		.. 'ON CONFLICT(mac) DO UPDATE SET ip = excluded.ip, '
		.. 'hostname = COALESCE(excluded.hostname, devices.hostname), last_seen = excluded.last_seen;',
		q(mac), q(ip), q(hostname), q(first_seen), q(last_seen))
end

function M.upsert_target(key, kind, display, ip, unresolved)
	local q = db.quote
	return string.format(
		'INSERT INTO targets(key, kind, display, ip, unresolved) VALUES (%s, %s, %s, %s, %s) '
		.. 'ON CONFLICT(key) DO UPDATE SET ip = excluded.ip;',
		q(key), q(kind), q(display), q(ip), q(unresolved))
end

function M.insert_sample(device, target, ts, up, down)
	local q = db.quote
	return string.format(
		'INSERT INTO traffic_samples(device, target, ts, bytes_up, bytes_down) VALUES (%s, %s, %s, %s, %s);',
		q(device), q(target), q(ts), q(up), q(down))
end

function M.upsert_session(s)
	local q = db.quote
	return string.format(
		'INSERT INTO sessions(device, target, started_at, last_seen_at, bytes_up, bytes_down, closed) '
		.. 'VALUES (%s, %s, %s, %s, %s, %s, %s) ON CONFLICT(device, target, started_at) DO UPDATE SET '
		.. 'last_seen_at = excluded.last_seen_at, bytes_up = excluded.bytes_up, '
		.. 'bytes_down = excluded.bytes_down, closed = excluded.closed;',
		q(s.device), q(s.target), q(s.started_at), q(s.last_seen_at),
		q(s.bytes_up), q(s.bytes_down), q(s.closed))
end

return M
