# hstore_hash_ops

A revived hash-based GIN operator class for the `hstore` type,
**`gin_hstore_hash_ops`**, ported to current PostgreSQL master (20devel).

Lineage: `akorotkov/hstore_ops` (2014) → `postgrespro/hstore_ops` (last
touched for v17) → this focused revival for master. The original extension
also shipped `gin_hstore_bytea_ops`; that opclass is **deliberately out of
scope** for this milestone (see *Limitations*).

## What it does

The default `gin_hstore_ops` indexes each key and each value of an hstore as
two **independent** text entries. It therefore has no information about which
value belongs to which key, so every `@>` containment search is lossy and must
recheck against the heap.

`gin_hstore_hash_ops` instead indexes each **key/value pair as a single GIN
key**: a 64-bit integer whose high 32 bits are `hash(key)` and low 32 bits are
`hash(value)` (0 for a SQL `NULL` value). Because a pair is one entry, `@>`
becomes a direct per-pair match rather than an intersection of separate key and
value posting lists.

Supported operators (strategies): `@>` (7), `?` (9), `?|` (10), `?&` (11).
`?`/`?|`/`?&` search on `hash(key)` via GIN partial match (all pairs sharing a
key hash).

## Recheck is mandatory (correctness invariant)

Two distinct pairs (or keys) can collide to the same 64-bit hash, so the index
is **lossy by construction**. `gin_consistent_hstore_hash` sets `*recheck =
true` for **every** strategy unconditionally; the executor re-applies the exact
operator against the heap tuple. This is what keeps SQL semantics exact:

* No false positive can escape — a hash collision only ever *adds* a candidate,
  which recheck then discards.
* No false negative can occur — `tag_hash` is deterministic within a server
  build, so a genuinely matching pair always produces the same index key as the
  query pair.

This was verified empirically (see below), not just argued.

## Determinism, collation, persistence

* Hashing is `tag_hash` over the **raw bytes** of key/value, so the opclass is
  **collation-independent** by construction (unlike the default opclass, whose
  support-1 compare is collation-aware). This is also why the historical
  `bytea` variant existed.
* The hash is deterministic within one server build. It is **not** guaranteed
  stable across major versions or CPU architectures — the same accepted
  boundary as core hash indexes. It does not affect correctness: logical
  dump/restore re-emits `CREATE INDEX` (the index is rebuilt, never shipped as
  bytes), and recheck would catch any hypothetical mismatch anyway.

## Edge cases covered by the correctness suite

empty hstore; SQL `NULL` value vs empty-string value vs the literal string
`"NULL"`; key-present vs key-with-null-value; duplicate input keys (hstore
keeps the first, normalized before extract); multi-key containment; the classic
*"existing key + existing value but never as a pair"* negative lookup;
non-ASCII keys/values (Cyrillic, accented Latin, CJK); long (10 kB) keys/values;
`CREATE INDEX` / `REINDEX` / `VACUUM` sanity.

The suite (`correctness.sql`) proves, for every strategy and every edge case,
that the set of rows returned via the index (seqscan disabled) is **identical**
to the set returned by a seqscan oracle (index disabled): 30/30 probes match.

## Build / install

```
make USE_PGXS=1
make USE_PGXS=1 install
make USE_PGXS=1 installcheck        # regression test
psql -c "CREATE EXTENSION hstore;"          -- prerequisite
psql -c "CREATE EXTENSION hstore_hash_ops;"
CREATE INDEX ON t USING gin (h gin_hstore_hash_ops);
```

Requires the `hstore` extension. The extension bundles `hstore.h` and
`hstore_compat.c` copied verbatim from master's `contrib/hstore` (they provide
the on-disk format definition and `hstoreUpgrade`, which are not installed into
the server include dir).

## When it helps / when it does not (see BENCHMARK.md for data)

Helps a lot: `@>` where a common key and a common value never occur together as
a pair (negative lookup) — the default opclass fetches and rechecks a large
fraction of the table; this opclass answers from the index with no heap access
(~2000–4000× on 1M rows: ≈190 ms → ≈0.05–0.10 ms per query, repeated-subquery method). Also faster on multi-pair `@>`, and ~2× faster to build.

Does **not** help: it is **not** smaller than the default opclass on flat data
under modern GIN posting-list compression (measured ~6% larger at 1M rows);
`?`/`?|`/`?&` key-existence is marginally slower (partial match, both sub-ms);
selective single-pair `@>` is a tie (0.32 vs 0.33 ms per query).

`jsonb_path_ops` (in core) uses the same pair-hashing idea for `jsonb` and
matches this opclass's `@>` performance. The distinct value here is bringing
that behavior to the `hstore` type without migrating to `jsonb`.

## Limitations / out of scope for this milestone

* `gin_hstore_bytea_ops` from the original extension is not included.
* No change to `hstore` semantics, the default `gin_hstore_ops`, dump/restore,
  or ABI.
