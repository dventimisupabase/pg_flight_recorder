-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- PG15 seed census: the manifest data itself. See pgfr-v2-context-pack.md
-- §3.2 for the full rationale behind every row. Idempotent: re-running
-- install.sql must not fail or duplicate rows on an existing install.
--
-- Size classes below are the closest fit among the five defined in §3.1
-- (singleton | per_db | per_relation | per_backend | per_slot); the
-- taxonomy is documentation/cost-model only (§2), so approximations here
-- are noted inline rather than treated as a design question.

-- ---------------------------------------------------------------------------
-- Group A -- cumulative counters, singleton / per-db. fast tier, 30d
-- retention, debounce = false (cheap, always changing, every sample wanted).
-- ---------------------------------------------------------------------------
INSERT INTO pgfr_record.manifest
    (source_view, cadence_tier, natural_key, retention, size_class, notes)
VALUES
    ('pg_catalog.pg_stat_archiver', 'fast', '{}', interval '30 days', 'singleton',
     'reset: stats_reset'),
    ('pg_catalog.pg_stat_bgwriter', 'fast', '{}', interval '30 days', 'singleton',
     'reset: stats_reset. PG17 removes checkpoint columns (moved to pg_stat_checkpointer); agnostic capture absorbs'),
    ('pg_catalog.pg_stat_wal', 'fast', '{}', interval '30 days', 'singleton',
     'reset: stats_reset'),
    ('pg_catalog.pg_stat_slru', 'fast', ARRAY['name'], interval '30 days', 'singleton',
     'per-cache row set, bounded/small cardinality -- closest fit is singleton; reset: stats_reset'),
    ('pg_catalog.pg_stat_database', 'fast', ARRAY['datid'], interval '30 days', 'per_db',
     'includes datid=0 shared-objects row; reset: stats_reset'),
    ('pg_catalog.pg_stat_database_conflicts', 'fast', ARRAY['datid'], interval '30 days', 'per_db',
     'nonzero only on standbys')
ON CONFLICT (source_view) DO NOTHING;

-- Version-gated Group A additions (§3.2 "Version rows beyond PG15"),
-- seeded now, activated by min_major once the generator runs on that major.
INSERT INTO pgfr_record.manifest
    (source_view, min_major, cadence_tier, natural_key, retention, size_class, notes)
VALUES
    ('pg_catalog.pg_stat_io', 16, 'fast', ARRAY['backend_type','object','context'], interval '30 days', 'singleton',
     'the single most valuable addition in the series; bounded/small cardinality -- closest fit is singleton'),
    ('pg_catalog.pg_stat_checkpointer', 17, 'fast', '{}', interval '30 days', 'singleton',
     'receives the columns split out of pg_stat_bgwriter')
ON CONFLICT (source_view) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Group B -- cumulative counters, per-relation: the cardinality frontier.
-- medium tier (statio: slow), debounce = true, anchor_every = 1 day,
-- retention 30d. size_class is per_relation for all rows below as the
-- closest fit; pg_stat_statements(_info) actually scale with distinct
-- queries, not relations, but no better-fitting class exists in §3.1.
-- ---------------------------------------------------------------------------
INSERT INTO pgfr_record.manifest
    (source_view, cadence_tier, natural_key, debounce, compare_ignore, anchor_every, retention, size_class, requires, notes)
VALUES
    ('pg_catalog.pg_stat_all_tables', 'medium', ARRAY['relid'], true,
     ARRAY['n_live_tup','n_dead_tup','n_mod_since_analyze','n_ins_since_vacuum'],
     interval '1 day', interval '30 days', 'per_relation', NULL,
     'ignore-list prevents estimator churn from defeating debounce; ignored columns are still stored'),
    ('pg_catalog.pg_stat_all_indexes', 'medium', ARRAY['indexrelid'], true,
     '{}', interval '1 day', interval '30 days', 'per_relation', NULL, NULL),
    ('pg_catalog.pg_statio_all_tables', 'slow', ARRAY['relid'], true,
     '{}', interval '1 day', interval '30 days', 'per_relation', NULL, NULL),
    ('pg_catalog.pg_statio_all_indexes', 'slow', ARRAY['indexrelid'], true,
     '{}', interval '1 day', interval '30 days', 'per_relation', NULL, NULL),
    ('pg_catalog.pg_statio_all_sequences', 'slow', ARRAY['relid'], true,
     '{}', interval '1 day', interval '30 days', 'per_relation', NULL, NULL),
    ('pg_catalog.pg_stat_user_functions', 'medium', ARRAY['funcid'], true,
     '{}', interval '1 day', interval '30 days', 'per_relation', 'GUC track_functions <> none', NULL),
    ('pg_catalog.pg_stat_statements', 'medium', ARRAY['userid','dbid','queryid','toplevel'], true,
     '{}', interval '1 day', interval '30 days', 'per_relation', 'pg_stat_statements extension',
     'dict: query (analyze-side dictionary over queryid -> text). Reset via pg_stat_statements_info.stats_reset. Eviction-aware: a vanished queryid is eviction, not reset.'),
    ('pg_catalog.pg_stat_statements_info', 'fast', '{}', false,
     '{}', NULL, interval '30 days', 'per_relation', 'pg_stat_statements extension',
     'singleton companion to pg_stat_statements; carries the reset signal (stats_reset) that distinguishes a real reset from per-query eviction')
ON CONFLICT (source_view) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Group C -- gauges. fast tier, 2h retention (this is the v1 ring,
-- expressed as a retention number), debounce = false.
-- ---------------------------------------------------------------------------
INSERT INTO pgfr_record.manifest
    (source_view, cadence_tier, natural_key, keyless, retention, size_class, notes)
