# FINDINGS — hstore GIN opclasses on real and synthetic data

Factual summary of the pg_proc benchmark and the three-opclass comparison.
Environment: PostgreSQL 20devel (commit `16a4b3ef8ee`, `-O2`, cassert off),
single core, `shared_buffers=512MB`. Latency figures are repeated-subquery
per-query times (the same scalar subquery placed N times in one `SELECT` under
`\timing`, per-query = total/N); on a single core, read ratios matter more than
absolute ms.

## 1. Historical pg_proc benchmark

Original 2014 example (obartunov.livejournal.com/178495.html):

```sql
SELECT hstore(t) AS h INTO proc FROM pg_proc t;
CREATE INDEX ON proc USING gin (h);            -- default gin_hstore_ops
SELECT count(*) FROM proc WHERE h @> 'proargtypes=>"2275"';
```

The 2014 claim was that `gin_hstore_hash_ops` is faster and smaller than the
default opclass, and (later update) that it "has no problem with long keys
(values)".

### PG20devel reproduction

`pg_proc` now has 3512 rows (2744 in 2014). `hstore(pg_proc)` includes
high-entropy text columns — `prosrc`, `prosqlbody` (up to ~19 KB), etc.

**Full `hstore(pg_proc)`:**

| opclass | result |
|---|---|
| `gin_hstore_ops` (default) | **build fails**: `index row size 3688 exceeds maximum 2712` |
| `gin_hstore_pair_ops` | **build fails**: `index row size 3704 exceeds maximum 2712` |
| `gin_hstore_hash_ops` | **builds, 840 kB** |

On the full catalog, hash is the *only* buildable opclass. A build failure is a
first-class result: the exact-byte opclasses cannot index this data at all.

### Buildable subset

Dropping the long high-entropy keys (`prosrc`, `prosqlbody`, `proconfig`,
`protrftypes`, `probin`, `proargnames`, `proargdefaults`) leaves values ≤ 108
bytes, so all three build. Same 3512 rows, query `@> 'proargtypes=>"2275"'`
(86 matches):

| opclass | index size | index scan → recheck | per-query |
|---|---:|---|---:|
| default | 792 kB | 199 candidates → **113 removed by recheck** → 86 | 0.764 ms |
| **hash** | **600 kB** | 86, 0 removed | **0.122 ms** |
| pair | 1024 kB | 86, recheck-free | 0.118 ms |

Here the 2014 claims hold: **hash is ~24% smaller and ~6× faster than the
default** opclass. The default opclass indexes key and value separately, so
`proargtypes=>"2275"` intersects the `proargtypes` key list with the `2275`
value list into 199 candidates and rechecks 113 false pairs away; hash indexes
the pair as one 8-byte entry (86 exact). pair matches hash on speed (both avoid
recheck) but is the largest index.

## 2. Three opclass profiles

**default `gin_hstore_ops`** — legacy/generic baseline. Key and value indexed
separately; exact-ish entries but can fail on long/high-entropy values; `@>`
containment is lossy and rechecks.

**`gin_hstore_hash_ops`** — compact lossy hashed representation. 64-bit
`hash(key,value)` per pair; mandatory recheck; **robust to arbitrary long /
high-entropy values** because every entry is fixed 8 bytes. Best candidate for
an "always buildable" hstore GIN index; best negative-lookup and single-pair
selectivity profile.

**`gin_hstore_pair_ops`** — exact tagged `K(key)` + `P(key,value)` entries;
recheck-free for `@>`, `?`, `?|`, `?&`; best semantic model and strongest on
multi-pair containment and key-existence. Limited by the GIN entry-size limit
for exact values; largest index and slowest build.

## 3. Long / high-entropy value limit

Exact-byte opclasses (default, pair) fail to build when a single key or value
does not compress below the GIN per-entry limit (~2712 bytes on an 8 KB page).
Hash always builds (8-byte entries).

The limit is on *incompressible* size, not raw length:

| value | default | pair | hash |
|---|---|---|---|
| `repeat('L',5000)` (compressible) | builds | builds | builds |
| 3200 bytes of `md5` output (high-entropy) | `3216 > 2712` fail | `3224 > 2712` fail | builds |
| `hstore(pg_proc)` (`prosrc`/`prosqlbody`) | `3688 > 2712` fail | `3704 > 2712` fail | builds |

Highly compressible long values slip under the limit because the stored index
tuple is compressed; real high-entropy text (source code, hashes) does not.

## 4. Correctness

Where they build, all three opclasses agree with the sequential-scan oracle:
`count(*) WHERE h @> 'proargtypes=>"2275"'` = **86** for default, hash, and pair
(and seqscan). Broader oracles on synthetic data: pair containment 20/20, pair
key-existence 20/20, correctness matrix 13/13, hash 30/30 — index result sets
identical to seqscan.

The 2014 post shows the default plan returning 76 rows and the hash plan 0 rows
for the same query. That is a discrepancy between two runs (likely a
copy/paste artifact), not a semantic difference: on this reproduction all
opclasses return the same count.

## 5. Recommendation

The story is not "hash vs pair, choose one". hstore has two useful non-default
GIN representations, and both are worth keeping:

- **hash** — bounded-size lossy representation; robust and compact; suitable
  for arbitrary hstore values, including long/high-entropy ones. On real
  catalog data it is often the only buildable opclass.
- **pair** — exact tagged representation; recheck-free and semantically clean;
  suitable when values are bounded enough to fit as exact GIN entries; strongest
  for multi-pair `@>` and key-existence.

pair is universal by operator semantics, not by data domain. The pg_proc result
makes hash historically and technically central again: it is the representation
that keeps working when exact entries cannot.
