-- Remote-first operational state. Canonical Markdown and credential material
-- stay on the Brain Agent; D1 contains only delivery/control metadata.

CREATE TABLE instances (
  id TEXT PRIMARY KEY NOT NULL,
  name TEXT NOT NULL,
  agent_token_digest TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
    CHECK (created_at GLOB '????-??-??T??:??:??.???Z' AND julianday(created_at) IS NOT NULL),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
    CHECK (updated_at GLOB '????-??-??T??:??:??.???Z' AND julianday(updated_at) IS NOT NULL)
);

CREATE TABLE devices (
  id TEXT PRIMARY KEY NOT NULL,
  instance_id TEXT NOT NULL,
  name TEXT NOT NULL,
  pairing_code_digest TEXT UNIQUE,
  token_digest TEXT UNIQUE,
  scopes TEXT NOT NULL DEFAULT '[]'
    CHECK (json_valid(scopes) AND json_type(scopes) = 'array'),
  pairing_expires_at TEXT
    CHECK (pairing_expires_at IS NULL OR (
      pairing_expires_at GLOB '????-??-??T??:??:??.???Z'
      AND julianday(pairing_expires_at) IS NOT NULL
    )),
  claimed_at TEXT
    CHECK (claimed_at IS NULL OR (
      claimed_at GLOB '????-??-??T??:??:??.???Z'
      AND julianday(claimed_at) IS NOT NULL
    )),
  revoked_at TEXT
    CHECK (revoked_at IS NULL OR (
      revoked_at GLOB '????-??-??T??:??:??.???Z'
      AND julianday(revoked_at) IS NOT NULL
    )),
  last_seen_at TEXT
    CHECK (last_seen_at IS NULL OR (
      last_seen_at GLOB '????-??-??T??:??:??.???Z'
      AND julianday(last_seen_at) IS NOT NULL
    )),
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
    CHECK (created_at GLOB '????-??-??T??:??:??.???Z' AND julianday(created_at) IS NOT NULL),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
    CHECK (updated_at GLOB '????-??-??T??:??:??.???Z' AND julianday(updated_at) IS NOT NULL),
  FOREIGN KEY (instance_id) REFERENCES instances(id) ON DELETE CASCADE,
  UNIQUE (instance_id, id)
);

CREATE TABLE captures (
  id TEXT PRIMARY KEY NOT NULL,
  instance_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  payload_digest TEXT NOT NULL,
  capture_type TEXT NOT NULL,
  source TEXT NOT NULL,
  object_key TEXT,
  object_sha256 TEXT,
  state TEXT NOT NULL DEFAULT 'queued'
    CHECK (state IN (
      'queued',
      'delivering',
      'delivered',
      'processing',
      'needs_attention',
      'completed',
      'failed'
    )),
  last_error TEXT,
  captured_at TEXT NOT NULL
    CHECK (captured_at GLOB '????-??-??T??:??:??.???Z' AND julianday(captured_at) IS NOT NULL),
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
    CHECK (created_at GLOB '????-??-??T??:??:??.???Z' AND julianday(created_at) IS NOT NULL),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
    CHECK (updated_at GLOB '????-??-??T??:??:??.???Z' AND julianday(updated_at) IS NOT NULL),
  FOREIGN KEY (instance_id) REFERENCES instances(id) ON DELETE CASCADE,
  FOREIGN KEY (instance_id, device_id) REFERENCES devices(instance_id, id) ON DELETE RESTRICT,
  UNIQUE (instance_id, idempotency_key)
);

CREATE TABLE jobs (
  id TEXT PRIMARY KEY NOT NULL,
  instance_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  idempotency_key TEXT,
  request_digest TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('ask', 'process', 'digest')),
  state TEXT NOT NULL DEFAULT 'queued'
    CHECK (state IN ('queued', 'running', 'completed', 'failed', 'cancelled')),
  result_json TEXT CHECK (result_json IS NULL OR json_valid(result_json)),
  last_error TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
    CHECK (created_at GLOB '????-??-??T??:??:??.???Z' AND julianday(created_at) IS NOT NULL),
  started_at TEXT
    CHECK (started_at IS NULL OR (
      started_at GLOB '????-??-??T??:??:??.???Z'
      AND julianday(started_at) IS NOT NULL
    )),
  finished_at TEXT
    CHECK (finished_at IS NULL OR (
      finished_at GLOB '????-??-??T??:??:??.???Z'
      AND julianday(finished_at) IS NOT NULL
    )),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
    CHECK (updated_at GLOB '????-??-??T??:??:??.???Z' AND julianday(updated_at) IS NOT NULL),
  FOREIGN KEY (instance_id) REFERENCES instances(id) ON DELETE CASCADE,
  FOREIGN KEY (instance_id, device_id) REFERENCES devices(instance_id, id) ON DELETE RESTRICT,
  UNIQUE (instance_id, idempotency_key)
);

CREATE TABLE heartbeats (
  id TEXT PRIMARY KEY NOT NULL,
  instance_id TEXT NOT NULL,
  agent_version TEXT NOT NULL,
  status_json TEXT NOT NULL CHECK (json_valid(status_json)),
  observed_at TEXT NOT NULL
    CHECK (observed_at GLOB '????-??-??T??:??:??.???Z' AND julianday(observed_at) IS NOT NULL),
  received_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
    CHECK (received_at GLOB '????-??-??T??:??:??.???Z' AND julianday(received_at) IS NOT NULL),
  FOREIGN KEY (instance_id) REFERENCES instances(id) ON DELETE CASCADE
);

CREATE INDEX idx_captures_pending
  ON captures (instance_id, state, created_at)
  WHERE state IN ('queued', 'delivering', 'delivered', 'processing', 'needs_attention');

CREATE INDEX idx_jobs_pending
  ON jobs (instance_id, state, created_at)
  WHERE state IN ('queued', 'running');

CREATE INDEX idx_heartbeats_latest
  ON heartbeats (instance_id, observed_at DESC);
