/*
 * hstore_pair_ops.c
 *
 * An exact, non-lossy GIN operator class for hstore: gin_hstore_pair_ops.
 *
 * Unlike gin_hstore_hash_ops (compact 64-bit pair hashes, always lossy, always
 * rechecked) this opclass indexes each key/value pair as an EXACT tagged bytea
 * entry, plus a key-only entry, so containment and key-existence are decided
 * from the index alone -- no heap recheck.  Precedent: contrib array GIN
 * (ginarrayconsistent sets *recheck = false for @>) and jsonb_ops entry tagging
 * (make_text_key prefixes a flag byte).  The correctness argument for dropping
 * recheck is:
 *
 *   - Each pair maps to an injective byte string (a length prefix on the key
 *     removes the "ab|c" vs "a|bc" ambiguity), so P(k,v) present in the index
 *     iff the row's hstore contains exactly the pair (k,v).
 *   - A SQL-NULL value gets a distinct tag byte, so P(k,NULL) can never collide
 *     with P(k,"") or P(k,"NULL").  hstore NULL-value semantics are exact
 *     (key present, value is null), unlike SQL array element NULLs.
 *   - "h @> {}" (empty rhs) matches every row and is handled with
 *     GIN_SEARCH_MODE_ALL, still recheck-free.
 *
 * Therefore @> is exactly "all queried pair-entries present", and ?/?|/?& are
 * exactly "the queried key-entries present"; both are non-lossy.
 */
#include "postgres.h"

#include "access/gin.h"
#include "access/stratnum.h"
#include "catalog/pg_type.h"
#include "utils/array.h"

#include "hstore.h"

PG_FUNCTION_INFO_V1(gin_extract_hstore_pair);
PG_FUNCTION_INFO_V1(gin_extract_hstore_query_pair);
PG_FUNCTION_INFO_V1(gin_consistent_hstore_pair);
PG_FUNCTION_INFO_V1(gin_compare_hstore_pair);

/* entry tag bytes (byte 0 of every entry) */
#define HTAG_KEY	0x01		/* key-only entry:  [KEY][key bytes]        */
#define HTAG_PAIR	0x02		/* pair entry: [PAIR][vnull][klen][key][val] */

/* value-null discriminator (byte 1 of a pair entry) */
#define HVAL_STR	0x00
#define HVAL_NULL	0x01

/*
 * Build a key-only entry: 1 tag byte + key bytes.  Injective over keys because
 * the tag is fixed and hstore keys are compared in full.
 */
static bytea *
make_key_entry(const char *key, int klen)
{
	bytea	   *e = (bytea *) palloc(VARHDRSZ + 1 + klen);
	char	   *p = VARDATA(e);

	SET_VARSIZE(e, VARHDRSZ + 1 + klen);
	p[0] = HTAG_KEY;
	memcpy(p + 1, key, klen);
	return e;
}

/*
 * Build a pair entry: [PAIR][vnull][klen:int32][key bytes][value bytes].
 *
 * The explicit 4-byte key length makes the key/value boundary unambiguous, so
 * distinct (k,v) pairs always produce distinct byte strings.  For a NULL value
 * the discriminator is HVAL_NULL and no value bytes are appended.
 */
static bytea *
make_pair_entry(const char *key, int klen,
				const char *val, int vlen, bool vnull)
{
	int			vbytes = vnull ? 0 : vlen;
	int			len = VARHDRSZ + 1 + 1 + sizeof(int32) + klen + vbytes;
	bytea	   *e = (bytea *) palloc(len);
	char	   *p = VARDATA(e);
	int32		k32 = (int32) klen;

	SET_VARSIZE(e, len);
	p[0] = HTAG_PAIR;
	p[1] = vnull ? HVAL_NULL : HVAL_STR;
	memcpy(p + 2, &k32, sizeof(int32));
	memcpy(p + 2 + sizeof(int32), key, klen);
	if (!vnull)
		memcpy(p + 2 + sizeof(int32) + klen, val, vlen);
	return e;
}

/*
 * compare: plain unsigned byte-wise ordering of the entry bytea values, with
 * the shorter string sorting first on a common prefix.  Any total order that
 * is consistent between build and search is acceptable for GIN.
 */
Datum
gin_compare_hstore_pair(PG_FUNCTION_ARGS)
{
	bytea	   *a = PG_GETARG_BYTEA_PP(0);
	bytea	   *b = PG_GETARG_BYTEA_PP(1);
	int			la = VARSIZE_ANY_EXHDR(a);
	int			lb = VARSIZE_ANY_EXHDR(b);
	int			m = Min(la, lb);
	int			c = 0;

	if (m > 0)
		c = memcmp(VARDATA_ANY(a), VARDATA_ANY(b), m);
	if (c == 0)
		c = (la < lb) ? -1 : (la > lb) ? 1 : 0;

	PG_FREE_IF_COPY(a, 0);
	PG_FREE_IF_COPY(b, 1);
	PG_RETURN_INT32(c);
}

/*
 * extractValue: emit a key entry and a pair entry for every key/value pair.
 * n pairs -> 2n entries.
 */
