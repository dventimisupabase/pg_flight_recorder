-- =============================================================================
-- pgfr_record pgTAP Tests — xmin Horizon Monitoring
-- =============================================================================
-- Tests the schema additions and collector behaviour for xmin horizon
-- monitoring. See REFERENCE.md "xmin horizon monitoring" and
-- blueprints/XMIN_HORIZON.md.
-- =============================================================================

BEGIN;
SELECT plan(15);

-- -----------------------------------------------------------------------------
-- 1. Schema — new columns on pgfr_record.snapshots (8 tests)
-- -----------------------------------------------------------------------------

SELECT has_column('pgfr_record', 'snapshots', 'activity_xmin_age',
    'snapshots: activity_xmin_age column exists');
SELECT has_column('pgfr_record', 'snapshots', 'slot_xmin_age',
    'snapshots: slot_xmin_age column exists');
SELECT has_column('pgfr_record', 'snapshots', 'slot_catalog_xmin_age',
    'snapshots: slot_catalog_xmin_age column exists');
SELECT has_column('pgfr_record', 'snapshots', 'replication_xmin_age',
    'snapshots: replication_xmin_age column exists');
SELECT has_column('pgfr_record', 'snapshots', 'prepared_xmin_age',
    'snapshots: prepared_xmin_age column exists');
SELECT has_column('pgfr_record', 'snapshots', 'xmin_data_horizon_age',
    'snapshots: xmin_data_horizon_age column exists');
SELECT has_column('pgfr_record', 'snapshots', 'xmin_any_horizon_age',
    'snapshots: xmin_any_horizon_age column exists');
SELECT col_type_is('pgfr_record', 'snapshots', 'xmin_horizon_detail', 'jsonb',
    'snapshots: xmin_horizon_detail is JSONB');

-- -----------------------------------------------------------------------------
-- 2. Schema — new columns on replication_snapshots (1 test)
-- -----------------------------------------------------------------------------

SELECT has_column('pgfr_record', 'replication_snapshots', 'is_logical_walsender',
    'replication_snapshots: is_logical_walsender column exists');

-- -----------------------------------------------------------------------------
-- 3. GREATEST NULL behavior (this design depends on it) (1 test)
-- -----------------------------------------------------------------------------

SELECT is(greatest(NULL::bigint, 10::bigint), 10::bigint,
    'GREATEST(NULL, 10) returns 10 — design depends on PostgreSQL ignoring NULLs');

-- -----------------------------------------------------------------------------
-- 4. Collector populates new columns + invariants (4 tests)
-- -----------------------------------------------------------------------------

SELECT lives_ok($$SELECT pgfr_record.snapshot()$$,
    'snapshot() runs cleanly with the xmin horizon section in place');

-- xmin_data_horizon_age is non-negative when populated, NULL otherwise.
SELECT ok(
    (SELECT xmin_data_horizon_age FROM pgfr_record.snapshots
     ORDER BY id DESC LIMIT 1) IS NULL
    OR
    (SELECT xmin_data_horizon_age FROM pgfr_record.snapshots
     ORDER BY id DESC LIMIT 1) >= 0,
    'snapshots.xmin_data_horizon_age is NULL or non-negative after snapshot()'
);

-- Collector self-pin exclusion: snapshot()'s own backend never appears as a
-- holder in xmin_horizon_detail.
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pgfr_record.snapshots
        WHERE id = (SELECT max(id) FROM pgfr_record.snapshots)
          AND xmin_horizon_detail->'holder'->>'pid' = pg_backend_pid()::text
    ),
    'self-pin excluded: collector pid never appears in xmin_horizon_detail'
);

-- xmin_any_horizon_age >= xmin_data_horizon_age (NULL-safe via GREATEST).
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pgfr_record.snapshots
        WHERE id = (SELECT max(id) FROM pgfr_record.snapshots)
          AND xmin_any_horizon_age IS NOT NULL
          AND xmin_data_horizon_age IS NOT NULL
          AND xmin_any_horizon_age < xmin_data_horizon_age
    ),
    'invariant: xmin_any_horizon_age >= xmin_data_horizon_age'
);

-- -----------------------------------------------------------------------------
-- 5. JSONB detail shape (1 test) — when populated, it has the documented shape
-- -----------------------------------------------------------------------------

SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pgfr_record.snapshots
        WHERE id = (SELECT max(id) FROM pgfr_record.snapshots)
          AND xmin_horizon_detail IS NOT NULL
          AND ((xmin_horizon_detail->>'source') NOT IN
                  ('activity','slot','slot_catalog','prepared','replication')
               OR jsonb_typeof(xmin_horizon_detail->'holder') NOT IN ('object','null'))
    ),
    'xmin_horizon_detail (when present) has source IN (activity|slot|slot_catalog|prepared|replication) and an object holder'
);

SELECT * FROM finish();
ROLLBACK;
