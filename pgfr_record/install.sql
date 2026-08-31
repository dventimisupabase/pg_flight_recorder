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
--   06_generators.sql        generate_archives(), generate_presentation_views()
--   07_capture_plan.sql      capture_plan table + generate_capture_plan()
--   08_collector.sql         run_tier(): the collector core (tier jobs are
--                            scheduled by enable(), 14_enable.sql, not here)
--   09_column_classes.sql    generate_column_classes(): the counter/odometer/
--                            gauge/label/key legend (§3.1, §4.5)
--   10_definitional.sql      state_as_of(), resolve_relation(), resolve_index()
--   11_deltas.sql            deltas(): reset-aware consecutive-sample differences
--   12_comments.sql          generate_comments(): self-documenting \d+ (§4.5)
--   13_profiles.sql          profiles, profile_tiers, apply_profile()
--   14_enable.sql            enable() / disable()
--   15_health_check.sql      health_check()
--   16_rollups.sql           generate_rollups(): long-horizon compressed
--                            history for Groups B/C (milestone 8)

\ir sql/01_schema.sql
\ir sql/02_manifest.sql
\ir sql/03_seed_pg15.sql
\ir sql/04_ledger.sql
\ir sql/05_partition_infra.sql
\ir sql/06_generators.sql
\ir sql/07_capture_plan.sql
\ir sql/08_collector.sql
\ir sql/09_column_classes.sql
\ir sql/10_definitional.sql
\ir sql/11_deltas.sql
\ir sql/12_comments.sql
\ir sql/13_profiles.sql
\ir sql/14_enable.sql
\ir sql/15_health_check.sql
\ir sql/16_rollups.sql

-- Create every enabled target's archive table + initial partitions,
-- regenerate the typed presentation views, reclassify every column,
-- create every rollup table, rebuild the capture plan, and regenerate
-- every comment -- all against this server's live catalog. Safe to
-- re-run (§7): this is also the post-major-upgrade procedure.
--
-- generate_column_classes() must run before generate_capture_plan() and
-- generate_rollups(): both of the latter need to know which columns are
-- counters/odometers (generate_rollups(), to choose a rollup shape) or
-- just want a stable, already-classified target (generate_capture_plan()
-- has no such dependency today, but ordering it after costs nothing and
-- keeps one dependency direction instead of two).
SELECT pgfr_record.generate_archives();
SELECT pgfr_record.generate_presentation_views();
SELECT pgfr_record.generate_column_classes();
SELECT pgfr_record.generate_rollups();
SELECT pgfr_record.generate_capture_plan();
SELECT pgfr_record.generate_comments();

-- Schedule all pg_cron jobs via the single source of truth (enable()).
-- pg_cron's cron.schedule() replaces same-named jobs, so this is
-- idempotent across re-runs (§7's upgrade procedure).
SELECT pgfr_record.enable();