VALUES
    ('pg_catalog.pg_stat_activity', 'fast', ARRAY['pid','backend_start'], false, interval '2 hours', 'per_backend',
     'backend_start disambiguates pid reuse; dict: query (analyze-side)'),
    ('pg_catalog.pg_locks', 'fast', '{}', true, interval '2 hours', 'per_backend',
     'no stable identity; join to activity via pid at equal captured_at (exact -- single-stamp rule, §5)'),
    ('pg_catalog.pg_stat_replication', 'fast', ARRAY['pid'], false, interval '2 hours', 'per_slot',
     'odometers: sent_lsn, write_lsn, flush_lsn, replay_lsn'),
    ('pg_catalog.pg_stat_wal_receiver', 'fast', '{}', false, interval '2 hours', 'singleton',
     'standby-side; odometers on received LSNs'),
    ('pg_catalog.pg_stat_subscription', 'fast', ARRAY['subid'], false, interval '2 hours', 'per_slot', NULL),
    ('pg_catalog.pg_replication_slots', 'fast', ARRAY['slot_name'], false, interval '2 hours', 'per_slot',
     'odometers: restart_lsn, confirmed_flush_lsn; failure to advance is the alarm (analyze-side)'),
    ('pg_catalog.pg_prepared_xacts', 'fast', ARRAY['gid'], false, interval '2 hours', 'singleton',
     'usually empty; an aging row is itself an anomaly'),
    ('pg_catalog.pg_stat_progress_vacuum', 'fast', ARRAY['pid'], false, interval '2 hours', 'per_backend',
     'default-on: empty view costs one SELECT'),
    ('pg_catalog.pg_stat_progress_cluster', 'fast', ARRAY['pid'], false, interval '2 hours', 'per_backend', 'default-on'),
    ('pg_catalog.pg_stat_progress_create_index', 'fast', ARRAY['pid'], false, interval '2 hours', 'per_backend', 'default-on'),
    ('pg_catalog.pg_stat_progress_basebackup', 'fast', ARRAY['pid'], false, interval '2 hours', 'per_backend', 'default-on'),
    ('pg_catalog.pg_stat_progress_analyze', 'fast', ARRAY['pid'], false, interval '2 hours', 'per_backend', 'default-on'),
    ('pg_catalog.pg_stat_progress_copy', 'fast', ARRAY['pid'], false, interval '2 hours', 'per_backend', 'default-on')
ON CONFLICT (source_view) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Group D -- state history. on_change tier, debounce = true,
-- anchor_every = 1 month (Group D uses monthly partitions per the §4.2
-- width rule), retention 365d.
-- ---------------------------------------------------------------------------
INSERT INTO pgfr_record.manifest
    (source_view, cadence_tier, natural_key, debounce, anchor_every, retention, size_class, requires, notes)
VALUES
    ('pg_catalog.pg_settings', 'on_change', ARRAY['name'], true, interval '1 month', interval '365 days', 'singleton', NULL,
     'flagship: GUC change detection falls out of debounce for free'),
    ('pg_catalog.pg_roles', 'on_change', ARRAY['oid'], true, interval '1 month', interval '365 days', 'singleton', NULL,
     'strip rolpassword from payload defensively (masked anyway)'),
    ('pg_catalog.pg_hba_file_rules', 'on_change', ARRAY['line_number'], true, interval '1 month', interval '365 days', 'singleton',
     'privileged read', 'degrade via ledger when unreadable'),
    ('pg_catalog.pg_file_settings', 'on_change', ARRAY['sourcefile','sourceline'], true, interval '1 month', interval '365 days', 'singleton',
     'privileged read', 'detects applied-vs-file divergence'),
    ('pg_catalog.pg_extension', 'on_change', ARRAY['oid'], true, interval '1 month', interval '365 days', 'singleton', NULL,
     'catalog table, not a view; extension installs/upgrades'),
    ('pgfr_record.src_catalog_identity', 'on_change', ARRAY['oid'], true, interval '1 month', interval '365 days', 'singleton', NULL,
     'the dimension table: resolves any relid/indexrelid in Group B as of any captured_at, surviving OID reuse across DROP/CREATE')
ON CONFLICT (source_view) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Group E -- enabled = false rows, present with reasons so "why doesn't
-- pgfr capture X" is queryable. Disabled rows never get an archive table
-- or capture-plan entry (§4.3.1), so the placeholder cadence/retention/
-- size_class values below are inert.
-- ---------------------------------------------------------------------------
INSERT INTO pgfr_record.manifest
    (source_view, cadence_tier, retention, size_class, enabled, notes)
VALUES
    ('pg_catalog.pg_cursors', 'on_change', interval '1 day', 'singleton', false,
     'session-local: observes pg_cron''s session, not the workload'),
    ('pg_catalog.pg_prepared_statements', 'on_change', interval '1 day', 'singleton', false,
     'session-local'),
    ('pg_catalog.pg_backend_memory_contexts', 'on_change', interval '1 day', 'singleton', false,
     'session-local (PG15 form); candidate for troubleshooting profile in later PG majors'),
    ('pg_catalog.pg_timezone_names', 'on_change', interval '1 day', 'singleton', false,
     'static and enormous'),
    ('pg_catalog.pg_stats', 'on_change', interval '1 day', 'singleton', false,
     'per-column planner statistics: huge, ANALYZE-cadenced, a different product'),
    ('pg_catalog.pg_shmem_allocations', 'on_change', interval '1 day', 'singleton', false,
     'low routine value; candidate troubleshooting-profile extra')
ON CONFLICT (source_view) DO NOTHING;
