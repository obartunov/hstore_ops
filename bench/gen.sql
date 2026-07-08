-- bench/gen.sql : reproducible flat-metadata generator (hstore + identical jsonb)
--
-- psql vars:  :nrows  (row count)
-- Deterministic: setseed() fixes the PRNG so a clean checkout reproduces data.
--
-- Structure (so selectivities are known and stable):
--   env  IN {prod,staging,dev}          -- medium-selective pairs
--   tier IN {gold,silver,bronze}        -- medium-selective pairs
--   region IN {r0..r19}                 -- lower-selective
--   plus 3..9 random filler pairs  k0..k49 => v0..v199
--   rare pair 'shard=>S777' injected into ~0.001 of rows (selective @>)
--
-- Negative-lookup by construction: value 'gold' only ever appears under key
-- 'tier', never under 'env'; so `@> 'env=>gold'` returns 0 rows although both
-- the key 'env' and the value 'gold' are extremely common tokens.

\set ON_ERROR_STOP on
SET client_min_messages = warning;
SET maintenance_work_mem = '512MB';

DROP TABLE IF EXISTS bench;

-- Deterministic pseudo-random derived from gid via hashint4 (reproducible on a
-- clean checkout, and varies per row -- the subquery references gid, so it is
-- re-evaluated per outer row instead of being folded to a constant InitPlan).
CREATE TABLE bench AS
SELECT gid AS id,
       (
         SELECT hstore(array_agg(k ORDER BY k, v), array_agg(v ORDER BY k, v))
         FROM (
           SELECT DISTINCT ON (k) k, v FROM (
             -- structured pairs
             SELECT 'env'  AS k,
                    (ARRAY['prod','staging','dev'])
                      [1 + (hashint4(gid*7+1) & 2147483647) % 3] AS v
             UNION ALL
             SELECT 'tier',
                    (ARRAY['gold','silver','bronze'])
                      [1 + (hashint4(gid*7+2) & 2147483647) % 3]
             UNION ALL
             SELECT 'region',
                    'r' || ((hashint4(gid*7+3) & 2147483647) % 20)
             UNION ALL
             -- 3..9 filler pairs
             SELECT 'k' || ((hashint4(gid*100+s) & 2147483647) % 50),
                    'v' || ((hashint4(gid*100+s+777) & 2147483647) % 200)
             FROM generate_series(1, 3 + (hashint4(gid) & 2147483647) % 7) s
           ) raw
           ORDER BY k, v
         ) d
       ) AS h
FROM generate_series(1, :nrows) gid;

-- selective rare pair: ~ nrows/1000 rows get shard=>S777
UPDATE bench SET h = h || 'shard=>S777'
WHERE id % 1000 = 0;

-- identical jsonb projection of the same logical data
ALTER TABLE bench ADD COLUMN j jsonb;
UPDATE bench SET j = hstore_to_jsonb(h);

VACUUM (ANALYZE) bench;

\echo '--- row count / sample ---'
SELECT count(*) AS rows FROM bench;
SELECT id, h FROM bench ORDER BY id LIMIT 3;
SELECT pg_size_pretty(pg_relation_size('bench')) AS heap_size;
