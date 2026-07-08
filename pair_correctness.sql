\set ON_ERROR_STOP on
DROP TABLE IF EXISTS pt;
CREATE TABLE pt (id int, h hstore);
INSERT INTO pt VALUES (1, '');
INSERT INTO pt VALUES (2, 'a=>1');
INSERT INTO pt VALUES (3, 'a=>1, b=>2');
INSERT INTO pt VALUES (4, 'a=>1, b=>2, c=>3');
INSERT INTO pt VALUES (5, 'k=>NULL');
INSERT INTO pt VALUES (6, 'k=>""');
INSERT INTO pt VALUES (7, 'k=>"NULL"');
INSERT INTO pt VALUES (8, 'a=>2, a=>1');
INSERT INTO pt VALUES (9, 'shared=>v1, other=>a');
INSERT INTO pt VALUES (10, 'shared=>v2, other=>b');
INSERT INTO pt VALUES (11, 'ключ=>значение');
INSERT INTO pt VALUES (12, 'café=>naïve');
INSERT INTO pt VALUES (13, 'ab=>c');
INSERT INTO pt VALUES (14, 'a=>bc');
INSERT INTO pt VALUES (15, 'x=>""');
CREATE INDEX pti ON pt USING gin (h gin_hstore_pair_ops);
ANALYZE pt;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS idx FROM pt WHERE h @> '' \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS seq FROM pt WHERE h @> '' \gset gs_
SELECT CASE WHEN :'gi_idx'=:'gs_seq' THEN 'PASS' ELSE 'FAIL' END AS r, 'h @> ' AS probe, :'gi_idx' AS idx, :'gs_seq' AS seq;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS idx FROM pt WHERE h @> 'a=>1' \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS seq FROM pt WHERE h @> 'a=>1' \gset gs_
SELECT CASE WHEN :'gi_idx'=:'gs_seq' THEN 'PASS' ELSE 'FAIL' END AS r, 'h @> a=>1' AS probe, :'gi_idx' AS idx, :'gs_seq' AS seq;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS idx FROM pt WHERE h @> 'a=>1, b=>2' \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS seq FROM pt WHERE h @> 'a=>1, b=>2' \gset gs_
SELECT CASE WHEN :'gi_idx'=:'gs_seq' THEN 'PASS' ELSE 'FAIL' END AS r, 'h @> a=>1, b=>2' AS probe, :'gi_idx' AS idx, :'gs_seq' AS seq;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS idx FROM pt WHERE h @> 'a=>2' \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS seq FROM pt WHERE h @> 'a=>2' \gset gs_
SELECT CASE WHEN :'gi_idx'=:'gs_seq' THEN 'PASS' ELSE 'FAIL' END AS r, 'h @> a=>2' AS probe, :'gi_idx' AS idx, :'gs_seq' AS seq;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS idx FROM pt WHERE h @> 'k=>NULL' \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS seq FROM pt WHERE h @> 'k=>NULL' \gset gs_
SELECT CASE WHEN :'gi_idx'=:'gs_seq' THEN 'PASS' ELSE 'FAIL' END AS r, 'h @> k=>NULL' AS probe, :'gi_idx' AS idx, :'gs_seq' AS seq;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS idx FROM pt WHERE h @> 'k=>""' \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS seq FROM pt WHERE h @> 'k=>""' \gset gs_
SELECT CASE WHEN :'gi_idx'=:'gs_seq' THEN 'PASS' ELSE 'FAIL' END AS r, 'h @> k=>' AS probe, :'gi_idx' AS idx, :'gs_seq' AS seq;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS idx FROM pt WHERE h @> 'k=>"NULL"' \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS seq FROM pt WHERE h @> 'k=>"NULL"' \gset gs_
SELECT CASE WHEN :'gi_idx'=:'gs_seq' THEN 'PASS' ELSE 'FAIL' END AS r, 'h @> k=>NULL' AS probe, :'gi_idx' AS idx, :'gs_seq' AS seq;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS idx FROM pt WHERE h @> 'shared=>v1, other=>b' \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS seq FROM pt WHERE h @> 'shared=>v1, other=>b' \gset gs_
SELECT CASE WHEN :'gi_idx'=:'gs_seq' THEN 'PASS' ELSE 'FAIL' END AS r, 'h @> shared=>v1, other=>b' AS probe, :'gi_idx' AS idx, :'gs_seq' AS seq;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS idx FROM pt WHERE h @> 'ab=>c' \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS seq FROM pt WHERE h @> 'ab=>c' \gset gs_
SELECT CASE WHEN :'gi_idx'=:'gs_seq' THEN 'PASS' ELSE 'FAIL' END AS r, 'h @> ab=>c' AS probe, :'gi_idx' AS idx, :'gs_seq' AS seq;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS idx FROM pt WHERE h @> 'a=>bc' \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS seq FROM pt WHERE h @> 'a=>bc' \gset gs_
SELECT CASE WHEN :'gi_idx'=:'gs_seq' THEN 'PASS' ELSE 'FAIL' END AS r, 'h @> a=>bc' AS probe, :'gi_idx' AS idx, :'gs_seq' AS seq;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS idx FROM pt WHERE h @> 'x=>""' \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS seq FROM pt WHERE h @> 'x=>""' \gset gs_
SELECT CASE WHEN :'gi_idx'=:'gs_seq' THEN 'PASS' ELSE 'FAIL' END AS r, 'h @> x=>' AS probe, :'gi_idx' AS idx, :'gs_seq' AS seq;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS idx FROM pt WHERE h @> 'nope=>x' \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS seq FROM pt WHERE h @> 'nope=>x' \gset gs_
SELECT CASE WHEN :'gi_idx'=:'gs_seq' THEN 'PASS' ELSE 'FAIL' END AS r, 'h @> nope=>x' AS probe, :'gi_idx' AS idx, :'gs_seq' AS seq;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS idx FROM pt WHERE h ? 'a' \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS seq FROM pt WHERE h ? 'a' \gset gs_
SELECT CASE WHEN :'gi_idx'=:'gs_seq' THEN 'PASS' ELSE 'FAIL' END AS r, 'h ? a' AS probe, :'gi_idx' AS idx, :'gs_seq' AS seq;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS idx FROM pt WHERE h ? 'k' \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS seq FROM pt WHERE h ? 'k' \gset gs_
SELECT CASE WHEN :'gi_idx'=:'gs_seq' THEN 'PASS' ELSE 'FAIL' END AS r, 'h ? k' AS probe, :'gi_idx' AS idx, :'gs_seq' AS seq;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS idx FROM pt WHERE h ? 'shared' \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS seq FROM pt WHERE h ? 'shared' \gset gs_
SELECT CASE WHEN :'gi_idx'=:'gs_seq' THEN 'PASS' ELSE 'FAIL' END AS r, 'h ? shared' AS probe, :'gi_idx' AS idx, :'gs_seq' AS seq;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS idx FROM pt WHERE h ? 'nope' \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS seq FROM pt WHERE h ? 'nope' \gset gs_
SELECT CASE WHEN :'gi_idx'=:'gs_seq' THEN 'PASS' ELSE 'FAIL' END AS r, 'h ? nope' AS probe, :'gi_idx' AS idx, :'gs_seq' AS seq;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS idx FROM pt WHERE h ?| ARRAY['a','nope'] \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS seq FROM pt WHERE h ?| ARRAY['a','nope'] \gset gs_
SELECT CASE WHEN :'gi_idx'=:'gs_seq' THEN 'PASS' ELSE 'FAIL' END AS r, 'h ?| ARRAY[a,nope]' AS probe, :'gi_idx' AS idx, :'gs_seq' AS seq;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS idx FROM pt WHERE h ?& ARRAY['a','b'] \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS seq FROM pt WHERE h ?& ARRAY['a','b'] \gset gs_
SELECT CASE WHEN :'gi_idx'=:'gs_seq' THEN 'PASS' ELSE 'FAIL' END AS r, 'h ?& ARRAY[a,b]' AS probe, :'gi_idx' AS idx, :'gs_seq' AS seq;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS idx FROM pt WHERE h ?& ARRAY['shared','other'] \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS seq FROM pt WHERE h ?& ARRAY['shared','other'] \gset gs_
SELECT CASE WHEN :'gi_idx'=:'gs_seq' THEN 'PASS' ELSE 'FAIL' END AS r, 'h ?& ARRAY[shared,other]' AS probe, :'gi_idx' AS idx, :'gs_seq' AS seq;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS idx FROM pt WHERE h ?& ARRAY['a','nope'] \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS seq FROM pt WHERE h ?& ARRAY['a','nope'] \gset gs_
SELECT CASE WHEN :'gi_idx'=:'gs_seq' THEN 'PASS' ELSE 'FAIL' END AS r, 'h ?& ARRAY[a,nope]' AS probe, :'gi_idx' AS idx, :'gs_seq' AS seq;
