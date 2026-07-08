/*-------------------------------------------------------------------------
 *
 * hstore_ops.c
 *     Definitions of gin_hstore_hash_ops operator class for hstore.
 *
 * Copyright (c) 2014, PostgreSQL Global Development Group
 * Author: Alexander Korotkov <aekorotkov@gmail.com>
 *
 * Revived and ported to PostgreSQL master (20devel) by @r2d2, 2026.
 *
 * GIN keys in this opclass are 64-bit integers where the high 32 bits are the
 * hash of the hstore key and the low 32 bits are the hash of the hstore value
 * (0 for a NULL value).  A key/value pair thus becomes a single GIN key, which
 * makes "@>" containment a direct per-pair match instead of the two
 * independent key/value entries used by the default gin_hstore_ops.  Because
 * two distinct pairs can hash to the same 64-bit key, recheck is ALWAYS
 * required for every supported strategy; the index is lossy by construction.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/gin.h"
#include "access/stratnum.h"
#include "catalog/pg_type.h"
#include "common/hashfn.h"		/* tag_hash() */
#include "utils/array.h"

#include "hstore.h"

PG_MODULE_MAGIC;

/*
 * GIN comparison function: compare keys as _unsigned_ 64-bit integers, so that
 * keys sharing the same high 32 bits (same key hash) sort together.  This
 * ordering is what makes the partial-match comparator below able to bound its
 * scan.
 */
PG_FUNCTION_INFO_V1(gin_compare_hstore_hash);
Datum
gin_compare_hstore_hash(PG_FUNCTION_ARGS)
{
	uint64		arg1 = (uint64) PG_GETARG_INT64(0);
	uint64		arg2 = (uint64) PG_GETARG_INT64(1);
	int32		result;

	if (arg1 < arg2)
		result = -1;
	else if (arg1 == arg2)
		result = 0;
	else
		result = 1;

	PG_RETURN_INT32(result);
}

/*
 * GIN partial-match comparator: select all index keys with the same hash of
 * the hstore key (used for ?, ?|, ?& where only the key is known).  Returns
 * <0 keep scanning, 0 match, >0 stop (past the range).  Both operands are
 * treated as unsigned to match gin_compare_hstore_hash's ordering.
 */
PG_FUNCTION_INFO_V1(gin_compare_partial_hstore_hash);
Datum
gin_compare_partial_hstore_hash(PG_FUNCTION_ARGS)
{
	uint64		partial_key = (uint64) PG_GETARG_INT64(0);
	uint64		key = (uint64) PG_GETARG_INT64(1);
	int32		result;

	if ((key & UINT64CONST(0xFFFFFFFF00000000)) > partial_key)
		result = 1;
	else if ((key & UINT64CONST(0xFFFFFFFF00000000)) == partial_key)
		result = 0;
	else
		result = -1;

	PG_RETURN_INT32(result);
}

/*
 * Hash of a key/value pair: high 32 bits = hash(key), low 32 bits = hash(value)
 * (0 when the value is SQL NULL).  tag_hash() hashes the raw bytes, so the
 * result is collation-independent and deterministic within one server build.
 */
static uint64
get_entry_hash(HEntry *hsent, char *ptr, int i)
{
	uint64		result = 0;

	result |= (uint64) tag_hash(HSTORE_KEY(hsent, ptr, i),
							   HSTORE_KEYLEN(hsent, i)) << 32;

	if (!HSTORE_VALISNULL(hsent, i))
		result |= (uint64) tag_hash(HSTORE_VAL(hsent, ptr, i),
									HSTORE_VALLEN(hsent, i));

	return result;
}

/*
 * Hash of an hstore key alone, laid out like a pair hash with an empty (0)
 * value slot.  Used as the partial-match query key for ?, ?|, ?&.
 */
static uint64
get_key_hash(text *key)
{
	uint64		result = 0;

	result |= (uint64) tag_hash(VARDATA_ANY(key),
								VARSIZE_ANY_EXHDR(key)) << 32;

	return result;
}

/*
 * extractValue: split an hstore into one composite pair-hash per key/value.
 */
PG_FUNCTION_INFO_V1(gin_extract_hstore_hash);
Datum
gin_extract_hstore_hash(PG_FUNCTION_ARGS)
{
	HStore	   *hs = PG_GETARG_HSTORE_P(0);
	int32	   *nentries = (int32 *) PG_GETARG_POINTER(1);
	Datum	   *entries = NULL;
	HEntry	   *hsent = ARRPTR(hs);
	char	   *ptr = STRPTR(hs);
	int			count = HS_COUNT(hs);
	int			i;

	*nentries = count;
	if (count)
		entries = (Datum *) palloc(sizeof(Datum) * count);

	for (i = 0; i < count; ++i)
		entries[i] = Int64GetDatum(get_entry_hash(hsent, ptr, i));

	PG_RETURN_POINTER(entries);
}

