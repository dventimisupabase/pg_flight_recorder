-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- pg_flight_recorder: pgfr_record module install script (v2)
--
-- v2 is a clean-slate rewrite: see pgfr-v2-context-pack.md for the design.
-- Kernel statement: pgfr_record appends debounced, dictionary-encoded
-- jsonb samples of PostgreSQL's own stats views and system views into
-- time-partitioned tables, and drops old partitions.
--
-- Orchestrates load order. Each sql/ file is independently reviewable.
-- Run as a superuser in the target database with pg_cron installed.
-- Uses psql `\ir` (include-relative); paths resolve against this file's
-- directory, so the script works from any working directory.
--
-- Files:
--   01_schema.sql            extension check, schema
--   02_manifest.sql          manifest, column_classes, payload_schemas,
--                            src_catalog_identity projection
--   03_seed_pg15.sql         the PG15 manifest census (pgfr-v2-context-pack.md §3.2)
--   04_ledger.sql            capture ledger: ledger_runs, ledger_captures
--   05_partition_infra.sql   maintain_partitions() and its helpers

\ir sql/01_schema.sql
\ir sql/02_manifest.sql
\ir sql/03_seed_pg15.sql
\ir sql/04_ledger.sql
\ir sql/05_partition_infra.sql
