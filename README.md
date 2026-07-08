# hstore GIN hash and pair operator classes

Revived non-default GIN operator classes for PostgreSQL `hstore`, ported to
current PostgreSQL master (20devel):

* **`gin_hstore_hash_ops`** — bounded-size lossy pair hashes; mandatory
  recheck; robust when exact GIN entries are too large.
* **`gin_hstore_pair_ops`** — exact tagged key and key/value entries;
  recheck-free for hstore containment and key-existence; bounded by GIN's
  per-entry size limit.

Lineage: `akorotkov/hstore_ops` (2014) → `postgrespro/hstore_ops` (last
touched for v17) → this focused revival for master. The original extension
also shipped `gin_hstore_bytea_ops`; that opclass is **deliberately out of
scope** for this milestone (see *Limitations*).

The intent is not to make `hstore` a document store again. The scope is narrower
and more PostgreSQL-like: keep `hstore` as a simple flat sparse-attribute
representation, and expose different physical GIN representations for different
workloads.

## Operator-class profiles

| opclass | representation | profile |
|---|---|---|
| `gin_hstore_ops` (default) | keys and values indexed separately | legacy/generic baseline; `@>` is lossy and rechecked; exact entries can fail on long/high-entropy values |
| `gin_hstore_hash_ops` | 64-bit `hash(key,value)` per pair | bounded-size lossy representation; mandatory recheck; robust to arbitrary long/high-entropy values |
| `gin_hstore_pair_ops` | exact `K(key)` and `P(key,value)` bytea entries | exact and recheck-free for `@>`, `?`, `?|`, `?&`; larger index; can fail on oversized exact entries |

## What the opclasses do

The default `gin_hstore_ops` indexes each key and each value of an hstore as
two **independent** text entries. It therefore has no information about which
value belongs to which key, so `@>` containment searches can produce false
candidates that must be rechecked against the heap.

`gin_hstore_hash_ops` indexes each **key/value pair as a single bounded GIN
key**: a 64-bit integer whose high 32 bits are `hash(key)` and low 32 bits are
`hash(value)` (0 for a SQL `NULL` value). Because a pair is one entry, `@>`
becomes a direct per-pair match rather than an intersection of separate key and
value posting lists. The representation is lossy because hashes can collide, so
heap recheck remains mandatory.

`gin_hstore_pair_ops` indexes exact tagged bytea entries in a disjoint tag
space:

```
K(key)          = [0x01] [key bytes]
P(key,value)    = [0x02] [vnull] [klen:int32] [key bytes] [value bytes]
```

`K` entries answer key-existence operators (`?`, `?|`, `?&`); `P` entries answer
exact containment (`@>`). The explicit key length makes the pair encoding
injective (`ab=>c` and `a=>bc` are different entries), so this opclass can set
`recheck=false` where the exact entries fit in GIN.

Both non-default opclasses support the hstore GIN strategies `@>` (7), `?` (9),
`?|` (10), and `?&` (11).

## Recheck and exactness invariants

For `gin_hstore_hash_ops`, two distinct pairs (or keys) can collide to the same
64-bit hash, so the index is **lossy by construction**.
`gin_consistent_hstore_hash` sets `*recheck = true` for **every** strategy
unconditionally; the executor re-applies the exact operator against the heap
tuple. This is what keeps SQL semantics exact:

* No false positive can escape — a hash collision only ever *adds* a candidate,
  which recheck then discards.
* No false negative can occur — `tag_hash` is deterministic within a server
  build, so a genuinely matching pair always produces the same index key as the
  query pair.

This was verified empirically (see below), not just argued.

For `gin_hstore_pair_ops`, entries are exact rather than hashed. `K(key)` proves
key existence and `P(key,value)` proves exact containment, so the pair opclass
sets `*recheck = false` for all supported strategies. This is a stronger
semantic profile, but it inherits GIN's per-entry size limit for exact key/value
bytes. Oversized entries fail hard rather than being truncated; truncation would
make an exact, no-recheck opclass incorrect.

## Determinism, collation, persistence

* `gin_hstore_hash_ops` hashes `tag_hash` over the **raw bytes** of key/value,
  so it is **collation-independent** by construction (unlike the default
  opclass, whose support-1 compare is collation-aware). This is also why the
  historical `bytea` variant existed.
