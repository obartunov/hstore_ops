\set ON_ERROR_STOP on
SET client_min_messages = warning;

DROP TABLE IF EXISTS ct;
CREATE TABLE ct (id serial primary key, h hstore);

-- ---- edge-case rows -------------------------------------------------------
INSERT INTO ct (h) VALUES
  (''),                                   -- empty hstore
  ('a=>1'),                               -- simple
  ('a=>1, b=>2'),                         -- multi-key
  ('a=>1, b=>2, c=>3'),
  ('k=>NULL'),                            -- SQL NULL value
  ('k=>""'),                              -- empty-string value
  ('k=>"NULL"'),                          -- literal string "NULL"
  ('a=>2, a=>1'),                         -- duplicate input keys -> a=>1 (last wins)
  ('dup=>x, dup=>y'),                     -- -> dup=>y
  ('ключ=>значение'),                     -- non-ASCII (Cyrillic)
  ('café=>naïve'),                        -- non-ASCII (accents)
  ('日本語=>テスト'),                      -- non-ASCII (CJK)
  (hstore('longk' || repeat('K',5000), 'longv' || repeat('V',5000))), -- long
  ('shared=>v1, other=>a'),               -- shared key, value v1
  ('shared=>v2, other=>b'),               -- shared key, value v2
  ('x=>1, y=>1, z=>1'),                   -- popular value 1 under many keys
  ('hot=>1'),('hot=>2'),('hot=>3'),('hot=>4'), -- hot key many values
  ('emptyval=>""'),
  ('n1=>NULL, n2=>NULL');
-- duplicate a large block to make the index non-trivial and exercise recheck
INSERT INTO ct (h)
  SELECT hstore('key'||(g%50), 'val'||(g%50)) FROM generate_series(1,5000) g;

ANALYZE ct;

-- ---- build hash-opclass index --------------------------------------------
CREATE INDEX ct_hash ON ct USING gin (h gin_hstore_hash_ops);

-- ==========================================================================
-- Oracle equivalence: for each probe, the set of ids returned via the index
-- (seqscan disabled) must EXACTLY equal the set returned via seqscan
-- (index disabled).  Any mismatch (false positive OR false negative) prints
-- a FAIL row.  A correct run prints only PASS rows.
-- ==========================================================================

CREATE OR REPLACE FUNCTION chk_contains(q hstore) RETURNS text LANGUAGE plpgsql AS $$
DECLARE idx int[]; seq int[];
BEGIN
  SET LOCAL enable_seqscan = off; SET LOCAL enable_bitmapscan = on; SET LOCAL enable_indexscan = on;
  EXECUTE 'SELECT array_agg(id ORDER BY id) FROM ct WHERE h @> $1' INTO idx USING q;
  SET LOCAL enable_seqscan = on; SET LOCAL enable_bitmapscan = off; SET LOCAL enable_indexscan = off;
  EXECUTE 'SELECT array_agg(id ORDER BY id) FROM ct WHERE h @> $1' INTO seq USING q;
  IF idx IS NOT DISTINCT FROM seq THEN RETURN 'PASS @> '||q::text;
  ELSE RETURN 'FAIL @> '||q::text||'  idx='||coalesce(idx::text,'{}')||' seq='||coalesce(seq::text,'{}'); END IF;
END $$;

