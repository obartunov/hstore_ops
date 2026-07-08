#!/usr/bin/env bash
# bench/run.sh : reproducible hstore hash-opclass benchmark against PG master.
# Usage: NROWS=1000000 bench/run.sh
# Requires a running server with extensions hstore + hstore_hash_ops installed,
# psql on PATH, PGUSER=postgres (trust). Each index config is measured in
# isolation (competitors dropped, enable_seqscan=off).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
NROWS="${NROWS:-1000000}"
DB="${DB:-bench}"
OUT="${OUT:-$HERE/results}"
GEN="${GEN:-$HERE/gen.sql}"
PSQL="psql -U ${PGUSER:-postgres} -d $DB -X -q -v ON_ERROR_STOP=1"
mkdir -p "$OUT"; : > "$OUT/latency.tsv"; : > "$OUT/sizes.tsv"
q() { psql -U "${PGUSER:-postgres}" -d "$DB" -X -tA -c "$1"; }

echo "== load $NROWS rows =="
psql -U "${PGUSER:-postgres}" -d "$DB" -X -q -v nrows="$NROWS" -f "$GEN" >/dev/null
printf 'nrows\t%s\n' "$NROWS" >> "$OUT/sizes.tsv"
printf 'heap_bytes\t%s\n' "$(q "SELECT pg_relation_size('bench');")" >> "$OUT/sizes.tsv"

declare -A IDX=(
  [std]="CREATE INDEX bx ON bench USING gin (h gin_hstore_ops);"
  [hash]="CREATE INDEX bx ON bench USING gin (h gin_hstore_hash_ops);"
  [jsonb_ops]="CREATE INDEX bx ON bench USING gin (j jsonb_ops);"
  [jpath]="CREATE INDEX bx ON bench USING gin (j jsonb_path_ops);"
)
declare -A H=(
  [q1_selective]="h @> 'shard=>S777'"
  [q2_medium]="h @> 'env=>prod'"
  [q3_multi]="h @> 'env=>prod, tier=>gold'"
  [q4_neglookup]="h @> 'env=>gold'"
  [q5_keyexist]="h ? 'shard'"
)
declare -A J=(
  [q1_selective]="j @> '{\"shard\":\"S777\"}'"
  [q2_medium]="j @> '{\"env\":\"prod\"}'"
  [q3_multi]="j @> '{\"env\":\"prod\",\"tier\":\"gold\"}'"
  [q4_neglookup]="j @> '{\"env\":\"gold\"}'"
  [q5_keyexist]="j ? 'shard'"
)
ORDER="q1_selective q2_medium q3_multi q4_neglookup q5_keyexist"

measure() {
  local cfg="$1" qid="$2" pred="$3"
  local f="$OUT/raw_${cfg}_${qid}.txt"
  local best rows rech hb sql
  sql="EXPLAIN (ANALYZE, BUFFERS, COSTS OFF) SELECT count(*) FROM bench WHERE $pred;"
  : > "$f"
  for i in 1 2 3; do
    psql -U "${PGUSER:-postgres}" -d "$DB" -X -c "SET enable_seqscan=off;" -c "$sql" >>"$f" 2>&1
    echo "----" >>"$f"
  done
  best=$(grep -oE 'Execution Time: [0-9.]+' "$f" | awk '{print $3}' | sort -n | head -1)
  rows=$(grep -oE 'actual [^)]*rows=[0-9.]+' "$f" | tail -1 | grep -oE 'rows=[0-9.]+' | tail -1 | cut -d= -f2)
  rech=$(grep -oE 'Rows Removed by Index Recheck: [0-9]+' "$f" | tail -1 | grep -oE '[0-9]+$'); rech=${rech:-0}
  hb=$(grep -oE 'Heap Blocks: exact=[0-9]+' "$f" | tail -1 | grep -oE '[0-9]+$'); hb=${hb:-0}
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$cfg" "$qid" "${best:-NA}" "${rows:-NA}" "$rech" "$hb" >> "$OUT/latency.tsv"
}

printf 'config\tqid\texec_ms_best\trows\trecheck_removed\theap_blocks_exact\n' >> "$OUT/latency.tsv"
$PSQL -c "DROP INDEX IF EXISTS bx;" >/dev/null
for qid in $ORDER; do measure none "$qid" "${H[$qid]}"; done

for cfg in std hash jsonb_ops jpath; do
  $PSQL -c "DROP INDEX IF EXISTS bx;" >/dev/null
  T0=$(date +%s%N); $PSQL -c "${IDX[$cfg]}" >/dev/null; T1=$(date +%s%N)
  printf '%s_build_ms\t%s\n' "$cfg" "$(( (T1-T0)/1000000 ))" >> "$OUT/sizes.tsv"
  printf '%s_index_bytes\t%s\n' "$cfg" "$(q "SELECT pg_relation_size('bx');")" >> "$OUT/sizes.tsv"
  for qid in $ORDER; do
    if [[ "$cfg" == jsonb_ops || "$cfg" == jpath ]]; then pred="${J[$qid]}"; else pred="${H[$qid]}"; fi
    if [[ "$cfg" == jpath && "$qid" == q5_keyexist ]]; then
      printf '%s\t%s\tNA\tNA\tNA\tNA\n' "$cfg" "$qid" >> "$OUT/latency.tsv"; continue
    fi
    measure "$cfg" "$qid" "$pred"
  done
done
echo "== done; see $OUT/sizes.tsv and $OUT/latency.tsv =="
