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
-- Group A -- cumulative counters, singleton / per-db. fast tier, 365d
-- retention, debounce = false (cheap, always changing, every sample
-- wanted). Retention is 365d directly, not a rollup: Group A is bounded
-- and small (singleton/per-db cardinality) even at a year's depth, so
-- there is no compression problem here to solve -- unlike Group B, the
-- cost-model frontier, milestone 8 gives Group A the same long horizon as
-- Group D for free rather than building rollup machinery it doesn't need.
-- ---------------------------------------------------------------------------
INSERT INTO pgfr_record.manifest
    (source_view, cadence_tier, natural_key, retention, size_class, notes)
VALUES
    ('pg_catalog.pg_stat_archiver', 'fast', '{}', interval '365 days', 'singleton',
     'reset: stats_reset'),
    ('pg_catalog.pg_stat_bgwriter', 'fast', '{}', interval '365 days', 'singleton',
     'reset: stats_reset. PG17 removes checkpoint columns (moved to pg_stat_checkpointer); agnostic capture absorbs'),
    ('pg_catalog.pg_stat_wal', 'fast', '{}', interval '365 days', 'singleton',
     'reset: stats_reset'),
    ('pg_catalog.pg_stat_slru', 'fast', ARRAY['name'], interval '365 days', 'singleton',
     'per-cache row set, bounded/small cardinality -- closest fit is singleton; reset: stats_reset'),
    ('pg_catalog.pg_stat_database', 'fast', ARRAY['datid'], interval '365 days', 'per_db',
     'includes datid=0 shared-objects row; reset: stats_reset'),
    ('pg_catalog.pg_stat_database_conflicts', 'fast', ARRAY['datid'], interval '365 days', 'per_db',
     'nonzero only on standbys')
ON CONFLICT (source_view) DO NOTHING;

-- Version-gated Group A additions (§3.2 "Version rows beyond PG15"),
-- seeded now, activated by min_major once the generator runs on that major.
INSERT INTO pgfr_record.manifest
    (source_view, min_major, cadence_tier, natural_key, retention, size_class, notes)
VALUES
    ('pg_catalog.pg_stat_io', 16, 'fast', ARRAY['backend_type','object','context'], interval '365 days', 'singleton',
     'the single most valuable addition in the series; bounded/small cardinality -- closest fit is singleton'),
    ('pg_catalog.pg_stat_checkpointer', 17, 'fast', '{}', interval '365 days', 'singleton',
     'receives the columns split out of pg_stat_bgwriter')
ON CONFLICT (source_view) DO NOTHING;

-- Group A addition, seeded after the initial v2 rewrite (additive, per
-- schema evolution policy): per-slot and per-subscription cumulative
-- counters, bounded/small cardinality like pg_stat_slru, each with its own
-- stats_reset.
INSERT INTO pgfr_record.manifest
    (source_view, cadence_tier, natural_key, retention, size_class, notes)
VALUES
    ('pg_catalog.pg_stat_replication_slots', 'fast', ARRAY['slot_name'], interval '365 days', 'per_slot',
     'logical-decoding spill/stream byte and txn counters, distinct from pg_replication_slots'' LSN/config columns (Group C); reset: stats_reset'),
    ('pg_catalog.pg_stat_subscription_stats', 'fast', ARRAY['subid'], interval '365 days', 'per_slot',
     'apply/sync error counts, distinct from pg_stat_subscription''s worker pid/lag columns (Group C); reset: stats_reset')
ON CONFLICT (source_view) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Group B -- cumulative counters, per-relation: the cardinality frontier.
-- medium tier (statio: slow), debounce = true, anchor_every = 1 day,
-- retention 30d. size_class is per_relation for all rows below as the
-- closest fit; pg_stat_statements(_info) actually scale with distinct
-- queries, not relations, but no better-fitting class exists in §3.1.
--
-- rollup_retention/rollup_granularity (milestone 8): 365d at 1-day
-- buckets. Group B is the cost-model frontier (§10.2), so raw retention
-- stays 30d; the rollup is mechanical (first/last value per counter/
-- odometer column per bucket, derived from column_classes, not hand-
-- seeded) and gives a year of correlatable history at a fraction of raw
-- storage. See generate_rollups().
-- ---------------------------------------------------------------------------
INSERT INTO pgfr_record.manifest
    (source_view, cadence_tier, natural_key, debounce, compare_ignore, anchor_every, retention, size_class, requires, notes, rollup_retention, rollup_granularity)
