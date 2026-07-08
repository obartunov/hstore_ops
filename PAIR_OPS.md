# gin_hstore_pair_ops — an exact, recheck-free GIN opclass for hstore

`gin_hstore_pair_ops` provides an exact, recheck-free GIN representation for
both hstore containment (`@>`) and key-existence (`?`, `?|`, `?&`) operators by
indexing separate key entries and key/value entries. It is **universal by
operator semantics, not by data domain**: it covers every hstore GIN operator
exactly, but because it indexes exact key/value bytes it inherits GIN
entry-size limits for long or high-entropy values, and it trades a larger index
and slower build for that exactness.

It sits alongside two other opclasses for the same type:

| opclass | representation | profile |
|---|---|---|
| `gin_hstore_ops` (default) | key and value indexed separately | legacy/generic baseline; `@>` is lossy (rechecks); exact-byte entries can fail on long/high-entropy values |
| `gin_hstore_hash_ops` | 64-bit `hash(key,value)` per pair | compact, lossy, always rechecked; best negative/selective profile; **robust to arbitrary long/high-entropy values — often the only buildable opclass** |
| **`gin_hstore_pair_ops`** | exact `K(key)` + `P(key,value)` entries | exact, recheck-free; best multi-pair containment and key-existence; **bounded** by the GIN entry-size limit for exact values |

## 1. Semantics

### Indexed entries

For every key/value pair of an hstore, `extractValue` emits **two** exact
tagged `bytea` entries in a **disjoint tag space** (byte 0 is the tag):

```
K(key)          = [0x01] [key bytes]
P(key,value)    = [0x02] [vnull] [klen:int32] [key bytes] [value bytes]
```

`K` answers key-existence (value is irrelevant); `P` answers exact containment.
Because the tags differ in byte 0, a `K` entry and a `P` entry can never
compare equal. An hstore with *n* pairs produces *2n* entries.

### Why the encoding is injective

The pair entry carries an explicit 4-byte key length before the key, so the
key/value boundary is unambiguous: `('ab','c')` and `('a','bc')` encode to
different byte strings even though their concatenations are equal. This is what
makes "`P(k,v)` present ⟺ the row contains exactly the pair (k,v)" hold, and it
is verified at runtime (`@> 'ab=>c'` and `@> 'a=>bc'` return disjoint rows).

The `klen:int32` field is stored in native-endian form. This is acceptable for
a physical GIN index representation: index files are platform-local artifacts,
and dump/restore rebuilds the index from logical hstore values rather than
copying the physical byte ordering across architectures.

### hstore NULL vs empty string vs the string "NULL"

The pair entry's discriminator byte distinguishes a SQL-NULL value
(`HVAL_NULL`, no value bytes) from a string value (`HVAL_STR`, followed by the
bytes). So the three pairs

```
a => NULL      -> [0x02][NULL][klen]["a"]
a => ""        -> [0x02][STR ][klen]["a"]           (zero value bytes)
a => "NULL"    -> [0x02][STR ][klen]["a"]["NULL"]
```

are three distinct entries. `K(a)` is identical for all of them, because
`make_key_entry` takes no value argument — key-existence is independent of the
value, including NULL.

### Why recheck can be false

Every entry is exact, so `consistent` and `triConsistent` need no heap recheck:

* `@>` / `?&` — all queried entries present ⟹ match (the row contains exactly
  those pairs / keys);
* `?` / `?|` — at least one queried entry present ⟹ match.

`consistent` sets `*recheck = false` for every strategy. This mirrors the core
array GIN opclass, whose `@>` is likewise non-lossy (`ginarrayconsistent` sets
`*recheck = false`). Empty right-hand side `@> ''` matches every row and is
handled with `GIN_SEARCH_MODE_ALL`, still recheck-free. A SQL `NULL::hstore`
column value is not indexed and never matches.

## 2. Correctness evidence

All checks compare the index result set against a sequential-scan oracle
(`enable_seqscan` toggled); they must be identical.

* **Pair containment** (`pair_correctness.sql`) — 20/20, including the
  injectivity landmines (`ab=>c` vs `a=>bc`), NULL vs `""` vs `"NULL"` values,
  duplicate-key normalization, non-ASCII, and the "existing key + existing
  value but never as the same pair" negatives.
* **Key-existence universality** (`pair_keyexist_oracle.sql`) — 20/20: `? 'a'`
  returns every value form (`a=>1, a=>2, a=>NULL, a=>""`); `?`/`@>` are
  distinguished (`? 'a' AND NOT @> 'a=>1'`); `?|`/`?&`; empty arrays taken from
  seqscan semantics first (`?| {}` → none, `?& {}` → all non-NULL); duplicate
  query keys; NULL inside the query array; empty, non-ASCII, 300-char, and
  TOASTed keys.