CREATE OR REPLACE FUNCTION chk_exists(k text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE idx int[]; seq int[];
BEGIN
  SET LOCAL enable_seqscan = off; SET LOCAL enable_bitmapscan = on; SET LOCAL enable_indexscan = on;
  EXECUTE 'SELECT array_agg(id ORDER BY id) FROM ct WHERE h ? $1' INTO idx USING k;
  SET LOCAL enable_seqscan = on; SET LOCAL enable_bitmapscan = off; SET LOCAL enable_indexscan = off;
  EXECUTE 'SELECT array_agg(id ORDER BY id) FROM ct WHERE h ? $1' INTO seq USING k;
  IF idx IS NOT DISTINCT FROM seq THEN RETURN 'PASS ? '||k;
  ELSE RETURN 'FAIL ? '||k||'  idx='||coalesce(idx::text,'{}')||' seq='||coalesce(seq::text,'{}'); END IF;
END $$;

CREATE OR REPLACE FUNCTION chk_any(k text[]) RETURNS text LANGUAGE plpgsql AS $$
DECLARE idx int[]; seq int[];
BEGIN
  SET LOCAL enable_seqscan = off; SET LOCAL enable_bitmapscan = on; SET LOCAL enable_indexscan = on;
  EXECUTE 'SELECT array_agg(id ORDER BY id) FROM ct WHERE h ?| $1' INTO idx USING k;
  SET LOCAL enable_seqscan = on; SET LOCAL enable_bitmapscan = off; SET LOCAL enable_indexscan = off;
  EXECUTE 'SELECT array_agg(id ORDER BY id) FROM ct WHERE h ?| $1' INTO seq USING k;
  IF idx IS NOT DISTINCT FROM seq THEN RETURN 'PASS ?| '||k::text;
  ELSE RETURN 'FAIL ?| '||k::text||'  idx='||coalesce(idx::text,'{}')||' seq='||coalesce(seq::text,'{}'); END IF;
END $$;

CREATE OR REPLACE FUNCTION chk_all(k text[]) RETURNS text LANGUAGE plpgsql AS $$
DECLARE idx int[]; seq int[];
BEGIN
  SET LOCAL enable_seqscan = off; SET LOCAL enable_bitmapscan = on; SET LOCAL enable_indexscan = on;
  EXECUTE 'SELECT array_agg(id ORDER BY id) FROM ct WHERE h ?& $1' INTO idx USING k;
  SET LOCAL enable_seqscan = on; SET LOCAL enable_bitmapscan = off; SET LOCAL enable_indexscan = off;
  EXECUTE 'SELECT array_agg(id ORDER BY id) FROM ct WHERE h ?& $1' INTO seq USING k;
  IF idx IS NOT DISTINCT FROM seq THEN RETURN 'PASS ?& '||k::text;
  ELSE RETURN 'FAIL ?& '||k::text||'  idx='||coalesce(idx::text,'{}')||' seq='||coalesce(seq::text,'{}'); END IF;
END $$;

-- ---- @> probes (incl. the classic "existing key + existing value but not as a pair") ----
SELECT chk_contains(''::hstore);
SELECT chk_contains('a=>1');
SELECT chk_contains('a=>1, b=>2');
SELECT chk_contains('a=>9');                 -- absent value for present key
SELECT chk_contains('k=>NULL');
SELECT chk_contains('k=>""');
SELECT chk_contains('k=>"NULL"');
SELECT chk_contains('a=>2');                 -- dup-key row normalized to a=>1, so absent
SELECT chk_contains('dup=>y');
SELECT chk_contains('ключ=>значение');
SELECT chk_contains('café=>naïve');
SELECT chk_contains('日本語=>テスト');
SELECT chk_contains('shared=>v1');
SELECT chk_contains('shared=>v1, other=>b');  -- key+value exist but NOT as this pair-set -> empty
SELECT chk_contains('other=>a, shared=>v2');  -- cross pair, must be empty
SELECT chk_contains('key3=>val3');
SELECT chk_contains('key3=>val7');            -- existing key + existing value, wrong pair

-- ---- ? probes ----
SELECT chk_exists('a');
SELECT chk_exists('k');
SELECT chk_exists('hot');
SELECT chk_exists('ключ');
SELECT chk_exists('nope');
SELECT chk_exists('shared');

-- ---- ?| probes ----
SELECT chk_any(ARRAY['a','nope']);
SELECT chk_any(ARRAY['nope','missing']);
SELECT chk_any(ARRAY['hot','shared']);

-- ---- ?& probes ----
SELECT chk_all(ARRAY['a','b']);
SELECT chk_all(ARRAY['shared','other']);
SELECT chk_all(ARRAY['a','nope']);
SELECT chk_all(ARRAY[]::text[]);

-- (recheck demonstration is done separately via EXPLAIN ANALYZE)