* The hash is deterministic within one server build. It is **not** guaranteed
  stable across major versions or CPU architectures — the same accepted
  boundary as core hash indexes. It does not affect correctness: logical
  dump/restore re-emits `CREATE INDEX` (the index is rebuilt, never shipped as
  bytes), and recheck would catch any hypothetical mismatch anyway.
* `gin_hstore_pair_ops` stores an exact `klen:int32` in native-endian form as
  part of the physical GIN entry. This only affects platform-local physical
  index ordering. Logical dump/restore rebuilds indexes from hstore values; it
  does not transport physical GIN entries across architectures.

## Edge cases covered by the correctness suites

empty hstore; SQL `NULL` value vs empty-string value vs the literal string
`"NULL"`; key-present vs key-with-null-value; duplicate input keys (hstore
keeps the first, normalized before extract); multi-key containment; the classic
*"existing key + existing value but never as a pair"* negative lookup;
non-ASCII keys/values (Cyrillic, accented Latin, CJK); long keys/values;
`CREATE INDEX` / `REINDEX` / `VACUUM` sanity; `pg_dump`/restore sanity for
`gin_hstore_pair_ops`; prepared-query containment.

The hash suite (`correctness.sql`) proves, for every strategy and every edge
case, that the set of rows returned via the index (seqscan disabled) is
**identical** to the set returned by a seqscan oracle (index disabled): 30/30
probes match.

The pair suites prove exact, recheck-free semantics across containment,
key-existence, and matrix cases: `pair_correctness.sql` 20/20,
`pair_keyexist_oracle.sql` 20/20, and `pair_matrix.sql` 13/13.

## Build / install

```
make USE_PGXS=1
make USE_PGXS=1 install
make USE_PGXS=1 installcheck        # regression test
psql -c "CREATE EXTENSION hstore;"          -- prerequisite
psql -c "CREATE EXTENSION hstore_hash_ops;"
CREATE INDEX ON t USING gin (h gin_hstore_hash_ops);
CREATE INDEX ON t USING gin (h gin_hstore_pair_ops);
```

Requires the `hstore` extension. The extension bundles `hstore.h` and
`hstore_compat.c` copied verbatim from master's `contrib/hstore` (they provide
the on-disk format definition and `hstoreUpgrade`, which are not installed into
the server include dir).

## When each opclass helps / when it does not

`gin_hstore_hash_ops` helps a lot for `@>` where a common key and a common value
never occur together as a pair (negative lookup). The default opclass may fetch
and recheck a large fraction of the table; hash answers from a bounded pair-hash
entry and then verifies candidates by heap recheck. In the 1M-row synthetic
benchmark this is ~2000–4000× faster (≈190 ms → ≈0.05–0.10 ms per query,
repeated-subquery method). Hash is also ~2× faster to build.

Hash also helps structurally: hash entries are fixed-size, so the opclass is
**robust to long/high-entropy values**. On data where an exact value is too large
to fit as a GIN entry (for example full `hstore(pg_proc)` with `prosrc` /
`prosqlbody`), the default opclass and `gin_hstore_pair_ops` fail to build while
hash still builds. In that regime hash can also be smaller. See `FINDINGS.md`.

`gin_hstore_pair_ops` helps when exact, recheck-free semantics matter and
key/value entries fit in GIN. It is strongest on multi-pair containment and
key-existence. In the 1M-row benchmark it wins multi-pair `@>` (2 pairs, 110k
matches: 69 ms vs 102 ms hash vs 123 ms default) and key-existence `?` / `?&`
(`? shard`: 0.19 ms vs 0.75 ms hash vs 1.08 ms default; `?& env,shard`: 0.90
ms vs 36.8 ms hash vs 1.06 ms default). See `PAIR_OPS.md`.

Does **not** hold universally: hash is **not** always smaller than the default
opclass on short-value flat data under modern GIN posting-list compression
(measured ~6% larger at 1M rows). Pair is exact but larger (+40% vs default in
the same benchmark) and slower to build. Medium-selectivity `@>` can be
heap-bound for all opclasses.

`jsonb_path_ops` (in core) uses a related pair-hashing idea for `jsonb` and
matches the hash opclass's `@>` profile on comparable flat data. The distinct
value here is bringing explicit physical choices to the `hstore` type without
migrating flat sparse attributes to `jsonb`.

## Limitations / out of scope for this milestone

* `gin_hstore_bytea_ops` from the original extension is not included.
* No change to `hstore` semantics, the default `gin_hstore_ops`, dump/restore,
  or ABI.