Datum
gin_extract_hstore_pair(PG_FUNCTION_ARGS)
{
	HStore	   *hs = PG_GETARG_HSTORE_P(0);
	int32	   *nentries = (int32 *) PG_GETARG_POINTER(1);
	HEntry	   *hsent = ARRPTR(hs);
	char	   *ptr = STRPTR(hs);
	int			count = HS_COUNT(hs);
	Datum	   *entries = NULL;
	int			i;

	*nentries = 2 * count;
	if (count)
		entries = (Datum *) palloc(sizeof(Datum) * 2 * count);

	for (i = 0; i < count; ++i)
	{
		char	   *key = HSTORE_KEY(hsent, ptr, i);
		int			klen = HSTORE_KEYLEN(hsent, i);
		bool		vnull = HSTORE_VALISNULL(hsent, i);
		char	   *val = vnull ? NULL : HSTORE_VAL(hsent, ptr, i);
		int			vlen = vnull ? 0 : HSTORE_VALLEN(hsent, i);

		entries[2 * i] =
			PointerGetDatum(make_key_entry(key, klen));
		entries[2 * i + 1] =
			PointerGetDatum(make_pair_entry(key, klen, val, vlen, vnull));
	}

	PG_RETURN_POINTER(entries);
}

/*
 * extractQuery: per strategy, produce the exact entries the query needs.
 *   @>            -> one pair entry per queried pair (empty rhs => full scan)
 *   ? / ?| / ?&   -> one key entry per queried key
 */
Datum
gin_extract_hstore_query_pair(PG_FUNCTION_ARGS)
{
	int32	   *nentries = (int32 *) PG_GETARG_POINTER(1);
	StrategyNumber strategy = PG_GETARG_UINT16(2);
	int32	   *searchMode = (int32 *) PG_GETARG_POINTER(6);
	Datum	   *entries = NULL;

	if (strategy == HStoreContainsStrategyNumber)
	{
		HStore	   *hs = PG_GETARG_HSTORE_P(0);
		HEntry	   *hsent = ARRPTR(hs);
		char	   *ptr = STRPTR(hs);
		int			count = HS_COUNT(hs);
		int			i;

		*nentries = count;
		if (count)
			entries = (Datum *) palloc(sizeof(Datum) * count);

		for (i = 0; i < count; ++i)
		{
			char	   *key = HSTORE_KEY(hsent, ptr, i);
			int			klen = HSTORE_KEYLEN(hsent, i);
			bool		vnull = HSTORE_VALISNULL(hsent, i);
			char	   *val = vnull ? NULL : HSTORE_VAL(hsent, ptr, i);
			int			vlen = vnull ? 0 : HSTORE_VALLEN(hsent, i);

			entries[i] =
				PointerGetDatum(make_pair_entry(key, klen, val, vlen, vnull));
		}

		/* "contains {}" matches everything */
		if (count == 0)
			*searchMode = GIN_SEARCH_MODE_ALL;
	}
	else if (strategy == HStoreExistsStrategyNumber)
	{
		text	   *key = PG_GETARG_TEXT_PP(0);

		*nentries = 1;
		entries = (Datum *) palloc(sizeof(Datum));
		entries[0] = PointerGetDatum(make_key_entry(VARDATA_ANY(key),
													VARSIZE_ANY_EXHDR(key)));
	}
	else if (strategy == HStoreExistsAnyStrategyNumber ||
			 strategy == HStoreExistsAllStrategyNumber)
	{
		ArrayType  *query = PG_GETARG_ARRAYTYPE_P(0);
		Datum	   *key_datums;
		bool	   *key_nulls;
		int			key_count;
		int			i,
					j;

		deconstruct_array_builtin(query, TEXTOID,
								  &key_datums, &key_nulls, &key_count);

		entries = (Datum *) palloc(sizeof(Datum) * key_count);

		for (i = 0, j = 0; i < key_count; ++i)
		{
			text	   *k;

			/* Nulls in the array are ignored, cf hstoreArrayToPairs */
			if (key_nulls[i])
				continue;
			k = DatumGetTextPP(key_datums[i]);
			entries[j++] = PointerGetDatum(make_key_entry(VARDATA_ANY(k),
														  VARSIZE_ANY_EXHDR(k)));
		}

		*nentries = j;
		/* ExistsAll over an all-null / empty array matches everything */
		if (j == 0 && strategy == HStoreExistsAllStrategyNumber)
			*searchMode = GIN_SEARCH_MODE_ALL;
	}
	else
	{
		elog(ERROR, "unrecognized strategy number: %d", strategy);
		entries = NULL;
	}

	PG_RETURN_POINTER(entries);
}

/*
 * consistent: because entries are exact, every strategy is non-lossy.
 */
Datum
gin_consistent_hstore_pair(PG_FUNCTION_ARGS)
{
	bool	   *check = (bool *) PG_GETARG_POINTER(0);
	StrategyNumber strategy = PG_GETARG_UINT16(1);

	/* HStore    *query = PG_GETARG_HSTORE_P(2); */
	int32		nkeys = PG_GETARG_INT32(3);
	bool	   *recheck = (bool *) PG_GETARG_POINTER(5);
	bool		res = true;
	int32		i;

	/* exact representation: no recheck for any supported strategy */
	*recheck = false;

	if (strategy == HStoreContainsStrategyNumber ||
		strategy == HStoreExistsAllStrategyNumber)
	{
		/* all queried entries must be present */
		for (i = 0; i < nkeys; i++)
		{
			if (!check[i])
			{
				res = false;
				break;
			}
		}
	}
	else if (strategy == HStoreExistsStrategyNumber ||
			 strategy == HStoreExistsAnyStrategyNumber)
	{
		/* at least one queried entry must be present */
		res = false;
		for (i = 0; i < nkeys; i++)
		{
			if (check[i])
			{
				res = true;
				break;
			}
		}
	}
	else
		elog(ERROR, "unrecognized strategy number: %d", strategy);

	PG_RETURN_BOOL(res);
}
