# BENCHMARK.md — gin_hstore_hash_ops vs modern PostgreSQL master

**Question.** For flat text key/value metadata, does the 2014 hash opclass idea
still deliver a *smaller, more selective* physical GIN representation on current
master — the way `jsonb_path_ops` does for jsonb?

**Short answer.** The selectivity win is real and sometimes huge (pair-level
`@>`, negative lookups). The *size* win is gone: modern GIN posting-list
compression makes the default opclass ~6% **smaller**, not larger. And
`jsonb_path_ops`, already in core, matches the hash opclass point-for-point.

## Environment

| item | value |
|---|---|
| PostgreSQL | 20devel, commit `16a4b3ef8ee` (github.com/postgres/postgres) |
| build | gcc 13.3.0, `CFLAGS=-O2`, `--without-icu --without-readline`, cassert OFF |
| kernel | Linux 6.18.5 x86_64 |
| cpu / mem | 1 vCPU, 3.9 GiB (constrained container — see *Scope*) |
| GUCs | shared_buffers=512MB, work_mem=64MB, maintenance_work_mem=256MB (128MB for the jsonb_path_ops build), effective_cache_size=1536MB, max_parallel_workers_per_gather=0, fsync=off, synchronous_commit=off, full_page_writes=off, autovacuum=off |
| extension | `hstore_hash_ops` 1.0 (this branch) |

## Methodology

* Data: `bench/gen.sql`, deterministic (values derived from `gid` via
  `hashint4`, reproducible on a clean checkout). Each row is an hstore of
  3–9 filler pairs (`k0..k49 => v0..v199`) plus structured pairs
  `env∈{prod,staging,dev}`, `tier∈{gold,silver,bronze}`, `region∈{r0..r19}`,
  and a rare `shard=>S777` in ~0.1% of rows. An identical `jsonb` column is
  produced with `hstore_to_jsonb` so hstore and jsonb opclasses see the same
  logical data.
* By construction the value `gold` only ever appears under key `tier`, never
  under `env`, so `@> 'env=>gold'` returns 0 rows although both tokens are
  extremely common — the negative-lookup stress case.
* Each index config is measured **in isolation** (competitors dropped,
  `enable_seqscan=off`) so the planner is forced onto the intended path.
* Latency = **repeated-subquery timing** (the amplification method): the same
  scalar subquery is placed `N` times, comma-separated, in the target list of a
  single `SELECT`, run under `\timing`; per-query time = total / `N`. Planning
  happens once; the `N` copies are separate InitPlans, each executed once
  (verified: three identical copies produce `InitPlan expr_1/2/3`, not folded to
  one). This removes per-node `EXPLAIN ANALYZE` instrumentation and one-shot
  round-trip/planning overhead, which matters for the sub-millisecond point
  lookups. `N=100` for the fast probes, `N=20` for the low-selectivity ones; the
  first execution warms the cache. Generator: `bench/repeat.sh`.
  (An earlier draft of this report used median-of-N separate `EXPLAIN ANALYZE`
  runs; that inflated the sub-ms lookups ~1.5–2× and made q1 look like a small
  default-opclass win — an instrumentation artifact. The corrected method below
  shows q1 is a tie.) Structural raw plans for the decisive case in `bench/raw/`.
  Config runner (sizes/build/CSV): `bench/run.sh`.
* Correctness (separate from performance): `correctness.sql`, index-vs-seqscan
  oracle, 30/30 probes identical.

## Scope / caveats

Run at **1,000,000 rows** (headline) and 100,000 (smoke); both agree. 5M/10M and
20–50-pair "medium dictionary" shapes were **not** run — single-core / 3.9 GiB
container. The findings that carry weight here (build time, index size,
negative-lookup latency, recheck volume) are structural and stable across the
two scales measured; the low-selectivity `@>` numbers are heap-bound and should
be read as "no meaningful difference", not precise ratios.

## Index size and build time (1,000,000 rows; heap = 491 MB)

| opclass | column | index size | vs default | build time | vs default |
|---|---|---:|---:|---:|---:|
| `gin_hstore_ops` (default) | hstore | 29.17 MB | — | 6.65 s | — |
| **`gin_hstore_hash_ops`** | hstore | **30.83 MB** | **+5.7%** | **3.12 s** | **0.47× (2.1× faster)** |
| `jsonb_ops` | jsonb | 29.17 MB | −0.0% | 5.52 s | 0.83× |
| `jsonb_path_ops` | jsonb | 30.83 MB | +5.7% | 3.39 s | 0.51× |

The hash opclass is **larger**, not smaller. Splitting each pair into its own
GIN key produces many more distinct keys with short posting lists; the default
opclass's few keys with long, delta-compressed posting lists pack tighter. The
penalty shrinks with scale (+13% at 100k → +5.7% at 1M) but stayed positive.
Build is ~2.1× faster (integer keys, no collation-aware text compares).
`jsonb_path_ops` — the same pair-hash idea — mirrors the hash opclass exactly.

This is a **short-value** result and does not generalize: "hash is smaller" is
not a universal property. The hash opclass's real structural property is a
**bounded entry size** (every pair is a fixed 8 bytes), which makes it robust to
long/high-entropy values and can make it smaller — or the only buildable
opclass — when exact text/pair entries are large. On real catalog data
(`hstore(pg_proc)`) the default opclass and the exact pair opclass fail to build
at all while hash builds; see `FINDINGS.md` for that comparison.

## Query latency (1,000,000 rows; repeated-subquery per-query, ms)

