DROP TABLE IF EXISTS cm;
CREATE TABLE cm (id int, h hstore);
INSERT INTO cm VALUES (1, '');
INSERT INTO cm VALUES (2, 'a=>1');
INSERT INTO cm VALUES (3, 'a=>1, b=>2');
INSERT INTO cm VALUES (4, 'a=>1, b=>2, c=>3');
INSERT INTO cm VALUES (5, 'k=>NULL');
INSERT INTO cm VALUES (6, 'k=>""');
INSERT INTO cm VALUES (7, 'k=>"NULL"');
INSERT INTO cm VALUES (8, 'a=>2, a=>1');
INSERT INTO cm VALUES (9, 'shared=>v1, other=>a');
INSERT INTO cm VALUES (10, 'shared=>v2, other=>b');
INSERT INTO cm VALUES (11, 'ключ=>значение');
INSERT INTO cm VALUES (12, 'café=>naïve');
INSERT INTO cm VALUES (13, 'ab=>c');
INSERT INTO cm VALUES (14, 'a=>bc');
INSERT INTO cm VALUES (15, 'x=>""');
INSERT INTO cm VALUES (100, NULL);
INSERT INTO cm VALUES (101, '');
INSERT INTO cm SELECT 102, hstore(array_agg('kk'||g), array_agg('vv'||g)) FROM generate_series(1,400) g;
INSERT INTO cm VALUES (103, hstore('big', repeat('v',2500)));
CREATE INDEX cmi ON cm USING gin (h gin_hstore_pair_ops);
ANALYZE cm;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM cm WHERE h @> '' \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM cm WHERE h @> '' \gset gs_
SELECT CASE WHEN :'gi_v'=:'gs_v' THEN 'PASS' ELSE 'FAIL' END AS r, 'empty_rhs' AS probe, :'gi_v' AS idx, :'gs_v' AS seq;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM cm WHERE h @> 'a=>1' \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM cm WHERE h @> 'a=>1' \gset gs_
SELECT CASE WHEN :'gi_v'=:'gs_v' THEN 'PASS' ELSE 'FAIL' END AS r, 'at_a1' AS probe, :'gi_v' AS idx, :'gs_v' AS seq;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM cm WHERE h @> hstore('kk50','vv50') \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM cm WHERE h @> hstore('kk50','vv50') \gset gs_
SELECT CASE WHEN :'gi_v'=:'gs_v' THEN 'PASS' ELSE 'FAIL' END AS r, 'toast_pair' AS probe, :'gi_v' AS idx, :'gs_v' AS seq;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM cm WHERE h @> hstore('big', repeat('v',2500)) \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM cm WHERE h @> hstore('big', repeat('v',2500)) \gset gs_
SELECT CASE WHEN :'gi_v'=:'gs_v' THEN 'PASS' ELSE 'FAIL' END AS r, 'long_val' AS probe, :'gi_v' AS idx, :'gs_v' AS seq;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM cm WHERE h ? 'kk399' \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM cm WHERE h ? 'kk399' \gset gs_
SELECT CASE WHEN :'gi_v'=:'gs_v' THEN 'PASS' ELSE 'FAIL' END AS r, 'toast_key' AS probe, :'gi_v' AS idx, :'gs_v' AS seq;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM cm WHERE h @> 'shared=>v1, other=>b' \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM cm WHERE h @> 'shared=>v1, other=>b' \gset gs_
SELECT CASE WHEN :'gi_v'=:'gs_v' THEN 'PASS' ELSE 'FAIL' END AS r, 'neg_pair' AS probe, :'gi_v' AS idx, :'gs_v' AS seq;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM cm WHERE h ? 'nope' \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM cm WHERE h ? 'nope' \gset gs_
SELECT CASE WHEN :'gi_v'=:'gs_v' THEN 'PASS' ELSE 'FAIL' END AS r, 'key_nope' AS probe, :'gi_v' AS idx, :'gs_v' AS seq;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM cm WHERE h ?& ARRAY['a','b'] \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM cm WHERE h ?& ARRAY['a','b'] \gset gs_
SELECT CASE WHEN :'gi_v'=:'gs_v' THEN 'PASS' ELSE 'FAIL' END AS r, 'all_ab' AS probe, :'gi_v' AS idx, :'gs_v' AS seq;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM cm WHERE h ?| ARRAY[]::text[] \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM cm WHERE h ?| ARRAY[]::text[] \gset gs_
SELECT CASE WHEN :'gi_v'=:'gs_v' THEN 'PASS' ELSE 'FAIL' END AS r, 'any_empty' AS probe, :'gi_v' AS idx, :'gs_v' AS seq;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM cm WHERE h ?& ARRAY[]::text[] \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM cm WHERE h ?& ARRAY[]::text[] \gset gs_
SELECT CASE WHEN :'gi_v'=:'gs_v' THEN 'PASS' ELSE 'FAIL' END AS r, 'all_empty' AS probe, :'gi_v' AS idx, :'gs_v' AS seq;
REINDEX INDEX cmi;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM cm WHERE h @> 'a=>1' \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM cm WHERE h @> 'a=>1' \gset gs_
SELECT CASE WHEN :'gi_v'=:'gs_v' THEN 'PASS' ELSE 'FAIL' END AS r, 'postREINDEX' AS probe, :'gi_v' AS idx, :'gs_v' AS seq;
VACUUM (ANALYZE) cm;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM cm WHERE h @> hstore('kk50','vv50') \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM cm WHERE h @> hstore('kk50','vv50') \gset gs_
SELECT CASE WHEN :'gi_v'=:'gs_v' THEN 'PASS' ELSE 'FAIL' END AS r, 'postVACUUM_toast' AS probe, :'gi_v' AS idx, :'gs_v' AS seq;
SET enable_seqscan=off;SET enable_bitmapscan=on;
PREPARE q(hstore) AS SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM cm WHERE h @> $1;
EXECUTE q('a=>1') \gset pi_
SET enable_seqscan=on;SET enable_bitmapscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM cm WHERE h @> 'a=>1' \gset ps_
SELECT CASE WHEN :'pi_v'=:'ps_v' THEN 'PASS' ELSE 'FAIL' END AS r, 'prepared_param' AS probe, :'pi_v' AS idx, :'ps_v' AS seq;
