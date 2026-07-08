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
* Latency = median of 7 warm `EXPLAIN (ANALYZE)` runs for the hstore `@>`
  probes, median of 5 for the jsonb probes, each preceded by a warm-up run;
  measured on an otherwise-idle server (an early single run showed a ~13 ms
  outlier on q1/hash under load that disappeared once quiesced — hence medians).
  Raw plans in `bench/raw/`. Runner: `bench/run.sh`.
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

## Query latency (1,000,000 rows; warm median, ms)

| query | seqscan | default | hash | jsonb_ops | jsonb_path_ops | rows |
|---|---:|---:|---:|---:|---:|---:|
| q1 selective `@>` (`shard=>S777`) | 183.8 | **0.495** | 0.767 | 0.83 | 0.79 | 1000 |
| q2 medium `@>` (`env=>prod`) | 204.3 | 220.2 | **194.9** | 256.7 | 244.8 | 333756 |
| q3 multi `@>` (`env=>prod,tier=>gold`) | 194.7 | 159.5 | **128.2** | 178.9 | 155.2 | 110641 |
| **q4 negative `@>` (`env=>gold`)** | 184.4 | 203.3 | **0.080** | 237.7 | 0.055 | 0 |
| q5 key-exists `?` (`shard`) | 168.9 | **0.48** | 0.56 | 0.60 | n/a | 1000 |

Bold = fastest in row. `jsonb_path_ops` does not support `?` (n/a). The default
opclass edges out the hash opclass on the two sub-millisecond point lookups
(q1, q5) — both all-rare-token queries where the default's two tiny posting
lists intersect to the exact answer cheaply. The hash opclass wins q2/q3 and,
decisively, q4.

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

~2500× faster (203.3 → 0.080 ms median; the single plans above show
198.5 → 0.024 ms), 39115 → 4 buffers, 333575 → 0 rechecked. `jsonb_path_ops`
behaves identically (0.055 ms median). This is the mechanism working exactly as
designed: indexing the pair as a unit turns a table-scan-sized recheck into an
index miss.

### Where it does not win

* q1 selective `@>` and q5 key-exists `?`: the default opclass is marginally
  faster (q1 0.50 vs 0.77 ms; q5 0.48 vs 0.56 ms). Both are sub-millisecond
  point lookups; `?` goes through partial match on the key hash, and q1's query
  tokens are individually rare so the default's two-posting-list intersection is
  already tight. Not a practically meaningful gap, but the hash opclass does not
  win here.
* q2/q3 low-selectivity `@>`: the hash opclass is 12–20% faster, but all
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
`EXPLAIN`/size artifacts in `bench/raw/`.
