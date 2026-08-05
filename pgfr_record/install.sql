-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- pg_flight_recorder: pgfr_record module install script
--
-- Orchestrates load order. Each sql/ file is independently reviewable.
-- Run as a superuser in the target database with pg_cron installed.
-- Uses psql `\ir` (include-relative); paths resolve against this file's
-- directory, so the script works from any working directory.
--
-- Files:
--   01_schema.sql            extension check, schema, search_path
--   02_tables.sql            heap tables: snapshots, aggregates, archives, legacy-ring DROPs
--   02b_discontinuities.sql  censoring-event ledger + _record_discontinuity, _detect_restart (Issue #101)
--   03_functions_util.sql    helpers: _pg_version, epoch, _get_config, circuit breakers
--   04a_functions_sample.sql wait/lock/activity ring samplers (old UPDATE pattern)
--   04b_functions_snapshot.sql snapshot(), _collect_* collectors
--   05_functions_ops.sql     cleanup(), enable/disable, set_mode, profiles
--   06_partition_infra.sql   _ensure_partition, _partition_inventory, truncate/drop GC
--   07_sparse_collectors.sql sparse PGSS/table/index collectors (v2 INSERT pattern)
--   08_ring_buffer_v2.sql    ring buffer v2 tables, sample_ring, rotate_ring, flush, archive
--   09_phase3_snapshots_v2.sql snapshots_v2 partitioned tables + dual-write trigger
--   10_consumption_sampler.sql consumption ledger: block/WAL/tuple flow + reset-guarded deltas
--   11_ring_rollups.sql      durable wait/lock/activity rollups fed from rotate_ring()
--   12_consumption_weekly_flows.sql weekly-grain ratio reconstruction for the 90-day trend window
--   13_snapshots_cutover.sql snapshots becomes a compat view over snapshots_v2 (Issue #73)

\ir sql/01_schema.sql
\ir sql/02_tables.sql
\ir sql/02b_discontinuities.sql
\ir sql/03_functions_util.sql
\ir sql/04a_functions_sample.sql
\ir sql/04b_functions_snapshot.sql
\ir sql/05_functions_ops.sql
\ir sql/06_partition_infra.sql
\ir sql/07_sparse_collectors.sql
\ir sql/08_ring_buffer_v2.sql
\ir sql/09_phase3_snapshots_v2.sql
\ir sql/10_consumption_sampler.sql
\ir sql/11_ring_rollups.sql
\ir sql/12_consumption_weekly_flows.sql
\ir sql/13_snapshots_cutover.sql

-- Post-install: migrate deprecated config key aliases to canonical names.
-- Idempotent; safe on fresh install (keys won't exist yet) and upgrades.
select old_key, new_key, action from pgfr_record.migrate_config_keys();

-- One-shot snapshot to seed the durable tables and the v2 partitions.
-- Lives here (rather than at the end of 06_partition_infra.sql) so every
-- collector defined in 07/08/09 is in place before snapshot() runs.
select pgfr_record.snapshot();

-- Schedule all pg_cron jobs via the single source of truth (enable()).
-- pg_cron's cron.schedule() replaces same-named jobs, so this is idempotent
-- across re-runs.
select pgfr_record.enable();
