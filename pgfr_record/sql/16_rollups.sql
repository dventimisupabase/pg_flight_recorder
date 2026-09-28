-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- Rollups (milestone 8): a uniform, dictionary-encoded table per target
-- that carries a rollup_retention, in one of two shapes:
--
--   endpoint shape (Group B, counters/odometers): one row per (bucket,
--   key), storing the first and last observed value of every counter/
--   odometer column in that bucket -- the two points a reset-aware delta
--   needs, mechanically derived from column_classes, the same way
--   presentation views are mechanically derived from payload_schemas.
--
--   stat shape (Group C, gauges): one row per (bucket, stat_name),
--   aggregated across every key in the bucket -- a gauge's rollup value
--   is a judgment call (see pgfr_record.rollup_specs), not a mechanical
--   derivation, and Group C's value is "did this happen in this bucket",
--   not a per-key history.
--
-- Neither shape carries a PRIMARY KEY, matching generate_archives()'s own
-- archive tables: uniqueness here is guaranteed by the collector's
-- bucket-close step (one write per bucket, checked before writing, the
-- same discipline as anchor detection), not by a database constraint, so
-- there is no unique-index maintenance cost on every insert.
CREATE OR REPLACE FUNCTION pgfr_record.generate_rollups()
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_row      record;
    v_short    text;
    v_rollup   text;
    v_has_ctr  boolean;
    v_has_spec boolean;
BEGIN
    FOR v_row IN
        SELECT *
        FROM pgfr_record.manifest
        WHERE enabled
          AND rollup_retention IS NOT NULL
          AND min_major <= pgfr_record._current_major()
          AND pgfr_record._current_major() <= coalesce(max_major, 999)
        ORDER BY source_view
    LOOP
        BEGIN
            v_short  := pgfr_record._short_name(v_row.source_view);
            v_rollup := 'r_' || v_short;

            IF to_regclass('pgfr_record.' || v_rollup) IS NOT NULL THEN
                -- Column-type migration: value was originally numeric,
                -- narrowed to double precision (a real per-row storage win
                -- across every partition, since these are already
                -- error-bounded Mode A estimates, not exact figures -- see
                -- STATISTICS.md). One-time per table: the next re-run finds
                -- the column already double precision and this is a no-op.
                IF EXISTS (
                    SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'pgfr_record' AND table_name = v_rollup
                      AND column_name = 'value' AND data_type = 'numeric'
                ) THEN
                    EXECUTE format(
                        'ALTER TABLE pgfr_record.%I ALTER COLUMN value TYPE double precision USING value::double precision',
                        v_rollup
                    );
                END IF;
                -- Column-add migration: schema_id, so an endpoint-shape
                -- rollup row can record which 'rollup' kind payload_schemas
                -- row its first_values/last_values arrays follow (see
                -- generate_capture_plan()). Nullable, unlike the archive's
                -- own schema_id: a row written before this column existed
                -- has no schema_id and keeps its original name-keyed jsonb
                -- object shape forever -- rollup_deltas() reads either
                -- shape depending on whether a given row has one.
                IF EXISTS (
                    SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'pgfr_record' AND table_name = v_rollup AND column_name = 'first_values'
                ) AND NOT EXISTS (
                    SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'pgfr_record' AND table_name = v_rollup AND column_name = 'schema_id'
                ) THEN
                    EXECUTE format(
                        'ALTER TABLE pgfr_record.%I ADD COLUMN schema_id smallint REFERENCES pgfr_record.payload_schemas',
                        v_rollup
                    );
                END IF;
                CONTINUE;
            END IF;

            SELECT EXISTS (
                SELECT 1 FROM pgfr_record.column_classes
                WHERE source_view = v_row.source_view AND class IN ('counter', 'odometer')
            ) INTO v_has_ctr;
            SELECT EXISTS (
                SELECT 1 FROM pgfr_record.rollup_specs WHERE source_view = v_row.source_view
            ) INTO v_has_spec;

            -- rollup_specs checked first: it is the explicit, hand-curated
            -- signal that a target wants the stat shape. Checking
            -- column_classes first would misroute a Group C target that
            -- happens to also carry an odometer column (e.g.
            -- pg_stat_activity's backend_xid/backend_xmin, xid-typed and
            -- therefore odometer by generate_column_classes()' own rule)
            -- into the endpoint shape it was never meant to have -- the
            -- same "identity always wins, checked first" lesson
            -- generate_column_classes() itself already learned for
            -- natural_key vs. its override list.
            IF v_has_spec THEN
                EXECUTE format(
                    'CREATE TABLE pgfr_record.%I (
                         bucket_start  timestamptz NOT NULL,
                         stat_name     text NOT NULL,
                         value         double precision,
                         sample_count  int NOT NULL DEFAULT 0
                     ) PARTITION BY RANGE (bucket_start)',
                    v_rollup
                );
                EXECUTE format('CREATE INDEX %I ON pgfr_record.%I (stat_name, bucket_start DESC)', v_rollup || '_stat_idx', v_rollup);
            ELSIF v_has_ctr THEN
                EXECUTE format(
                    'CREATE TABLE pgfr_record.%I (
                         bucket_start       timestamptz NOT NULL,
                         key                jsonb,
                         key_hash           bigint,
                         first_captured_at  timestamptz NOT NULL,
                         last_captured_at   timestamptz NOT NULL,
                         schema_id          smallint REFERENCES pgfr_record.payload_schemas,
                         first_values       jsonb NOT NULL,
                         last_values        jsonb NOT NULL,
                         first_reset_values jsonb,
                         last_reset_values  jsonb
                     ) PARTITION BY RANGE (bucket_start)',
                    v_rollup
                );
                EXECUTE format('CREATE INDEX %I ON pgfr_record.%I (key_hash, bucket_start DESC)', v_rollup || '_key_hash_idx', v_rollup);
            ELSE
                RAISE NOTICE 'pgfr_record.generate_rollups: % has rollup_retention set but no column_classes counter/odometer columns and no rollup_specs rows -- nothing to roll up, skipping', v_row.source_view;
                CONTINUE;
            END IF;
        EXCEPTION
            WHEN undefined_table THEN
                RAISE NOTICE 'pgfr_record.generate_rollups: % does not exist yet; skipping until this generator is re-run', v_row.source_view;
        END;
    END LOOP;

    -- Every rollup table just created needs its initial partitions before
    -- the collector's bucket-close step can insert into it (mirrors
    -- generate_archives()'s own call at the end of its loop).
    PERFORM pgfr_record.maintain_partitions();
END;
$$;

COMMENT ON FUNCTION pgfr_record.generate_rollups() IS
    'For each enabled manifest row with rollup_retention set: create its rollup table if absent, in one of two uniform shapes -- endpoint (first/last value per counter/odometer column per bucket, for Group B) if column_classes has counter/odometer columns for it, or stat (aggregated per rollup_specs, for Group C) if pgfr_record.rollup_specs has rows for it -- and pre-create initial partitions. Must run after generate_column_classes() (needs its output to choose a shape); safe to re-run.';
