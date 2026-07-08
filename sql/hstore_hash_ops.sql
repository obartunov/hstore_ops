CREATE EXTENSION IF NOT EXISTS hstore;
CREATE EXTENSION hstore_hash_ops;

CREATE TABLE hht (id int, h hstore);
INSERT INTO hht VALUES
  (1,  ''),
  (2,  'a=>1'),
  (3,  'a=>1, b=>2'),
  (4,  'a=>1, b=>2, c=>3'),
  (5,  'k=>NULL'),
  (6,  'k=>""'),
  (7,  'k=>"NULL"'),
  (8,  'a=>2, a=>1'),
  (9,  'shared=>v1, other=>a'),
  (10, 'shared=>v2, other=>b'),
  (11, 'ключ=>значение'),
  (12, 'café=>naïve');

CREATE INDEX hht_hash ON hht USING gin (h gin_hstore_hash_ops);

SET enable_seqscan = off;

-- containment
SELECT id FROM hht WHERE h @> '' ORDER BY id;
SELECT id FROM hht WHERE h @> 'a=>1' ORDER BY id;
SELECT id FROM hht WHERE h @> 'a=>1, b=>2' ORDER BY id;
SELECT id FROM hht WHERE h @> 'a=>2' ORDER BY id;           -- row 8 normalizes to a=>2 (first dup wins)
SELECT id FROM hht WHERE h @> 'k=>NULL' ORDER BY id;
SELECT id FROM hht WHERE h @> 'k=>""' ORDER BY id;
SELECT id FROM hht WHERE h @> 'k=>"NULL"' ORDER BY id;
SELECT id FROM hht WHERE h @> 'shared=>v1, other=>b' ORDER BY id;  -- key+val exist, not this pair-set
SELECT id FROM hht WHERE h @> 'ключ=>значение' ORDER BY id;
SELECT id FROM hht WHERE h @> 'café=>naïve' ORDER BY id;

-- key existence
SELECT id FROM hht WHERE h ? 'a' ORDER BY id;
SELECT id FROM hht WHERE h ? 'k' ORDER BY id;
SELECT id FROM hht WHERE h ? 'shared' ORDER BY id;
SELECT id FROM hht WHERE h ? 'nope' ORDER BY id;

-- any / all
SELECT id FROM hht WHERE h ?| ARRAY['a','nope'] ORDER BY id;
SELECT id FROM hht WHERE h ?| ARRAY['nope','missing'] ORDER BY id;
SELECT id FROM hht WHERE h ?& ARRAY['a','b'] ORDER BY id;
SELECT id FROM hht WHERE h ?& ARRAY['shared','other'] ORDER BY id;
SELECT id FROM hht WHERE h ?& ARRAY['a','nope'] ORDER BY id;

-- recheck flag must be set: the bitmap heap scan carries a Recheck Cond
SELECT count(*) FROM hht WHERE h @> 'a=>1';

RESET enable_seqscan;
DROP TABLE hht;
DROP EXTENSION hstore_hash_ops;
