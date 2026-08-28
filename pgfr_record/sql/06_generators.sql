-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- Generators (§4.3): plpgsql functions that are pure functions of the
-- manifest plus the server's actual catalog. Re-running any generator is
-- always safe and is the upgrade procedure (§7).

-- Column list + type names for a source_view, in the view's own column
-- position order. Shared by generate_archives() (to mint payload_schemas
-- rows) and, later, generate_presentation_views() (to build cast lists).
CREATE OR REPLACE FUNCTION pgfr_record._introspect_columns(p_source_view text)
RETURNS TABLE(attnum smallint, column_name text, type_name text)
LANGUAGE sql STABLE AS $$
    SELECT a.attnum, a.attname::text, format_type(a.atttypid, a.atttypmod)
    FROM pg_attribute a
    WHERE a.attrelid = p_source_view::regclass
      AND a.attnum > 0
      AND NOT a.attisdropped;
$$;
COMMENT ON FUNCTION pgfr_record._introspect_columns(text) IS
    'Live column names + type names for a schema-qualified source_view, in attnum order. Raises undefined_table if the relation does not currently exist (unmet precondition, e.g. an extension not installed).';

-- Archives (§4.1, §4.3.1, §4.4). For each enabled, version-applicable
-- manifest row: create the uniform-shape archive table if absent, and
-- mint the payload_schemas row for its current live column layout --
-- the mint-together invariant's "schema" half; generate_capture_plan()
-- (not yet built) supplies the other half, the cached capture statement.
--
-- A manifest row whose source_view does not yet exist (an unmet
-- `requires` precondition -- e.g. pg_stat_statements not installed) is
-- not a tier failure at install time either: it is skipped with a NOTICE,
-- per §8.3 ("the installer surfaces unmet preconditions ... as NOTICEs,
-- not errors"). Re-running generate_archives() after the precondition is
-- met picks it up -- this is the same re-run-is-safe property as the
-- rest of the installer (§7).
CREATE OR REPLACE FUNCTION pgfr_record.generate_archives()
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_row       record;
    v_short     text;
    v_archive   text;
    v_columns   text[];
    v_types     text[];
    v_fp        text;
    v_schema_id smallint;
BEGIN
    FOR v_row IN
        SELECT *
        FROM pgfr_record.manifest
        WHERE enabled
          AND min_major <= pgfr_record._current_major()
          AND pgfr_record._current_major() <= coalesce(max_major, 999)
        ORDER BY source_view
    LOOP
        BEGIN
            v_short   := pgfr_record._short_name(v_row.source_view);
            v_archive := 'a_' || v_short;

            SELECT array_agg(column_name ORDER BY attnum), array_agg(type_name ORDER BY attnum)
            INTO v_columns, v_types
            FROM pgfr_record._introspect_columns(v_row.source_view);

            IF v_columns IS NULL THEN
                RAISE NOTICE 'pgfr_record.generate_archives: % has no introspectable columns, skipping', v_row.source_view;
                CONTINUE;
            END IF;

            v_fp := md5(v_row.source_view || ':' || array_to_string(v_columns, ',') || ':' || array_to_string(v_types, ','));

            SELECT schema_id INTO v_schema_id
            FROM pgfr_record.payload_schemas
            WHERE source_view = v_row.source_view AND fingerprint = v_fp;

            IF v_schema_id IS NULL THEN
                INSERT INTO pgfr_record.payload_schemas (source_view, columns, type_names, fingerprint)
                VALUES (v_row.source_view, v_columns, v_types, v_fp)
                RETURNING schema_id INTO v_schema_id;
            END IF;

            IF to_regclass('pgfr_record.' || v_archive) IS NULL THEN
                EXECUTE format(
                    'CREATE TABLE pgfr_record.%I (
                         captured_at timestamptz NOT NULL,
                         key         jsonb,
                         key_hash    bigint,
                         row_hash    bigint NOT NULL,
                         schema_id   smallint NOT NULL REFERENCES pgfr_record.payload_schemas,
                         payload     jsonb NOT NULL
                     ) PARTITION BY RANGE (captured_at)',
                    v_archive
                );
                EXECUTE format(
                    'CREATE INDEX %I ON pgfr_record.%I (key_hash, captured_at DESC)',
                    v_archive || '_key_hash_idx', v_archive
                );
            END IF;
        EXCEPTION
            WHEN undefined_table THEN
                RAISE NOTICE 'pgfr_record.generate_archives: % does not exist yet (requires: %); skipping until this generator is re-run',
                    v_row.source_view, coalesce(v_row.requires, 'unknown precondition');
            WHEN insufficient_privilege THEN
                RAISE NOTICE 'pgfr_record.generate_archives: insufficient privilege to introspect %, skipping', v_row.source_view;
        END;
    END LOOP;

    -- Every archive table just created needs its initial partitions
    -- before any collector can insert into it (§4.3.1).
    PERFORM pgfr_record.maintain_partitions();
END;
$$;

COMMENT ON FUNCTION pgfr_record.generate_archives() IS
    'For each enabled, version-applicable manifest row: create its uniform-shape archive table if absent, mint the payload_schemas row for its live column layout, and pre-create initial partitions. Pure function of the manifest + the live catalog; safe to re-run (§7).';
