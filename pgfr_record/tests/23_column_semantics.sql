-- =============================================================================
-- pgfr_record pgTAP Tests: column-level semantic annotations (Issue #99)
-- =============================================================================
-- Every column of every pgfr_record view must carry a COMMENT ON COLUMN whose
-- prefix follows the machine-parseable grammar defined in STATISTICS.md and
-- parsed by pgfr_analyze.column_semantics():
--
--   [<class>] [<units>] [interval-mean|instantaneous]? <prose>
--
-- with <class> one of: point-sample, counter-delta, gauge, derived, dimension.
--
-- These tests are the CI enforcement for the annotation policy: adding a view
-- column without a well-formed semantic comment fails the suite. The offender
-- list is the test value itself, so failures name the unannotated columns.
-- =============================================================================

BEGIN;
SELECT plan(4);

-- The dbdev package build strips every COMMENT ON statement to fit dbdev's
-- 250,000-character cap (see scripts/build_dbdev_package.sh), so on a
-- dbdev-channel install there are no annotations to enforce. Detect that via
-- a table comment that every other channel carries, and skip the
-- comment-dependent assertions; the psql and bundle channels still enforce.
CREATE TEMP VIEW __semantics_stripped AS
SELECT obj_description('pgfr_record.config'::regclass, 'pg_class') IS NULL AS stripped;

-- -----------------------------------------------------------------------------
-- 1. Coverage: no pgfr_record view column without a comment
-- -----------------------------------------------------------------------------

SELECT CASE WHEN (SELECT stripped FROM __semantics_stripped)
THEN skip('dbdev package strips COMMENT ON; annotations not present on this channel')
ELSE is(
    (SELECT coalesce(array_agg(c.relname || '.' || a.attname ORDER BY c.relname, a.attnum), '{}')
     FROM pg_class c
     JOIN pg_namespace n ON n.oid = c.relnamespace
     JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
     LEFT JOIN pg_description d
            ON d.objoid = c.oid
           AND d.classoid = 'pg_class'::regclass
           AND d.objsubid = a.attnum
     WHERE n.nspname = 'pgfr_record'
       AND c.relkind = 'v'
       AND d.description IS NULL),
    '{}'::text[],
    'every pgfr_record view column has a COMMENT ON COLUMN'
) END;

-- -----------------------------------------------------------------------------
-- 2. Well-formedness: every comment parses under the registry grammar
-- -----------------------------------------------------------------------------

SELECT is(
    (SELECT coalesce(array_agg(c.relname || '.' || a.attname ORDER BY c.relname, a.attnum), '{}')
     FROM pg_class c
     JOIN pg_namespace n ON n.oid = c.relnamespace
     JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
     JOIN pg_description d
            ON d.objoid = c.oid
           AND d.classoid = 'pg_class'::regclass
           AND d.objsubid = a.attnum
     WHERE n.nspname = 'pgfr_record'
       AND c.relkind = 'v'
       AND d.description !~ '^\[(point-sample|counter-delta|gauge|derived|dimension)\] \[[^\]]+\]( \[(interval-mean|instantaneous)\])? .+'),
    '{}'::text[],
    'every pgfr_record view column comment matches the [class] [units] grammar'
);

-- -----------------------------------------------------------------------------
-- 3. Spot checks: canonical annotations carry the exact prefixes STATISTICS.md
--    documents (rate columns are interval-mean counter deltas; ring-derived
--    columns are point samples)
-- -----------------------------------------------------------------------------

SELECT CASE WHEN (SELECT stripped FROM __semantics_stripped)
THEN skip('dbdev package strips COMMENT ON; annotations not present on this channel')
ELSE alike(
    col_description('pgfr_record.consumption_flows'::regclass,
        (SELECT attnum FROM pg_attribute
         WHERE attrelid = 'pgfr_record.consumption_flows'::regclass
           AND attname = 'block_demand_per_s')),
    '[counter-delta] [blocks/s] [interval-mean]%',
    'consumption_flows.block_demand_per_s is annotated as an interval-mean counter-delta rate'
) END;

SELECT CASE WHEN (SELECT stripped FROM __semantics_stripped)
THEN skip('dbdev package strips COMMENT ON; annotations not present on this channel')
ELSE alike(
    col_description('pgfr_record.recent_waits_v2'::regclass,
        (SELECT attnum FROM pg_attribute
         WHERE attrelid = 'pgfr_record.recent_waits_v2'::regclass
           AND attname = 'active_count')),
    '[point-sample]%',
    'recent_waits_v2.active_count is annotated as a point sample'
) END;

SELECT * FROM finish();
ROLLBACK;
