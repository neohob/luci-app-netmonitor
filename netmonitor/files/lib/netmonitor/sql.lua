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

function M.upsert_target(key, kind, display, ip, unresolved, source, resolved_at)
	local q = db.quote
	source = source or ((tonumber(unresolved) == 0) and 'dns' or 'ip')
	local ra = resolved_at and q(resolved_at) or 'NULL'
	return string.format(
		'INSERT INTO targets(key, kind, display, ip, unresolved, source, resolved_at) '
		.. 'VALUES (%s, %s, %s, %s, %s, %s, %s) '
		.. 'ON CONFLICT(key) DO UPDATE SET ip = COALESCE(excluded.ip, targets.ip), '
		.. 'display = CASE WHEN excluded.unresolved = 0 THEN excluded.display ELSE targets.display END, '
		.. 'kind = CASE WHEN excluded.unresolved = 0 THEN excluded.kind ELSE targets.kind END, '
		.. 'unresolved = MIN(targets.unresolved, excluded.unresolved), '
		.. 'source = CASE WHEN excluded.unresolved = 0 THEN excluded.source ELSE targets.source END, '
		.. 'resolved_at = CASE WHEN excluded.unresolved = 0 THEN excluded.resolved_at ELSE targets.resolved_at END;',
		q(key), q(kind), q(display), q(ip), q(unresolved), q(source), ra)
end

function M.upsert_ip_name(ip, name, source, updated_at)
	local q = db.quote
	-- Priority: dns > sni/http_host > service > asn > other. Never demote.
	return string.format(
		'INSERT INTO ip_names(ip, name, source, updated_at) VALUES (%s, %s, %s, %s) '
		.. 'ON CONFLICT(ip) DO UPDATE SET '
		.. 'name = CASE '
		.. 'WHEN excluded.source = %s THEN excluded.name '
		.. 'WHEN excluded.source IN (%s,%s) AND ip_names.source != %s THEN excluded.name '
		.. 'WHEN excluded.source = %s AND ip_names.source NOT IN (%s,%s,%s) THEN excluded.name '
		.. 'WHEN excluded.source = %s AND ip_names.source NOT IN (%s,%s,%s,%s) THEN excluded.name '
		.. 'WHEN ip_names.source = excluded.source THEN excluded.name '
		.. 'ELSE ip_names.name END, '
		.. 'source = CASE '
		.. 'WHEN excluded.source = %s THEN excluded.source '
		.. 'WHEN excluded.source IN (%s,%s) AND ip_names.source != %s THEN excluded.source '
		.. 'WHEN excluded.source = %s AND ip_names.source NOT IN (%s,%s,%s) THEN excluded.source '
		.. 'WHEN excluded.source = %s AND ip_names.source NOT IN (%s,%s,%s,%s) THEN excluded.source '
		.. 'WHEN ip_names.source = excluded.source THEN excluded.source '
		.. 'ELSE ip_names.source END, '
		.. 'updated_at = excluded.updated_at;',
		q(ip), q(name), q(source), q(updated_at),
		q('dns'),
		q('sni'), q('http_host'), q('dns'),
		q('service'), q('dns'), q('sni'), q('http_host'),
		q('asn'), q('dns'), q('sni'), q('http_host'), q('service'),
		q('dns'),
		q('sni'), q('http_host'), q('dns'),
		q('service'), q('dns'), q('sni'), q('http_host'),
		q('asn'), q('dns'), q('sni'), q('http_host'), q('service'))
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
