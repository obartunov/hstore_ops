DROP TABLE IF EXISTS pk;
CREATE TABLE pk(id int, h hstore);
INSERT INTO pk VALUES (1, 'a=>1');
INSERT INTO pk VALUES (2, 'a=>2');
INSERT INTO pk VALUES (3, 'a=>NULL');
INSERT INTO pk VALUES (4, 'a=>""');
INSERT INTO pk VALUES (5, 'b=>1');
INSERT INTO pk VALUES (6, 'c=>NULL');
INSERT INTO pk VALUES (7, ''::hstore);
INSERT INTO pk VALUES (8, NULL);
CREATE INDEX pki ON pk USING gin (h gin_hstore_pair_ops);
ANALYZE pk;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM pk WHERE h ? 'a' \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM pk WHERE h ? 'a' \gset gs_
SELECT CASE WHEN :'gi_v'=:'gs_v' THEN 'PASS' ELSE 'FAIL' END AS r,'? a (val=ANY)' AS probe,:'gi_v' AS idx,:'gs_v' AS seq;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM pk WHERE h ? 'b' \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM pk WHERE h ? 'b' \gset gs_
SELECT CASE WHEN :'gi_v'=:'gs_v' THEN 'PASS' ELSE 'FAIL' END AS r,'? b' AS probe,:'gi_v' AS idx,:'gs_v' AS seq;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM pk WHERE h ? 'missing' \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM pk WHERE h ? 'missing' \gset gs_
SELECT CASE WHEN :'gi_v'=:'gs_v' THEN 'PASS' ELSE 'FAIL' END AS r,'? missing' AS probe,:'gi_v' AS idx,:'gs_v' AS seq;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM pk WHERE h ? 'c' \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM pk WHERE h ? 'c' \gset gs_
SELECT CASE WHEN :'gi_v'=:'gs_v' THEN 'PASS' ELSE 'FAIL' END AS r,'? c (null val)' AS probe,:'gi_v' AS idx,:'gs_v' AS seq;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM pk WHERE h @> 'a=>1' \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM pk WHERE h @> 'a=>1' \gset gs_
SELECT CASE WHEN :'gi_v'=:'gs_v' THEN 'PASS' ELSE 'FAIL' END AS r,'@> a=>1' AS probe,:'gi_v' AS idx,:'gs_v' AS seq;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM pk WHERE h @> 'a=>NULL' \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM pk WHERE h @> 'a=>NULL' \gset gs_
SELECT CASE WHEN :'gi_v'=:'gs_v' THEN 'PASS' ELSE 'FAIL' END AS r,'@> a=>NULL' AS probe,:'gi_v' AS idx,:'gs_v' AS seq;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM pk WHERE h ? 'a' AND NOT h @> 'a=>1' \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM pk WHERE h ? 'a' AND NOT h @> 'a=>1' \gset gs_
SELECT CASE WHEN :'gi_v'=:'gs_v' THEN 'PASS' ELSE 'FAIL' END AS r,'? a AND NOT @> a=>1' AS probe,:'gi_v' AS idx,:'gs_v' AS seq;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM pk WHERE h ?| ARRAY['a','b'] \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM pk WHERE h ?| ARRAY['a','b'] \gset gs_
SELECT CASE WHEN :'gi_v'=:'gs_v' THEN 'PASS' ELSE 'FAIL' END AS r,'?| [a,b]' AS probe,:'gi_v' AS idx,:'gs_v' AS seq;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM pk WHERE h ?& ARRAY['a','b'] \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM pk WHERE h ?& ARRAY['a','b'] \gset gs_
SELECT CASE WHEN :'gi_v'=:'gs_v' THEN 'PASS' ELSE 'FAIL' END AS r,'?& [a,b]' AS probe,:'gi_v' AS idx,:'gs_v' AS seq;
INSERT INTO pk VALUES (9, 'a=>1,b=>2');
REINDEX INDEX pki;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM pk WHERE h ?& ARRAY['a','b'] \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM pk WHERE h ?& ARRAY['a','b'] \gset gs_
SELECT CASE WHEN :'gi_v'=:'gs_v' THEN 'PASS' ELSE 'FAIL' END AS r,'?& [a,b] after row9' AS probe,:'gi_v' AS idx,:'gs_v' AS seq;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM pk WHERE h ?| ARRAY[]::text[] \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM pk WHERE h ?| ARRAY[]::text[] \gset gs_
SELECT CASE WHEN :'gi_v'=:'gs_v' THEN 'PASS' ELSE 'FAIL' END AS r,'?| []' AS probe,:'gi_v' AS idx,:'gs_v' AS seq;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM pk WHERE h ?& ARRAY[]::text[] \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM pk WHERE h ?& ARRAY[]::text[] \gset gs_
SELECT CASE WHEN :'gi_v'=:'gs_v' THEN 'PASS' ELSE 'FAIL' END AS r,'?& []' AS probe,:'gi_v' AS idx,:'gs_v' AS seq;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM pk WHERE h ?& ARRAY['a','a'] \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM pk WHERE h ?& ARRAY['a','a'] \gset gs_
SELECT CASE WHEN :'gi_v'=:'gs_v' THEN 'PASS' ELSE 'FAIL' END AS r,'?& [a,a] dup' AS probe,:'gi_v' AS idx,:'gs_v' AS seq;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM pk WHERE h ?| ARRAY['a','a'] \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM pk WHERE h ?| ARRAY['a','a'] \gset gs_
SELECT CASE WHEN :'gi_v'=:'gs_v' THEN 'PASS' ELSE 'FAIL' END AS r,'?| [a,a] dup' AS probe,:'gi_v' AS idx,:'gs_v' AS seq;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM pk WHERE h ?| ARRAY['a',NULL] \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM pk WHERE h ?| ARRAY['a',NULL] \gset gs_
SELECT CASE WHEN :'gi_v'=:'gs_v' THEN 'PASS' ELSE 'FAIL' END AS r,'?| [a,NULL]' AS probe,:'gi_v' AS idx,:'gs_v' AS seq;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM pk WHERE h ?& ARRAY['a',NULL] \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM pk WHERE h ?& ARRAY['a',NULL] \gset gs_
SELECT CASE WHEN :'gi_v'=:'gs_v' THEN 'PASS' ELSE 'FAIL' END AS r,'?& [a,NULL]' AS probe,:'gi_v' AS idx,:'gs_v' AS seq;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM pk WHERE h ? '' \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM pk WHERE h ? '' \gset gs_
SELECT CASE WHEN :'gi_v'=:'gs_v' THEN 'PASS' ELSE 'FAIL' END AS r,'? emptykey' AS probe,:'gi_v' AS idx,:'gs_v' AS seq;
INSERT INTO pk VALUES (10, 'ключ=>v');
INSERT INTO pk VALUES (11, hstore(repeat('K',300),'v'));
INSERT INTO pk SELECT 12, hstore(array_agg('p'||g), array_agg('q'||g)) FROM generate_series(1,300) g;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM pk WHERE h ? 'ключ' \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM pk WHERE h ? 'ключ' \gset gs_
SELECT CASE WHEN :'gi_v'=:'gs_v' THEN 'PASS' ELSE 'FAIL' END AS r,'? non-ascii' AS probe,:'gi_v' AS idx,:'gs_v' AS seq;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM pk WHERE h ? 'KKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKK' \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM pk WHERE h ? 'KKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKK' \gset gs_
SELECT CASE WHEN :'gi_v'=:'gs_v' THEN 'PASS' ELSE 'FAIL' END AS r,'? longkey' AS probe,:'gi_v' AS idx,:'gs_v' AS seq;
SET enable_seqscan=off;SET enable_bitmapscan=on;SET enable_indexscan=on;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM pk WHERE h ? 'p250' \gset gi_
SET enable_seqscan=on;SET enable_bitmapscan=off;SET enable_indexscan=off;
SELECT coalesce(string_agg(id::text,',' ORDER BY id),'-') AS v FROM pk WHERE h ? 'p250' \gset gs_
SELECT CASE WHEN :'gi_v'=:'gs_v' THEN 'PASS' ELSE 'FAIL' END AS r,'? toastkey' AS probe,:'gi_v' AS idx,:'gs_v' AS seq;
