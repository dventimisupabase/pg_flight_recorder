-- =============================================================================
-- pgfr_analyze pgTAP Tests: column-semantics registry (Issue #99)
-- =============================================================================
-- pgfr_analyze.column_semantics() is the machine-readable registry of
-- column-level statistical semantics. It parses annotations straight out of
-- pg_description (COMMENT ON COLUMN for views, "Output columns:" blocks in
-- function comments for set-returning functions), so the comments are the
-- single source of truth and the registry cannot drift from them.
--
-- These tests are the CI enforcement for 100% registry coverage: every
-- pgfr_analyze view column and every output column of every public
-- set-returning function must resolve to a well-formed registry row, and the
-- registry must not contain entries for columns that do not exist (typo
-- guard). Offender lists are the test values, so failures name the columns.
-- =============================================================================

BEGIN;
SELECT plan(9);

SELECT has_function('pgfr_analyze', 'column_semantics',
    'pgfr_analyze.column_semantics() exists');

-- -----------------------------------------------------------------------------
-- 1. pgfr_analyze view columns: commented and well-formed
-- -----------------------------------------------------------------------------

SELECT is(
    (SELECT coalesce(array_agg(c.relname || '.' || a.attname ORDER BY c.relname, a.attnum), '{}')
     FROM pg_class c
     JOIN pg_namespace n ON n.oid = c.relnamespace
     JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
     LEFT JOIN pg_description d
            ON d.objoid = c.oid
           AND d.classoid = 'pg_class'::regclass
           AND d.objsubid = a.attnum
     WHERE n.nspname = 'pgfr_analyze'
       AND c.relkind = 'v'
       AND d.description IS NULL),
    '{}'::text[],
    'every pgfr_analyze view column has a COMMENT ON COLUMN'
);

SELECT is(
    (SELECT coalesce(array_agg(c.relname || '.' || a.attname ORDER BY c.relname, a.attnum), '{}')
     FROM pg_class c
     JOIN pg_namespace n ON n.oid = c.relnamespace
     JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
     JOIN pg_description d
            ON d.objoid = c.oid
           AND d.classoid = 'pg_class'::regclass
           AND d.objsubid = a.attnum
     WHERE n.nspname = 'pgfr_analyze'
       AND c.relkind = 'v'
       AND d.description !~ '^\[(point-sample|counter-delta|gauge|derived|dimension)\] \[[^\]]+\]( \[(interval-mean|instantaneous)\])? .+'),
    '{}'::text[],
    'every pgfr_analyze view column comment matches the [class] [units] grammar'
);

-- -----------------------------------------------------------------------------
-- 2. Set-returning function outputs: every declared output column of every
--    public pgfr_analyze SRF has a registry row (parsed from the function
--    comment's "Output columns:" block)
-- -----------------------------------------------------------------------------

SELECT is(
    (WITH declared AS (
        SELECT DISTINCT n.nspname || '.' || p.proname || '()' AS relation,
               args.argname AS column_name
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        CROSS JOIN LATERAL unnest(p.proargnames, p.proargmodes) AS args(argname, argmode)
        WHERE n.nspname = 'pgfr_analyze'
          AND p.proname NOT LIKE '\_%'
          AND p.proretset
          AND args.argmode IN ('t', 'o')
    )
    SELECT coalesce(array_agg(d.relation || '.' || d.column_name ORDER BY 1), '{}')
    FROM (SELECT relation, column_name FROM declared
          EXCEPT
          SELECT relation, column_name FROM pgfr_analyze.column_semantics()) d),
    '{}'::text[],
    'every output column of every public pgfr_analyze SRF is in the registry'
);

-- Typo guard: no registry entry for a function output column that is not
-- actually declared by the function (catches misspelled names in comments).
SELECT is(
    (WITH declared AS (
        SELECT DISTINCT n.nspname || '.' || p.proname || '()' AS relation,
               args.argname AS column_name
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        CROSS JOIN LATERAL unnest(p.proargnames, p.proargmodes) AS args(argname, argmode)
        WHERE n.nspname = 'pgfr_analyze'
          AND p.proretset
          AND args.argmode IN ('t', 'o')
    )
    SELECT coalesce(array_agg(s.relation || '.' || s.column_name ORDER BY 1), '{}')
    FROM (SELECT relation, column_name FROM pgfr_analyze.column_semantics()
          WHERE relation LIKE '%()'
          EXCEPT
          SELECT relation, column_name FROM declared) s),
    '{}'::text[],
    'the registry contains no function output columns that the functions do not declare'
);

-- -----------------------------------------------------------------------------
-- 3. Full-surface coverage: view columns in BOTH schemas are all in the
--    registry (the record-side grammar test lives in pgfr_record/tests;
--    this asserts the registry actually parses them)
-- -----------------------------------------------------------------------------

SELECT is(
    (WITH view_cols AS (
        SELECT n.nspname || '.' || c.relname AS relation,
               a.attname::text AS column_name
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
        WHERE n.nspname IN ('pgfr_record', 'pgfr_analyze')
          AND c.relkind = 'v'
    )
    SELECT coalesce(array_agg(v.relation || '.' || v.column_name ORDER BY 1), '{}')
    FROM (SELECT relation, column_name FROM view_cols
          EXCEPT
          SELECT relation, column_name FROM pgfr_analyze.column_semantics()) v),
    '{}'::text[],
    'every view column in both pgfr schemas resolves to a registry row'
);

-- -----------------------------------------------------------------------------
-- 4. Spot checks: canonical semantics land in the registry with the right
--    class, units, and denominator disclosure
-- -----------------------------------------------------------------------------

SELECT is(
    (SELECT semantic_class || '|' || units
     FROM pgfr_analyze.column_semantics()
     WHERE relation = 'pgfr_analyze.wait_summary()' AND column_name = 'pct_of_samples'),
    'point-sample|percent',
    'wait_summary().pct_of_samples is a point-sample percent in the registry'
);

SELECT ok(
    (SELECT notes ILIKE '%distinct ticks%'
     FROM pgfr_analyze.column_semantics()
     WHERE relation = 'pgfr_analyze.wait_summary()' AND column_name = 'pct_of_samples'),
    'wait_summary().pct_of_samples notes disclose the distinct-ticks denominator'
);

SELECT is(
    (SELECT semantic_class || '|' || units || '|' || interval_basis
     FROM pgfr_analyze.column_semantics()
     WHERE relation = 'pgfr_record.consumption_flows' AND column_name = 'block_demand_per_s'),
    'counter-delta|blocks/s|interval-mean',
    'consumption_flows.block_demand_per_s parses as an interval-mean counter-delta rate'
);

SELECT * FROM finish();
ROLLBACK;
