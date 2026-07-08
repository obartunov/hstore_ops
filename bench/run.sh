#!/usr/bin/env bash
# bench/run.sh NROWS  -- reproducible hstore hash-opclass benchmark on PG master.
set -uo pipefail
NROWS="${1:-1000000}"
DB=bench
HERE="$(cd "$(dirname "$0")" && pwd)"
RAW="$HERE/raw"; mkdir -p "$RAW"
CSV="$HERE/summary.csv"
PSQL="psql -U postgres -d $DB -X -q -v ON_ERROR_STOP=1"
echo "config,metric,value" > "$CSV"
psql -U postgres -X -q -c "DROP DATABASE IF EXISTS $DB;" -c "CREATE DATABASE $DB;"
$PSQL -c "CREATE EXTENSION hstore; CREATE EXTENSION hstore_hash_ops;"
echo ">> generating $NROWS rows"
$PSQL -v nrows="$NROWS" -f "$HERE/gen.sql" >/dev/null
HEAP=$($PSQL -tAc "SELECT pg_relation_size('bench')")
echo "none,heap_bytes,$HEAP" >> "$CSV"
declare -a HPROBES=(
  "sel_hstore|h|h @> 'shard=>S777'"
  "med_hstore|h|h @> 'env=>prod'"
  "multi_hstore|h|h @> 'env=>prod, tier=>gold'"
  "neg_hstore|h|h @> 'env=>gold'"
  "exists_hstore|h|h ? 'shard'"
)
declare -a JPROBES=(
  "sel_jsonb|j|j @> '{\"shard\":\"S777\"}'"
  "med_jsonb|j|j @> '{\"env\":\"prod\"}'"
  "multi_jsonb|j|j @> '{\"env\":\"prod\",\"tier\":\"gold\"}'"
  "neg_jsonb|j|j @> '{\"env\":\"gold\"}'"
  "exists_jsonb|j|j ? 'shard'"
)
run_probe () {
  local cfg="$1" label="$2" pred="$3"
  local f="$RAW/${cfg}__${label}.txt"
  $PSQL -c "SET enable_seqscan=$SEQ; SET enable_bitmapscan=$BMP; SET enable_indexscan=$BMP;
            EXPLAIN (ANALYZE, BUFFERS, COSTS off) SELECT count(*) FROM bench WHERE $pred;" >/dev/null 2>&1
  $PSQL -c "SET enable_seqscan=$SEQ; SET enable_bitmapscan=$BMP; SET enable_indexscan=$BMP;
            EXPLAIN (ANALYZE, BUFFERS, COSTS off) SELECT count(*) FROM bench WHERE $pred;" > "$f" 2>&1
  local et rr rows bh
  et=$(grep -oP 'Execution Time: \K[0-9.]+' "$f" | tail -1); et=${et:-NA}
  rr=$(grep -oP 'Rows Removed by Index Recheck: \K[0-9]+' "$f" | tail -1); rr=${rr:-0}
  rows=$(grep -oP 'Bitmap Heap Scan.*actual rows=\K[0-9.]+' "$f" | tail -1)
  [ -z "${rows:-}" ] && rows=$(grep -oP 'Seq Scan.*actual rows=\K[0-9.]+' "$f" | tail -1)
  rows=${rows:-NA}
  bh=$(grep -oP 'shared hit=\K[0-9]+' "$f" | awk '{s+=$1} END{print s+0}')
  { echo "$cfg,$label:exec_ms,$et"; echo "$cfg,$label:recheck_removed,$rr"; echo "$cfg,$label:heap_rows,$rows"; echo "$cfg,$label:shared_hit,$bh"; } >> "$CSV"
}
echo ">> config: none (seqscan)"
SEQ=on; BMP=off
for p in "${HPROBES[@]}" "${JPROBES[@]}"; do IFS='|' read -r l c pred <<<"$p"; run_probe none "$l" "$pred"; done
bench_index () {
  local cfg="$1" create="$2" rel="$3"; shift 3
  echo ">> config: $cfg (build index)"
  local t
  t=$($PSQL -c '\timing on' -c "$create" 2>&1 | grep -oP 'Time: \K[0-9.]+' | tail -1)
  echo "$cfg,build_ms,${t:-NA}" >> "$CSV"
  local sz; sz=$($PSQL -tAc "SELECT pg_relation_size('$rel')")
  echo "$cfg,index_bytes,${sz:-NA}" >> "$CSV"
  SEQ=off; BMP=on
  for p in "$@"; do IFS='|' read -r l c pred <<<"$p"; run_probe "$cfg" "$l" "$pred"; done
  $PSQL -c "DROP INDEX $rel;"
}
bench_index gin_std        "CREATE INDEX bench_gin_std  ON bench USING gin (h gin_hstore_ops);"      bench_gin_std  "${HPROBES[@]}"
bench_index gin_hash       "CREATE INDEX bench_gin_hash ON bench USING gin (h gin_hstore_hash_ops);" bench_gin_hash "${HPROBES[@]}"
bench_index jsonb_ops      "CREATE INDEX bench_jb1 ON bench USING gin (j jsonb_ops);"                bench_jb1 "${JPROBES[@]}"
bench_index jsonb_path_ops "CREATE INDEX bench_jb2 ON bench USING gin (j jsonb_path_ops);"           bench_jb2 "${JPROBES[@]:0:4}"
echo ">> done. summary: $CSV"
