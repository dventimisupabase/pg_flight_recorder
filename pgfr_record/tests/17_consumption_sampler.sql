-- =============================================================================
-- pgfr_record pgTAP Tests — Consumption Sampler (Issue #81)
-- =============================================================================
-- Tests the generic reset-guard primitive, the consumption ledger schema, the
-- collector's real-catalog wiring, and the reset-guarded flow/ratio view.
--
-- The view-level reset behavior (acceptance criterion: "LSN-based WAL flow
-- survives a deliberate pg_stat_reset() / pg_stat_reset_shared('wal') while
-- counter-based lanes correctly discard the interval") is tested via inserted
-- fixture rows rather than by actually calling pg_stat_reset(): this whole
-- suite runs in one transaction where now() is frozen at transaction start,
-- so two real snapshot() ticks would land on the same sample_ts; and a real
-- pg_stat_reset() would blow away counters other test files in this suite
-- may depend on. Fixture rows exercise the same guard logic deterministically
-- and additionally show it is guarded per-source (db vs. wal) rather than as
-- one blanket per-row flag.
-- =============================================================================

BEGIN;
SELECT plan(25);

-- -----------------------------------------------------------------------------
-- 1. _reset_guarded_delta() — generic primitive, no DB state (6 tests)
-- -----------------------------------------------------------------------------

SELECT is(
    pgfr_record._reset_guarded_delta(150::numeric, 100::numeric, '2026-01-01'::timestamptz, '2026-01-01'::timestamptz),
    50::numeric,
    '_reset_guarded_delta: normal increase returns curr - prev'
);

SELECT is(
    pgfr_record._reset_guarded_delta(50::numeric, 100::numeric, '2026-01-01'::timestamptz, '2026-01-01'::timestamptz),
    null::numeric,
    '_reset_guarded_delta: regression (curr < prev) returns NULL'
);

SELECT is(
    pgfr_record._reset_guarded_delta(150::numeric, 100::numeric, '2026-01-02'::timestamptz, '2026-01-01'::timestamptz),
    null::numeric,
    '_reset_guarded_delta: changed reset sentinel returns NULL even if curr > prev'
);

SELECT is(
    pgfr_record._reset_guarded_delta(null::numeric, 100::numeric, '2026-01-01'::timestamptz, '2026-01-01'::timestamptz),
    null::numeric,
    '_reset_guarded_delta: NULL curr returns NULL'
);

SELECT is(
    pgfr_record._reset_guarded_delta(150::numeric, null::numeric, '2026-01-01'::timestamptz, '2026-01-01'::timestamptz),
    null::numeric,
    '_reset_guarded_delta: NULL prev (first sample) returns NULL'
);

SELECT is(
    pgfr_record._reset_guarded_delta(150::numeric, 100::numeric, '2026-01-01'::timestamptz, null::timestamptz),
    50::numeric,
    '_reset_guarded_delta: NULL prev sentinel (legacy row) falls back to regression-only check'
);

-- -----------------------------------------------------------------------------
-- 2. Schema (7 tests)
-- -----------------------------------------------------------------------------

SELECT has_table('pgfr_record', 'consumption_snapshots_v2',
    'consumption_snapshots_v2 table exists');
SELECT has_column('pgfr_record', 'consumption_snapshots_v2', 'wal_lsn',
    'consumption_snapshots_v2: wal_lsn column exists');
SELECT has_column('pgfr_record', 'consumption_snapshots_v2', 'tup_returned',
    'consumption_snapshots_v2: tup_returned column exists');
SELECT has_column('pgfr_record', 'consumption_snapshots_v2', 'io_reads_total',
    'consumption_snapshots_v2: io_reads_total column exists');
SELECT has_column('pgfr_record', 'consumption_snapshots_v2', 'db_stats_reset',
    'consumption_snapshots_v2: db_stats_reset column exists');
SELECT has_column('pgfr_record', 'consumption_snapshots_v2', 'recorder_blks_hit',
    'consumption_snapshots_v2: recorder_blks_hit column exists');
SELECT has_view('pgfr_record', 'consumption_flows',
    'consumption_flows view exists');

-- -----------------------------------------------------------------------------
-- 3. Partitioning — RANGE by int4 sample_ts, matching sibling v2 tables (1 test)
-- -----------------------------------------------------------------------------

SELECT ok(
    (SELECT pt.partstrat FROM pg_catalog.pg_partitioned_table pt
     JOIN pg_catalog.pg_class c ON c.oid = pt.partrelid
     JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'pgfr_record' AND c.relname = 'consumption_snapshots_v2') = 'r',
    'consumption_snapshots_v2 is RANGE-partitioned'
);

-- -----------------------------------------------------------------------------
-- 4. Collector wiring against real catalogs (4 tests)
-- -----------------------------------------------------------------------------

SELECT lives_ok($$SELECT pgfr_record.snapshot()$$,
    'snapshot() runs cleanly with the consumption collector wired into the v2 trigger');

SELECT ok(
    (SELECT wal_lsn FROM pgfr_record.consumption_snapshots_v2
     WHERE datname = current_database() ORDER BY sample_ts DESC LIMIT 1) IS NOT NULL,
    'consumption collector recorded a non-NULL wal_lsn on a primary'
);

SELECT is(
    (SELECT pg_version FROM pgfr_record.consumption_snapshots_v2
     WHERE datname = current_database() ORDER BY sample_ts DESC LIMIT 1),
    pgfr_record._pg_version(),
    'consumption collector recorded the running pg_version'
);

SELECT ok(
    (SELECT db_size_bytes FROM pgfr_record.consumption_snapshots_v2
     WHERE datname = current_database() ORDER BY sample_ts DESC LIMIT 1) > 0,
    'consumption collector recorded a positive db_size_bytes'
);

-- -----------------------------------------------------------------------------
-- 5. Reset-guarded flow view — fixture rows under a private datname so the
--    self-join's "previous row" lookup can't be contaminated by real ticks
--    from section 4 above (7 tests)
-- -----------------------------------------------------------------------------

INSERT INTO pgfr_record.consumption_snapshots_v2 (
    snapshot_id, sample_ts, captured_at, pg_version, datname,
    wal_lsn, tup_returned, xact_commit, blks_hit, blks_read,
    wal_records, wal_fpi, wal_bytes, wal_stats_reset,
    db_stats_reset
) VALUES
    -- row 1: baseline
    (900001, 10000, now(), 17, '__pgfr_test_consumption__',
     '0/1000000'::pg_lsn, 100, 10, 500, 50,
     1000, 10, 200000, '2026-01-01'::timestamptz,
     '2026-01-01'::timestamptz),
    -- row 2: normal tick, no reset
    (900002, 10060, now(), 17, '__pgfr_test_consumption__',
     '0/2000000'::pg_lsn, 150, 15, 600, 55,
     1100, 12, 220000, '2026-01-01'::timestamptz,
     '2026-01-01'::timestamptz),
    -- row 3: db-scoped reset (pg_stat_reset()-style) — db_stats_reset changed,
    -- tup_returned/xact_commit/blks_* regressed; wal lanes untouched
    (900003, 10120, now(), 17, '__pgfr_test_consumption__',
     '0/3000000'::pg_lsn, 20, 2, 30, 5,
     1150, 13, 230000, '2026-01-01'::timestamptz,
     '2026-01-02'::timestamptz),
    -- row 4: wal-scoped reset (pg_stat_reset_shared('wal')-style) — wal_stats_reset
    -- changed, wal_records/wal_fpi/wal_bytes regressed; db lanes untouched
    (900004, 10180, now(), 17, '__pgfr_test_consumption__',
     '0/4000000'::pg_lsn, 70, 7, 40, 6,
     10, 1, 500, '2026-01-03'::timestamptz,
     '2026-01-02'::timestamptz);

SELECT ok(
    (SELECT rows_returned_per_s FROM pgfr_record.consumption_flows
     WHERE datname = '__pgfr_test_consumption__' AND sample_ts = 10060) > 0,
    'consumption_flows: normal interval yields a positive rows_returned_per_s'
);

SELECT ok(
    (SELECT wal_bytes_per_s FROM pgfr_record.consumption_flows
     WHERE datname = '__pgfr_test_consumption__' AND sample_ts = 10060) > 0,
    'consumption_flows: normal interval yields a positive wal_bytes_per_s'
);

SELECT ok(
    (SELECT rows_returned_per_s FROM pgfr_record.consumption_flows
     WHERE datname = '__pgfr_test_consumption__' AND sample_ts = 10120) IS NULL,
    'consumption_flows: db-scoped reset discards rows_returned_per_s for that interval'
);

SELECT ok(
    (SELECT xact_per_s FROM pgfr_record.consumption_flows
     WHERE datname = '__pgfr_test_consumption__' AND sample_ts = 10120) IS NULL,
    'consumption_flows: db-scoped reset discards xact_per_s for that interval'
);

SELECT ok(
    (SELECT wal_bytes_per_s FROM pgfr_record.consumption_flows
     WHERE datname = '__pgfr_test_consumption__' AND sample_ts = 10120) > 0,
    'consumption_flows: wal_bytes_per_s (LSN ledger) survives a db-scoped reset'
);

SELECT ok(
    (SELECT fpi_fraction FROM pgfr_record.consumption_flows
     WHERE datname = '__pgfr_test_consumption__' AND sample_ts = 10180) IS NULL,
    'consumption_flows: wal-scoped reset discards fpi_fraction for that interval'
);

SELECT ok(
    (SELECT wal_bytes_per_s FROM pgfr_record.consumption_flows
     WHERE datname = '__pgfr_test_consumption__' AND sample_ts = 10180) > 0
    AND (SELECT rows_returned_per_s FROM pgfr_record.consumption_flows
         WHERE datname = '__pgfr_test_consumption__' AND sample_ts = 10180) > 0,
    'consumption_flows: a wal-only reset leaves the LSN ledger and db-scoped flows valid'
);

SELECT * FROM finish();
ROLLBACK;
