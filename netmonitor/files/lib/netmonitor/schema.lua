local M = {}

M.VERSION = 3

-- Base schema (idempotent). Future ALTER steps go in M.MIGRATIONS[version].
M.SQL = [[
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
CREATE TABLE IF NOT EXISTS meta (
	key TEXT PRIMARY KEY,
	value TEXT
);
CREATE TABLE IF NOT EXISTS devices (
	mac TEXT PRIMARY KEY,
	ip TEXT,
	hostname TEXT,
	first_seen INTEGER NOT NULL,
	last_seen INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS targets (
	key TEXT PRIMARY KEY,
	kind TEXT NOT NULL,
	display TEXT NOT NULL,
	ip TEXT,
	unresolved INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS traffic_samples (
	id INTEGER PRIMARY KEY,
	device TEXT NOT NULL,
	target TEXT NOT NULL,
	ts INTEGER NOT NULL,
	bytes_up INTEGER NOT NULL,
	bytes_down INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_samples_ts ON traffic_samples(ts);
CREATE INDEX IF NOT EXISTS idx_samples_device_ts ON traffic_samples(device, ts);
CREATE TABLE IF NOT EXISTS sessions (
	device TEXT NOT NULL,
	target TEXT NOT NULL,
	started_at INTEGER NOT NULL,
	last_seen_at INTEGER NOT NULL,
	bytes_up INTEGER NOT NULL DEFAULT 0,
	bytes_down INTEGER NOT NULL DEFAULT 0,
	closed INTEGER NOT NULL DEFAULT 0,
	PRIMARY KEY (device, target, started_at)
);
CREATE INDEX IF NOT EXISTS idx_sessions_device_start ON sessions(device, started_at);
CREATE INDEX IF NOT EXISTS idx_sessions_last ON sessions(last_seen_at);
]]

-- Per-version upgrade scripts (applied after base CREATE IF NOT EXISTS).
-- [1] = empty: version stamp only after base schema.
-- [2] = destination source + persistent IP→name map (v0.2 resolve).
-- [3] = ASN display demoted to IP (org stays in ip_names); service CIDR labels.
M.MIGRATIONS = {
	[1] = '',
	[2] = [[
ALTER TABLE targets ADD COLUMN source TEXT NOT NULL DEFAULT 'ip';
ALTER TABLE targets ADD COLUMN resolved_at INTEGER;
CREATE TABLE IF NOT EXISTS ip_names (
	ip TEXT PRIMARY KEY,
	name TEXT NOT NULL,
	source TEXT NOT NULL,
	updated_at INTEGER NOT NULL
);
]],
	[3] = [[
UPDATE targets SET display = key
 WHERE source = 'asn' AND kind = 'ip'
   AND display IS NOT NULL AND display != key;
]],
}

-- Apply base schema + any pending migrations (F15).
function M.apply(db_file, db_mod)
	local ok, err = db_mod.exec(db_file, M.SQL)
	if not ok then return nil, err end
	local rows = db_mod.query(db_file, "SELECT value FROM meta WHERE key = 'schema_version';")
	local ver = 0
	if rows and rows[1] and rows[1].value then ver = tonumber(rows[1].value) or 0 end
	for v = ver + 1, M.VERSION do
		local mig = M.MIGRATIONS[v]
		if mig and mig ~= '' then
			ok, err = db_mod.exec(db_file, mig)
			if not ok then return nil, err end
		end
		ok, err = db_mod.exec(db_file, string.format(
			"INSERT OR REPLACE INTO meta(key, value) VALUES ('schema_version', %s);",
			db_mod.quote(tostring(v))))
		if not ok then return nil, err end
	end
	return true
end

return M
