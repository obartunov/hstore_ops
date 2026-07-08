#!/usr/bin/env bash
# bench/repeat.sh [DB]  -- repeated-subquery ("amplification") latency method.
#
# Instead of timing one EXPLAIN ANALYZE (whose per-node instrumentation inflates
# sub-millisecond queries), we place the SAME scalar subquery N times, comma-
# separated, in the target list of ONE SELECT and time it with \timing; the
# per-query cost is total/N.  Planning is done once; the N copies are separate
# InitPlans, each executed once (not folded).  N=100 for fast probes, 20 for the
# low-selectivity ones.  Requires a loaded `bench` table (see run.sh / gen.sql).
set -uo pipefail
DB="${1:-bench}"
PSQL="psql -U ${PGUSER:-postgres} -d $DB -X -q"

# emit: SELECT (sq),(sq),...,(sq);   with N copies
sel() { local pred="$1" n="$2" i; printf 'SELECT '
        for i in $(seq 1 "$n"); do printf '(SELECT count(*) FROM bench WHERE %s)' "$pred"
          [ "$i" -lt "$n" ] && printf ','; done; printf ';\n'; }

# time one probe: label predicate N  -> prints "label: <ms/query> ms (rows=<c>)"
probe() {
  local lbl="$1" pred="$2" n="$3" out t
  out=$($PSQL -c "SET enable_seqscan=off; SET enable_bitmapscan=on;" \
              -c '\timing on' -c "$(sel "$pred" "$n")" 2>&1)
  t=$(printf '%s\n' "$out" | grep -oP 'Time: \K[0-9.]+' | tail -1)
  awk -v t="$t" -v n="$n" -v l="$lbl" 'BEGIN{printf "  %-16s %.4f ms/query (N=%d)\n", l, t/n, n}'
}

config() { # label create_sql
  echo "== $1 =="
  $PSQL -c "DROP INDEX IF EXISTS x1;" >/dev/null 2>&1
  $PSQL -c "$2" 2>&1 | grep -i error || true
  probe "q1 selective"  "h @> 'shard=>S777'"         100
  probe "q5 key-exists" "h ? 'shard'"                100
  probe "q4 negative"   "h @> 'env=>gold'"           100
  probe "q3 multi"      "h @> 'env=>prod, tier=>gold'" 20
  probe "q2 medium"     "h @> 'env=>prod'"            20
  $PSQL -c "DROP INDEX x1;" >/dev/null 2>&1
}

config "gin_hstore_ops (default)"  "CREATE INDEX x1 ON bench USING gin (h gin_hstore_ops);"
config "gin_hstore_hash_ops"       "CREATE INDEX x1 ON bench USING gin (h gin_hstore_hash_ops);"
