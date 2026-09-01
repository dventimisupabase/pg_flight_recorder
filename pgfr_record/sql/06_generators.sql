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

-- payload->>i (the ->> operator) extracts a jsonb array element as its
-- JSON-text representation -- for a scalar this is fine ('123', 'true'),
-- but for a nested array value (e.g. pg_settings.enumvals, a text[]) it
-- yields JSON syntax ('["a", "b"]', square brackets), which is not valid
-- Postgres array literal syntax ('{a,b}', curly braces) and fails
-- ::type[] with "malformed array literal". Array-typed columns need
-- jsonb_array_elements_text() reassembled into a real array instead, with
-- an explicit guard for a captured NULL (a JSON null scalar at that
-- position, not an empty array, which jsonb_array_elements_text() cannot
-- iterate).
CREATE OR REPLACE FUNCTION pgfr_record._jsonb_element_cast(p_type_name text, p_index int)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN p_type_name LIKE '%[]' THEN
            format(
                '(CASE WHEN payload->%s = ''null''::jsonb THEN NULL::%s ELSE ARRAY(SELECT jsonb_array_elements_text(payload->%s))::%s END)',
                p_index, p_type_name, p_index, p_type_name
            )
        ELSE
            format('(payload->>%s)::%s', p_index, p_type_name)
    END;
$$;
COMMENT ON FUNCTION pgfr_record._jsonb_element_cast(text, int) IS
    'The correct SQL expression (referencing a payload column in scope) to extract and cast payload array position p_index to p_type_name -- handling array-typed columns (jsonb_array_elements_text reassembly) separately from scalars (a plain ->> cast), since ->> yields JSON-bracket syntax for a nested array value, not a Postgres array literal.';

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

-- Presentation views (§4.3.2, §4.4): project a target's jsonb-array
-- payloads back into the source view's typed columns, plus captured_at.
-- The fidelity promise ("the data model is exactly the PostgreSQL views")
-- is made and kept here, not at the payload layer (§4.4's "honest
-- concession").
--
-- A source_view can have more than one payload_schemas row over time --
-- mid-major column accretion (pg_stat_statements is the known offender,
-- §4.4) mints a new schema_id rather than editing the old one. The
-- presentation view's column set always matches the *current* (highest
-- schema_id) shape; older rows captured under a narrower prior schema get
-- NULL for whatever column didn't exist yet, via one UNION ALL branch per
-- schema_id the source_view has ever had. Positions are resolved
-- per-variant (a column's array index can differ across schema_id
-- variants), never assumed to line up across schemas.
CREATE OR REPLACE FUNCTION pgfr_record.generate_presentation_views()
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_source_view record;
    v_current     record;
    v_variant     record;
    v_short       text;
    v_col         text;
    v_pos         int;
    v_variant_pos int;
    v_exprs       text[];
    v_branches    text[];
BEGIN
    FOR v_source_view IN
        SELECT DISTINCT m.source_view
        FROM pgfr_record.manifest m
        WHERE m.enabled
          AND m.min_major <= pgfr_record._current_major()
          AND pgfr_record._current_major() <= coalesce(m.max_major, 999)
    LOOP
        v_short := pgfr_record._short_name(v_source_view.source_view);

        -- The current (most recently minted) shape defines the view's
        -- column set. No row yet means generate_archives() has not run,
        -- or the target's precondition remains unmet -- nothing to do.
        SELECT * INTO v_current
        FROM pgfr_record.payload_schemas
        WHERE source_view = v_source_view.source_view
        ORDER BY schema_id DESC
        LIMIT 1;

        IF NOT FOUND THEN
            CONTINUE;
        END IF;

        v_branches := '{}';
        FOR v_variant IN
            SELECT * FROM pgfr_record.payload_schemas
            WHERE source_view = v_source_view.source_view
        LOOP
            v_exprs := '{}';
            FOR v_pos IN 1..array_length(v_current.columns, 1) LOOP
                v_col := v_current.columns[v_pos];

                SELECT ord INTO v_variant_pos
                FROM unnest(v_variant.columns) WITH ORDINALITY AS u(name, ord)
                WHERE u.name = v_col;

                IF v_variant_pos IS NULL THEN
                    v_exprs := v_exprs || format('NULL::%s AS %I', v_current.type_names[v_pos], v_col);
                ELSE
                    v_exprs := v_exprs || format(
                        '%s AS %I',
                        pgfr_record._jsonb_element_cast(v_variant.type_names[v_variant_pos], v_variant_pos - 1),
                        v_col
                    );
                END IF;
            END LOOP;

            v_branches := v_branches || format(
                'SELECT captured_at, %s FROM pgfr_record.%I WHERE schema_id = %s',
                array_to_string(v_exprs, ', '), 'a_' || v_short, v_variant.schema_id
            );
        END LOOP;

        -- DROP + CREATE, not CREATE OR REPLACE: Postgres refuses to
        -- replace a view in a way that removes or reorders existing
        -- output columns, and a real (not just test-manufactured)
        -- source_view can legitimately shrink its column set between
        -- majors -- e.g. PG17 moving checkpoint columns out of
        -- pg_stat_bgwriter (§7). Safe because presentation views are
        -- freely regenerable, unlike the archive data underneath them.
        EXECUTE format('DROP VIEW IF EXISTS pgfr_record.%I', 'v_' || v_short);
        EXECUTE format(
            'CREATE VIEW pgfr_record.%I AS %s',
            'v_' || v_short, array_to_string(v_branches, ' UNION ALL ')
        );
    END LOOP;
END;
$$;

COMMENT ON FUNCTION pgfr_record.generate_presentation_views() IS
    'For each enabled, version-applicable manifest row with a minted schema: (re)create v_<short_name>, projecting the archive''s jsonb-array payloads back into the source view''s typed columns via one UNION ALL branch per schema_id that source_view has ever had. Regenerated per major at install/upgrade (§7); safe to re-run.';