VALUES
    ('pg_catalog.pg_stat_all_tables', 'medium', ARRAY['relid'], true,
     ARRAY['n_live_tup','n_dead_tup','n_mod_since_analyze','n_ins_since_vacuum'],
     interval '1 day', interval '30 days', 'per_relation', NULL,
     'ignore-list prevents estimator churn from defeating debounce; ignored columns are still stored',
     interval '365 days', interval '1 day'),
    ('pg_catalog.pg_stat_all_indexes', 'medium', ARRAY['indexrelid'], true,
     '{}', interval '1 day', interval '30 days', 'per_relation', NULL, NULL,
     interval '365 days', interval '1 day'),
    ('pg_catalog.pg_statio_all_tables', 'slow', ARRAY['relid'], true,
     '{}', interval '1 day', interval '30 days', 'per_relation', NULL, NULL,
     interval '365 days', interval '1 day'),
    ('pg_catalog.pg_statio_all_indexes', 'slow', ARRAY['indexrelid'], true,
     '{}', interval '1 day', interval '30 days', 'per_relation', NULL, NULL,
     interval '365 days', interval '1 day'),
    ('pg_catalog.pg_statio_all_sequences', 'slow', ARRAY['relid'], true,
     '{}', interval '1 day', interval '30 days', 'per_relation', NULL, NULL,
     interval '365 days', interval '1 day'),
    ('pg_catalog.pg_stat_user_functions', 'medium', ARRAY['funcid'], true,
     '{}', interval '1 day', interval '30 days', 'per_relation', 'GUC track_functions <> none', NULL,
     interval '365 days', interval '1 day'),
    -- Unqualified on purpose: pg_stat_statements is an extension-provided
    -- view, not a pg_catalog builtin. CREATE EXTENSION installs it into
    -- whichever schema was current at the time (public on stock
    -- PostgreSQL; typically `extensions` on Supabase) -- there is no
    -- single correct hardcoded schema to qualify it with, so resolution
    -- relies on search_path via ::regclass, same as any other client of
    -- an extension-provided object.
    ('pg_stat_statements', 'medium', ARRAY['userid','dbid','queryid','toplevel'], true,
     '{}', interval '1 day', interval '30 days', 'per_relation', 'pg_stat_statements extension',
     'dict: query (analyze-side dictionary over queryid -> text). Reset via pg_stat_statements_info.stats_reset. Eviction-aware: a vanished queryid is eviction, not reset.',
     interval '365 days', interval '1 day'),
    ('pg_stat_statements_info', 'fast', '{}', false,
     '{}', NULL, interval '30 days', 'per_relation', 'pg_stat_statements extension',
     'singleton companion to pg_stat_statements; carries the reset signal (stats_reset) that distinguishes a real reset from per-query eviction',
     interval '365 days', interval '1 day')
ON CONFLICT (source_view) DO NOTHING;

-- Group B addition, seeded after the initial v2 rewrite (additive, per
-- schema evolution policy): last_value against min_value/max_value is
-- sequence-exhaustion risk, the same category of problem as XID/MultiXID
-- wraparound distance, just missed the first time around. Keyed by name,
-- not oid: this view exposes no oid column, so unlike every other
-- relid/indexrelid-keyed Group B target, identity here does not survive a
-- DROP/CREATE or rename via src_catalog_identity.
INSERT INTO pgfr_record.manifest
    (source_view, cadence_tier, natural_key, debounce, compare_ignore, anchor_every, retention, size_class, requires, notes, rollup_retention, rollup_granularity)
VALUES
    ('pg_catalog.pg_sequences', 'medium', ARRAY['schemaname','sequencename'], true,
     '{}', interval '1 day', interval '30 days', 'per_relation', NULL,
     'last_value is NULL without USAGE/SELECT on the sequence; start_value/increment_by/cache_size are fixed config, not cumulative',
     interval '365 days', interval '1 day')
ON CONFLICT (source_view) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Group C -- gauges. fast tier, 2h retention (this is the v1 ring,
-- expressed as a retention number), debounce = false.
--
-- rollup_retention/rollup_granularity (milestone 8): 365d at 1-hour
-- buckets -- comfortably inside the 2h raw retention, so a bucket always
-- closes while its source rows still exist. Group C's rollup is usually
-- not mechanical (a gauge has no single correct "delta"); it aggregates
-- the hand-seeded statistics in pgfr_record.rollup_specs, below. A target
-- needs either a rollup_specs row or, like pg_stat_wal_receiver here,
-- column_classes odometer columns of its own (LSNs) to roll up -- a
-- rollup_retention with neither would be dead weight, per
-- generate_rollups()'s shape-selection rule (rollup_specs wins when both
-- are present, so a target's explicit hand-picked stat is never
-- shadowed by an incidental odometer column, e.g. pg_stat_replication's
-- own LSN columns).
-- ---------------------------------------------------------------------------
INSERT INTO pgfr_record.manifest
    (source_view, cadence_tier, natural_key, keyless, retention, size_class, notes, rollup_retention, rollup_granularity)
