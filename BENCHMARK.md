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
| GUCs | shared_buffers=1GB, work_mem=64MB, maintenance_work_mem=512MB, effective_cache_size=2GB, max_parallel_workers_per_gather=0, autovacuum=off |
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
* Latency = best of 3 warm `EXPLAIN (ANALYZE, BUFFERS)` runs. Raw plans in
  `bench/results/raw_*.txt`. Runner: `bench/run.sh`.
* Correctness (separate from performance): `correctness.sql`, index-vs-seqscan
  oracle, 30/30 probes identical.

## Scope / caveats

Run at **1,000,000 rows** (headline) and 50,000 (smoke); both agree. 5M/10M and
20–50-pair "medium dictionary" shapes were **not** run — single-core / 3.9 GiB
container. The findings that carry weight here (build time, index size,
negative-lookup latency, recheck volume) are structural and stable across the
two scales measured; the low-selectivity `@>` numbers are heap-bound and should
be read as "no meaningful difference", not precise ratios.

## Index size and build time (1,000,000 rows; heap = 468 MB)

| opclass | column | index size | vs default | build time | vs default |
|---|---|---:|---:|---:|---:|
| `gin_hstore_ops` (default) | hstore | 27.82 MB | — | 6.69 s | — |
| **`gin_hstore_hash_ops`** | hstore | **29.41 MB** | **+5.7%** | **2.91 s** | **0.43× (2.3× faster)** |
| `jsonb_ops` | jsonb | 27.82 MB | −0.0% | 5.52 s | 0.82× |
| `jsonb_path_ops` | jsonb | 29.40 MB | +5.7% | 3.29 s | 0.49× |

The hash opclass is **larger**, not smaller. Splitting each pair into its own
GIN key produces many more distinct keys with short posting lists; the default
opclass's few keys with long, delta-compressed posting lists pack tighter. The
penalty shrinks with scale (+57% at 50k → +6% at 1M) but stayed positive.
Build is ~2.3× faster (integer keys, no collation-aware text compares).
`jsonb_path_ops` — the same pair-hash idea — mirrors the hash opclass exactly.

## Query latency (1,000,000 rows; best-of-3 warm, ms)

| query | seqscan | default | **hash** | jsonb_ops | jsonb_path_ops | rows |
|---|---:|---:|---:|---:|---:|---:|
| q1 selective `@>` (`shard=>S777`) | 171.6 | 0.67 | **0.65** | 0.71 | 0.71 | 1000 |
| q2 medium `@>` (`env=>prod`) | 206.4 | 189.8 | **164.1** | 220.1 | 205.1 | 333756 |
| q3 multi `@>` (`env=>prod,tier=>gold`) | 194.8 | 132.1 | **107.1** | 154.1 | 125.7 | 110641 |
| **q4 negative `@>` (`env=>gold`)** | 184.3 | 168.5 | **0.12** | 202.5 | 0.06 | 0 |
| q5 key-exists `?` (`shard`) | 158.5 | 0.52 | 0.54 | 0.60 | n/a | 1000 |

`jsonb_path_ops` does not support `?` (n/a).

### The decisive case: q4 negative lookup

`env` is present in every row; `gold` is present in ~33% of rows (as `tier`);
the pair `env=>gold` exists nowhere. Raw plans (last of 3 runs):

**Default `gin_hstore_ops`** — intersects the two huge token posting lists,
fetches a third of the table, and recheck discards all of it:

```
Aggregate (actual time=167.904..167.906 rows=1.00)
  Buffers: shared hit=39115
  ->  Bitmap Heap Scan on bench (rows=0.00)
        Recheck Cond: (h @> '"env"=>"gold"'::hstore)
        Rows Removed by Index Recheck: 333575
        Heap Blocks: exact=38833
        Buffers: shared hit=39115
        ->  Bitmap Index Scan on bx (rows=333575.00)
              Buffers: shared hit=282
 Execution Time: 168.481 ms
```

**`gin_hstore_hash_ops`** — the pair hash is simply absent; answered from the
index with 4 buffers and no heap access:

```
Aggregate (actual time=0.019..0.019 rows=1.00)
  Buffers: shared hit=4
  ->  Bitmap Heap Scan on bench (rows=0.00)
        Recheck Cond: (h @> '"env"=>"gold"'::hstore)
        Buffers: shared hit=4
        ->  Bitmap Index Scan on bx (rows=0.00)
              Buffers: shared hit=4
 Execution Time: 0.122 ms
```

~1380× faster, 39115 → 4 buffers, 333575 → 0 rechecked. `jsonb_path_ops`
behaves identically (0.056 ms). This is the mechanism working exactly as
designed: indexing the pair as a unit turns a table-scan-sized recheck into an
index miss.

### Where it does not win

* q1 selective and q5 key-exists: tied with the default opclass (both ~0.5 ms).
  `?` is a hair slower via partial match.
* q2/q3 low-selectivity `@>`: the hash opclass is 13–19% faster, but all
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
same ground for `jsonb`. No claim in this report is made without the raw
`EXPLAIN`/size artifacts in `bench/results/`.