* **Correctness matrix** (`pair_matrix.sql`) — 13/13: `NULL::hstore` not
  returned by `@> ''`; empty hstore value; empty rhs; TOASTed hstore (400
  pairs); long value (2500 bytes); correctness preserved across `REINDEX`,
  `VACUUM`, and `pg_dump`/restore; parameterised `PREPARE ... @> $1`.
* **No recheck at runtime** — `EXPLAIN (ANALYZE, BUFFERS)` for `@>`, `?`, `?|`,
  `?&` shows the GIN index used and **no `Rows Removed by Index Recheck`**
  line; the bitmap index scan returns exactly the matching rows.

## 3. Cost profile

PostgreSQL 20devel (commit `16a4b3ef8ee`, `-O2`, cassert off), single core,
`shared_buffers=512MB`. Dataset: 1,000,000 rows, 3–9 pairs/row over structured
keys (`env`, `tier`, `region`) plus filler pairs, identical to the hash-opclass
benchmark. Latency = repeated-subquery per-query time (the amplification
method); single core, so read ratios matter more than absolute ms.

| metric | default | hash | **pair** |
|---|---:|---:|---:|
| index size | 29.2 MB | 30.8 MB | 41 MB |
| build time | 6.6 s | 3.1 s | 10.5 s |
| selective `@>` (`shard=>S777`, 1k) | 0.58 | **0.24** | 0.46 |
| negative `@>` (`env=>gold`, 0) | 184 | **0.048** | 0.052 |
| medium `@>` (`env=>prod`, 333k) | 175 | **163** | 198 |
| multi-pair `@>` (2 pairs, 110k) | 123 | 102 | **69** |
| key-existence `?` (`shard`, 1k) | 1.08 | 0.75 | **0.19** |
| key-existence `?&` (`env`,`shard`) | 1.06 | 36.8 | **0.90** |

Latency is per-query in ms. Bold = fastest in row.

Where **pair** wins: multi-pair containment, and key-existence — especially
`?&`, where the hash opclass degrades because its `?` path is a partial match
over `hash(key)` and must scan every value under a frequent key (36.8 ms),
while exact `K` entries drive off the rarest key (0.90 ms).

Where **pair** loses: index size (+40% vs default) and build time (slowest);
single-pair selective `@>` (a hair behind hash); medium single-pair `@>` is
heap-bound for everyone and slightly worse for pair because its index is
larger. On the negative lookup it ties the hash opclass (both answer from the
index with no heap access).

## Limitations

Like the default `gin_hstore_ops`, this opclass indexes raw key/value bytes, so
a single key or value that does not compress below GIN's per-entry limit
(~2712 bytes on an 8 KB page) makes index build fail:

```
ERROR:  index row size 3224 exceeds maximum 2712 for index ...
```

This is a real limit on catalog-like data. `SELECT hstore(t) FROM pg_proc t`
contains high-entropy values (`prosrc`, `prosqlbody`, up to ~19 KB) and
`CREATE INDEX ... gin_hstore_pair_ops` fails on it — as does the default
opclass. Highly compressible long values (e.g. `repeat('x',5000)`) index fine
because the stored tuple is compressed under the limit; high-entropy long
values do not. The **hash** opclass is immune: it hashes every pair to 8 bytes
and indexes arbitrary hstore regardless of key/value length. So for hstore
columns that may hold long high-entropy values, `gin_hstore_hash_ops` is the
only usable GIN opclass of the three.

## 4. Conclusion

`gin_hstore_pair_ops` is **not a universal winner** on cost, and not universal
across the data domain. It is an **exact, bounded opclass**: one representation
that answers hstore containment and key-existence exactly and recheck-free, as
long as the exact key/value entries fit the GIN entry-size limit.

The story is not "hash vs pair, choose one". hstore has two useful non-default
GIN representations, and both are worth keeping:

* **hash** — bounded-size lossy hashed entries; mandatory recheck; **robust to
  arbitrary long/high-entropy values** (often the only buildable opclass, e.g.
  on `hstore(pg_proc)`); best negative-lookup and single-pair selectivity.
* **pair** — exact tagged entries; recheck-free and semantically clean;
  strongest on multi-pair `@>` and key-existence; bounded by the entry-size
  limit for exact values; larger index and slower build.

The default opclass remains the smallest generic baseline (and shares pair's
long-value limit). See `FINDINGS.md` for the pg_proc benchmark behind this.

The strong claim is not "a faster hstore index." The strong claim is:

> `gin_hstore_pair_ops` provides an exact, recheck-free GIN representation for
> both hstore containment and key-existence operators by indexing separate key
> and key/value entries — universal by operator semantics, bounded by data
> domain.
