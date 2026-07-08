# hstore_hash_ops/Makefile

MODULE_big = hstore_hash_ops
OBJS = hstore_compat.o hstore_ops.o

EXTENSION = hstore_hash_ops
DATA = hstore_hash_ops--1.0.sql

REGRESS = hstore_hash_ops

ifdef USE_PGXS
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
else
subdir = contrib/hstore_hash_ops
top_builddir = ../..
include $(top_builddir)/src/Makefile.global
include $(top_srcdir)/contrib/contrib-global.mk
endif