/*
 * extractQuery: produce the search keys for the query datum, per strategy.
 */
PG_FUNCTION_INFO_V1(gin_extract_hstore_query_hash);
Datum
gin_extract_hstore_query_hash(PG_FUNCTION_ARGS)
{
	int32	   *nentries = (int32 *) PG_GETARG_POINTER(1);
	StrategyNumber strategy = PG_GETARG_UINT16(2);
	bool	  **pmatch = (bool **) PG_GETARG_POINTER(3);
	int32	   *searchMode = (int32 *) PG_GETARG_POINTER(6);
	Datum	   *entries;

	if (strategy == HStoreContainsStrategyNumber)
	{
		/* Query is an hstore, so just apply gin_extract_hstore_hash... */
		entries = (Datum *)
			DatumGetPointer(DirectFunctionCall2(gin_extract_hstore_hash,
												PG_GETARG_DATUM(0),
												PointerGetDatum(nentries)));
		/* ... except that "contains {}" requires a full index scan */
		if (entries == NULL)
			*searchMode = GIN_SEARCH_MODE_ALL;
	}
	else if (strategy == HStoreExistsStrategyNumber)
	{
		text	   *query = PG_GETARG_TEXT_PP(0);

		*nentries = 1;
		entries = (Datum *) palloc(sizeof(Datum));
		*pmatch = (bool *) palloc(sizeof(bool));
		entries[0] = Int64GetDatum(get_key_hash(query));
		(*pmatch)[0] = true;
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
		*pmatch = (bool *) palloc(sizeof(bool) * key_count);

		for (i = 0, j = 0; i < key_count; ++i)
		{
			/* Nulls in the array are ignored, cf hstoreArrayToPairs */
			if (key_nulls[i])
				continue;
			(*pmatch)[j] = true;
			entries[j++] = Int64GetDatum(get_key_hash(DatumGetTextPP(key_datums[i])));
		}

		*nentries = j;
		/* ExistsAll with no keys should match everything */
		if (j == 0 && strategy == HStoreExistsAllStrategyNumber)
			*searchMode = GIN_SEARCH_MODE_ALL;
	}
	else
	{
		elog(ERROR, "unrecognized strategy number: %d", strategy);
		entries = NULL;			/* keep compiler quiet */
	}

	PG_RETURN_POINTER(entries);
}

/*
 * consistent: every strategy is lossy here because two distinct pairs (or
 * keys) can share a 64-bit hash, so recheck is unconditionally required.  We
 * can still fail fast when a required entry is absent.
 */
PG_FUNCTION_INFO_V1(gin_consistent_hstore_hash);
Datum
gin_consistent_hstore_hash(PG_FUNCTION_ARGS)
{
	bool	   *check = (bool *) PG_GETARG_POINTER(0);
	StrategyNumber strategy = PG_GETARG_UINT16(1);

	/* HStore    *query = PG_GETARG_HSTORE_P(2); */
	int32		nkeys = PG_GETARG_INT32(3);

	/* Pointer  *extra_data = (Pointer *) PG_GETARG_POINTER(4); */
	bool	   *recheck = (bool *) PG_GETARG_POINTER(5);
	bool		res = true;
	int32		i;

	/* All cases are inexact because of hashing */
	*recheck = true;

	if (strategy == HStoreContainsStrategyNumber)
	{
		/*
		 * All queried pairs must be present.  Their key/value correspondence
		 * and any hash collisions are resolved by the mandatory heap recheck.
		 */
		for (i = 0; i < nkeys; i++)
		{
			if (!check[i])
			{
				res = false;
				break;
			}
		}
	}
	else if (strategy == HStoreExistsStrategyNumber)
	{
		res = true;
	}
	else if (strategy == HStoreExistsAnyStrategyNumber)
	{
		res = true;
	}
	else if (strategy == HStoreExistsAllStrategyNumber)
	{
		for (i = 0; i < nkeys; i++)
		{
			if (!check[i])
			{
				res = false;
				break;
			}
		}
	}
	else
		elog(ERROR, "unrecognized strategy number: %d", strategy);

	PG_RETURN_BOOL(res);
}
