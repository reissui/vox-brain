ALTER TABLE captures ADD COLUMN delivered_at TEXT
  CHECK (delivered_at IS NULL OR (
    delivered_at GLOB '????-??-??T??:??:??.???Z'
    AND julianday(delivered_at) IS NOT NULL
  ));