| query | seqscan | default | hash | jsonb_ops | jsonb_path_ops | rows |
|---|---:|---:|---:|---:|---:|---:|
| q1 selective `@>` (`shard=>S777`) | ~184 | 0.320 | 0.331 | 1.00 | 0.99 | 1000 |
| q2 medium `@>` (`env=>prod`) | ~204 | 188.0 | **148.6** | 374.0 | 362.0 | 333756 |
| q3 multi `@>` (`env=>prod,tier=>gold`) | ~195 | 131.7 | **97.2** | 226.6 | 211.0 | 110641 |
| **q4 negative `@>` (`env=>gold`)** | ~184 | 198.0 | **0.050** | 360.1 | 0.064 | 0 |
| q5 key-exists `?` (`shard`) | ~169 | **0.201** | 0.276 | ~0.6 | n/a | 1000 |

Bold = fastest in row (seqscan column is an approximate baseline, single-node so
instrumentation-insensitive; not re-measured with the repeated method). `jsonb_path_ops`
has no `?` (n/a). Notes:

* **q1 selective is a tie** (0.320 vs 0.331 ms) — the earlier "default wins q1"
  reading was `EXPLAIN ANALYZE` overhead, not a real difference.
* **q4 negative** is the decisive case: the hash opclass is **~2000–4000×** faster (run-to-run variance, single core)
  than the default (198.0 → 0.050 ms). Among jsonb opclasses the split is the
  same, several thousand× (`jsonb_path_ops` 0.064 vs `jsonb_ops` 360.1 ms).
* q2/q3 low-selectivity `@>`: hash is 27–35% faster than default, but all are
  heap-bound. jsonb `@>` is ~2× slower than hstore `@>` here (pricier per-tuple
  recheck on the jsonb representation), independent of opclass.
* q5 key-exists: default marginally ahead (both sub-ms; `?` uses partial match).

### The decisive case: q4 negative lookup

`env` is present in every row; `gold` is present in ~33% of rows (as `tier`);
the pair `env=>gold` exists nowhere. Raw plans (last of 3 runs):

**Default `gin_hstore_ops`** — intersects the two huge token posting lists,
fetches a third of the table, and recheck discards all of it:

```
Aggregate (actual time=198.465..198.467 rows=1.00)
  Buffers: shared hit=39115
  ->  Bitmap Heap Scan on bench (rows=0.00)
        Recheck Cond: (h @> '"env"=>"gold"'::hstore)
        Rows Removed by Index Recheck: 333575
        Heap Blocks: exact=38833
        Buffers: shared hit=39115
        ->  Bitmap Index Scan on bx (actual time=43.437..43.438 rows=333575.00)
```

**`gin_hstore_hash_ops`** — the pair hash is simply absent; answered from the
index with 4 buffers and no heap access:

```
Aggregate (actual time=0.024..0.024 rows=1.00)
  Buffers: shared hit=4
  ->  Bitmap Heap Scan on bench (rows=0.00)
        Recheck Cond: (h @> '"env"=>"gold"'::hstore)
        Buffers: shared hit=4
        ->  Bitmap Index Scan on bx (actual time=0.015..0.015 rows=0.00)
              Index Cond: (h @> '"env"=>"gold"'::hstore)
```

~2000–4000× faster by the repeated-subquery method (≈188–198 ms → ≈0.05–0.10 ms
per query across runs on a loaded single core; the
single instrumented plans above show 198.5 → 0.024 ms), 39115 → 4 buffers,
333575 → 0 rechecked. `jsonb_path_ops` behaves identically (0.064 ms). This is
the mechanism working exactly as designed: indexing the pair as a unit turns a
table-scan-sized recheck into an index miss.

### Where it does not win

* q1 selective `@>`: a tie (0.320 vs 0.331 ms). q5 key-exists `?`: default
  marginally ahead (0.201 vs 0.276 ms). Both are sub-millisecond point lookups;
  `?` goes through partial match on the key hash. No practically meaningful gap.
* q2/q3 low-selectivity `@>`: the hash opclass is 27–35% faster, but all
  configs are heap-bound (fetching 36–39k blocks for 100–330k result rows) and
  barely beat the seqscan — not an index-selectivity story.
* Size: loses to the default opclass (above).

## Correctness (separate from performance)

`correctness.sql`: for `@>`, `?`, `?|`, `?&` over the full edge-case dataset,
the index result set equals the seqscan-oracle result set for all 30 probes —
no false positives, no false negatives. `EXPLAIN` confirms every plan carries a
`Recheck Cond` (the opclass forces recheck unconditionally). `installcheck`
regression (`sql/`, `expected/`) passes.

## Verdict

**Candidate for extension only.**

* Correct, and the pair-selectivity / negative-lookup win is genuine and large.
* But it is **not** smaller on modern compressed GIN (the historical headline
  claim no longer holds on flat data), key-existence is marginally slower, and
  low-selectivity `@>` is heap-bound for everyone.
* Decisively, **`jsonb_path_ops` already delivers the identical mechanism and
  performance in core**. A user wanting this behavior can store the metadata as
  `jsonb` and use `jsonb_path_ops` today.

So it is worth maintaining as an extension for users committed to the `hstore`
type who want `jsonb_path_ops`-style `@>` selectivity without migrating — but it
is **not** a compelling `contrib`/core addition, because core already covers the
same ground for `jsonb`. Reproducers and artifacts: `bench/run.sh` (sizes /
build / CSV), `bench/repeat.sh` (per-query latency), decisive raw plans in
`bench/raw/`, results in `bench/summary_1m.csv`.
