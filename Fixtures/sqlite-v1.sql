CREATE TABLE settings (
  key TEXT PRIMARY KEY NOT NULL,
  value TEXT NOT NULL
);
CREATE TABLE known_devices (
  id TEXT PRIMARY KEY NOT NULL,
  name TEXT NOT NULL,
  supports_atvv INTEGER NOT NULL,
  last_seen_at TEXT NOT NULL
);
INSERT INTO known_devices VALUES (
  'legacy', 'Unknown ATVV', 1, '2026-08-13T00:00:00Z'
);
INSERT INTO settings VALUES ('last_connected_device_id', 'legacy');