VALUES
    ('pg_catalog.pg_stat_activity', 'fast', ARRAY['pid','backend_start'], false, interval '2 hours', 'per_backend',
     'backend_start disambiguates pid reuse; dict: query (analyze-side)',
     interval '365 days', interval '1 hour'),
    ('pg_catalog.pg_locks', 'fast', '{}', true, interval '2 hours', 'per_backend',
     'no stable identity; join to activity via pid at equal captured_at (exact -- single-stamp rule, §5)',
     interval '365 days', interval '1 hour'),
    ('pg_catalog.pg_stat_replication', 'fast', ARRAY['pid'], false, interval '2 hours', 'per_slot',
     'odometers: sent_lsn, write_lsn, flush_lsn, replay_lsn',
     interval '365 days', interval '1 hour'),
    ('pg_catalog.pg_stat_wal_receiver', 'fast', '{}', false, interval '2 hours', 'singleton',
     'standby-side; odometers on received LSNs. No rollup_specs row: its own odometer columns are enough for generate_rollups() to pick the mechanical endpoint shape, same as Group B',
     interval '365 days', interval '1 hour'),
    ('pg_catalog.pg_stat_subscription', 'fast', ARRAY['subid'], false, interval '2 hours', 'per_slot', NULL,
     interval '365 days', interval '1 hour'),
    ('pg_catalog.pg_replication_slots', 'fast', ARRAY['slot_name'], false, interval '2 hours', 'per_slot',
     'odometers: restart_lsn, confirmed_flush_lsn; failure to advance is the alarm (analyze-side)',
     interval '365 days', interval '1 hour'),
    ('pg_catalog.pg_prepared_xacts', 'fast', ARRAY['gid'], false, interval '2 hours', 'singleton',
     'usually empty; an aging row is itself an anomaly',
     interval '365 days', interval '1 hour'),
    ('pg_catalog.pg_stat_progress_vacuum', 'fast', ARRAY['pid'], false, interval '2 hours', 'per_backend',
     'default-on: empty view costs one SELECT',
     interval '365 days', interval '1 hour'),
    ('pg_catalog.pg_stat_progress_cluster', 'fast', ARRAY['pid'], false, interval '2 hours', 'per_backend', 'default-on',
     interval '365 days', interval '1 hour'),
    ('pg_catalog.pg_stat_progress_create_index', 'fast', ARRAY['pid'], false, interval '2 hours', 'per_backend', 'default-on',
     interval '365 days', interval '1 hour'),
    ('pg_catalog.pg_stat_progress_basebackup', 'fast', ARRAY['pid'], false, interval '2 hours', 'per_backend', 'default-on',
     interval '365 days', interval '1 hour'),
    ('pg_catalog.pg_stat_progress_analyze', 'fast', ARRAY['pid'], false, interval '2 hours', 'per_backend', 'default-on',
     interval '365 days', interval '1 hour'),
    ('pg_catalog.pg_stat_progress_copy', 'fast', ARRAY['pid'], false, interval '2 hours', 'per_backend', 'default-on',
     interval '365 days', interval '1 hour')
ON CONFLICT (source_view) DO NOTHING;

-- Group C addition, seeded after the initial v2 rewrite (additive, per
-- schema evolution policy): per-connection TLS/GSSAPI info, gauge-like and
-- per-backend exactly like pg_stat_activity, no debounce.
INSERT INTO pgfr_record.manifest
    (source_view, cadence_tier, natural_key, retention, size_class, notes, rollup_retention, rollup_granularity)
VALUES
    ('pg_catalog.pg_stat_ssl', 'fast', ARRAY['pid'], interval '2 hours', 'per_backend',
     'one row per connection, regular and replication alike',
     interval '365 days', interval '1 hour'),
    ('pg_catalog.pg_stat_gssapi', 'fast', ARRAY['pid'], interval '2 hours', 'per_backend',
     'one row per connection, regular and replication alike',
     interval '365 days', interval '1 hour')
