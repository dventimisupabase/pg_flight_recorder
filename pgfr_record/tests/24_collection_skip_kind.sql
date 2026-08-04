-- =============================================================================
-- pgfr_record pgTAP Tests: enumerated skip_kind on collection_stats (Issue #100)
-- =============================================================================
-- Gap attribution must not string-match skipped_reason prose. New skips carry
-- an enumerated skip_kind written at the call site; legacy rows (and rows from
-- older installs) are classified by pgfr_record._skip_kind(reason), and every
-- consumer reads coalesce(skip_kind, _skip_kind(skipped_reason)) so the two
-- paths cannot disagree.
-- =============================================================================

BEGIN;
SELECT plan(9);

SELECT has_column('pgfr_record', 'collection_stats', 'skip_kind',
    'collection_stats has the additive skip_kind column');

SELECT has_function('pgfr_record', '_skip_kind', ARRAY['text'],
    '_skip_kind(reason) mapping function exists');

-- -----------------------------------------------------------------------------
-- 1. Legacy prose mapping
-- -----------------------------------------------------------------------------

SELECT is(
    pgfr_record._skip_kind('Circuit breaker tripped - recent runs exceeded threshold'),
    'circuit_breaker',
    '_skip_kind maps the sampler circuit-breaker prose');

SELECT is(
    pgfr_record._skip_kind('Circuit breaker tripped - last run exceeded threshold'),
    'circuit_breaker',
    '_skip_kind maps the snapshot circuit-breaker prose (different wording)');

SELECT is(
    pgfr_record._skip_kind('Load shedding: high load (90 active / 100 max = 90.0% >= 70% threshold)'),
    'load_shedding',
    '_skip_kind maps load-shedding prose');

SELECT is(
    pgfr_record._skip_kind('something unrecognized'),
    'unknown',
    '_skip_kind falls back to unknown');

-- -----------------------------------------------------------------------------
-- 2. Write path: forced skips record the enumerated kind
-- -----------------------------------------------------------------------------

-- Force a load-shedding skip: threshold 0% means any active backend trips it.
UPDATE pgfr_record.config SET value = '0' WHERE key = 'load_shedding_active_pct';
DELETE FROM pgfr_record.collection_stats WHERE collection_type = 'sample';
DO $$ BEGIN PERFORM pgfr_record.sample_ring(); END $$;

SELECT is(
    (SELECT skip_kind FROM pgfr_record.collection_stats
     WHERE collection_type = 'sample' AND skipped
     ORDER BY started_at DESC LIMIT 1),
    'load_shedding',
    'a load-shedding skip records skip_kind = load_shedding');

UPDATE pgfr_record.config SET value = '70' WHERE key = 'load_shedding_active_pct';

-- Force a circuit-breaker skip: a fake slow run over a tiny threshold.
UPDATE pgfr_record.config SET value = '100' WHERE key = 'circuit_breaker_threshold_ms';
DELETE FROM pgfr_record.collection_stats WHERE collection_type = 'sample';
INSERT INTO pgfr_record.collection_stats (collection_type, started_at, completed_at, duration_ms, success)
VALUES ('sample', now(), now(), 10000, true);
DO $$ BEGIN PERFORM pgfr_record.sample_ring(); END $$;

SELECT is(
    (SELECT skip_kind FROM pgfr_record.collection_stats
     WHERE collection_type = 'sample' AND skipped
     ORDER BY started_at DESC LIMIT 1),
    'circuit_breaker',
    'a circuit-breaker skip records skip_kind = circuit_breaker');

-- health_check() counts the same trip through the shared classification
SELECT ok(
    (SELECT details FROM pgfr_record.health_check()
     WHERE component = 'Circuit Breaker') ~ '^[1-9][0-9]* trips',
    'health_check() counts the circuit-breaker trip via skip_kind');

UPDATE pgfr_record.config SET value = '5000' WHERE key = 'circuit_breaker_threshold_ms';

SELECT * FROM finish();
ROLLBACK;
