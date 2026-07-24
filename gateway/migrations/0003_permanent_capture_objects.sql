-- Capture objects are immutable originals. D1 keeps the safe metadata needed
-- to authorize and stream an object without ever revealing its R2 key.

ALTER TABLE captures ADD COLUMN object_content_type TEXT;
ALTER TABLE captures ADD COLUMN object_byte_length INTEGER
  CHECK (object_byte_length IS NULL OR object_byte_length >= 0);
ALTER TABLE captures ADD COLUMN object_filename TEXT;
ALTER TABLE captures ADD COLUMN object_retention_state TEXT NOT NULL DEFAULT 'none'
  CHECK (object_retention_state IN ('none', 'permanent'));

UPDATE captures
   SET object_retention_state = 'permanent'
 WHERE object_key IS NOT NULL;