ON CONFLICT (source_view) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Rollup specs (milestone 8): the hand-seeded, threshold-free statistics
-- for the Group C targets above that carry a rollup_retention. See the
-- comment on pgfr_record.rollup_specs (02_manifest.sql) for why these are
-- deliberately not threshold-based (that judgment is pgfr_analyze's, at
-- read time, against the stored continuous value here).
--
-- The six pg_stat_progress_* views share one shape of problem: rare,
-- bursty, per-backend, and none of them carries a start-time column of
-- its own (only captured_at says when pgfr saw one in flight), so there
-- is no duration to compute the way pg_stat_activity's idle_in_xact_max_
-- duration does. Their per-invocation progress counters (blocks/tuples
-- processed, etc.) reset with each new operation, so a MAX across a
-- whole bucket would conflate separate, unrelated operations rather than
-- describe one of them -- not a continuous quantity in the sense this
-- table requires. active_sample_count (a plain count of backend-tick
-- observations where the operation had any row present, no predicate)
-- sidesteps that: it is exactly the Mode A time-in-state estimation
-- STATISTICS.md already describes (sample count is proportional to time
-- observed in that state, not a count of distinct operations), applied
-- to "was an operation of this type running" instead of a backend state.
-- ---------------------------------------------------------------------------
INSERT INTO pgfr_record.rollup_specs
    (source_view, stat_name, agg, value_expr, predicate_sql)
VALUES
    ('pg_catalog.pg_stat_activity', 'idle_in_xact_max_duration', 'max',
     'extract(epoch FROM captured_at - xact_start)', $$state = 'idle in transaction'$$),
    ('pg_catalog.pg_stat_activity', 'lock_wait_max_duration', 'max',
     'extract(epoch FROM captured_at - query_start)', $$wait_event_type = 'Lock'$$),
    ('pg_catalog.pg_locks', 'blocked_sample_count', 'count',
     '1', 'granted = false'),
    ('pg_catalog.pg_stat_replication', 'non_streaming_sample_count', 'count',
     '1', $$state <> 'streaming'$$),
    ('pg_catalog.pg_stat_subscription', 'disconnected_sample_count', 'count',
     '1', 'pid IS NULL'),
    ('pg_catalog.pg_replication_slots', 'inactive_sample_count', 'count',
     '1', 'active = false'),
    ('pg_catalog.pg_prepared_xacts', 'prepared_max_age', 'max',
     'extract(epoch FROM captured_at - prepared)', NULL),
    ('pg_catalog.pg_stat_ssl', 'unencrypted_sample_count', 'count',
     '1', 'ssl = false'),
    ('pg_catalog.pg_stat_gssapi', 'unencrypted_sample_count', 'count',
     '1', 'encrypted = false'),
    ('pg_catalog.pg_stat_progress_vacuum', 'active_sample_count', 'count',
     '1', NULL),
    ('pg_catalog.pg_stat_progress_cluster', 'active_sample_count', 'count',
     '1', NULL),
    ('pg_catalog.pg_stat_progress_create_index', 'active_sample_count', 'count',
     '1', NULL),
    ('pg_catalog.pg_stat_progress_basebackup', 'active_sample_count', 'count',
     '1', NULL),
    ('pg_catalog.pg_stat_progress_analyze', 'active_sample_count', 'count',
     '1', NULL),
    ('pg_catalog.pg_stat_progress_copy', 'active_sample_count', 'count',
     '1', NULL)
ON CONFLICT (source_view, stat_name) DO NOTHING;

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

-- Group D additions, seeded after the initial v2 rewrite (additive, per
-- schema evolution policy): pg_ident_file_mappings is pg_hba_file_rules'
-- direct companion (same privileged-read/ledger-degradation story) that was
-- missed the first time; pg_publication_tables is the publisher-side
-- counterpart to pg_stat_subscription/pg_stat_subscription_stats
-- (Group A/C), which only cover the subscriber side.
INSERT INTO pgfr_record.manifest
    (source_view, cadence_tier, natural_key, debounce, anchor_every, retention, size_class, requires, notes)
VALUES
    ('pg_catalog.pg_ident_file_mappings', 'on_change', ARRAY['line_number'], true, interval '1 month', interval '365 days', 'singleton',
     'privileged read', 'the pg_ident.conf companion to pg_hba_file_rules; degrades via the ledger when unreadable'),
    ('pg_catalog.pg_publication_tables', 'on_change', ARRAY['pubname','schemaname','tablename'], true, interval '1 month', interval '365 days', 'singleton', NULL,
     'which tables are actually published; complements the subscriber-side pg_stat_subscription (Group C) and pg_stat_subscription_stats (Group A)')
ON CONFLICT (source_view) DO NOTHING;

-- Group D addition, seeded after the initial v2 rewrite (additive, per
-- schema evolution policy): datfrozenxid/datminmxid give the database-level
-- half of XID/MultiXID wraparound distance tracking (the per-relation half
-- comes from src_catalog_identity's relfrozenxid/relminmxid, above).
INSERT INTO pgfr_record.manifest
    (source_view, cadence_tier, natural_key, debounce, anchor_every, retention, size_class, requires, notes)
VALUES
    ('pg_catalog.pg_database', 'on_change', ARRAY['oid'], true, interval '1 month', interval '365 days', 'singleton', NULL,
     'catalog table, not a view; wraparound distance: datfrozenxid, datminmxid')
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
