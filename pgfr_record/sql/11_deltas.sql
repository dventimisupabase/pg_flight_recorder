-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- deltas() (§4.5): consecutive-sample differences per key over
-- counter/odometer columns, reset-aware. Never a negative rate: a
-- decreased counter value, or an advanced reset_column, yields NULL for
-- that interval rather than a bogus negative delta. Odometers (LSNs,
-- XIDs) skip reset detection entirely, per §2's definition.
--
-- Built on state_as_of(): deltas(source_view, from_t, to_t) is exactly
-- "join state_as_of(source_view, to_t) to state_as_of(source_view,
-- from_t) on the key, then difference the counter/odometer columns" --
-- no separate reconstruction logic.
--
-- Returns SETOF record, like state_as_of(); the caller supplies a
-- column-definition list. Counter/odometer columns are named
-- <column>_delta; everything else (key, label, gauge columns) passes
-- through as the to_t value, under its own name. One type wrinkle worth
-- knowing before writing an AS() clause: pg_lsn - pg_lsn yields numeric,
-- not pg_lsn, so an LSN odometer's _delta column is numeric.
CREATE OR REPLACE FUNCTION pgfr_record.deltas(p_source_view text, p_from_t timestamptz, p_to_t timestamptz)
RETURNS SETOF record
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_manifest    record;
    v_ps          record;
    v_col_defs    text;
    v_key_cols    text;
    v_join_clause text;
    v_select_list text[];
    v_i           int;
    v_col         text;
    v_class       text;
    v_reset_col   text;
    v_sql         text;
BEGIN
    SELECT * INTO v_manifest FROM pgfr_record.manifest WHERE source_view = p_source_view;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'pgfr_record.deltas: unknown source_view %', p_source_view;
    END IF;
    IF v_manifest.keyless THEN
        RAISE EXCEPTION 'pgfr_record.deltas: % is keyless; deltas requires row identity to correlate two points in time', p_source_view;
    END IF;

    SELECT schema_id, columns, type_names INTO v_ps
    FROM pgfr_record.payload_schemas
    WHERE source_view = p_source_view
    ORDER BY schema_id DESC
    LIMIT 1;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'pgfr_record.deltas: no payload schema minted yet for %', p_source_view;
    END IF;

    SELECT 'captured_at timestamptz, ' || string_agg(format('%I %s', c, t), ', ' ORDER BY ord)
    INTO v_col_defs
    FROM unnest(v_ps.columns, v_ps.type_names) WITH ORDINALITY AS u(c, t, ord);

    v_select_list := '{}';
    FOR v_i IN 1..array_length(v_ps.columns, 1) LOOP
        v_col := v_ps.columns[v_i];

        IF v_col = ANY(v_manifest.natural_key) THEN
            v_select_list := v_select_list || format('t.%I', v_col);
            CONTINUE;
        END IF;

        SELECT class, reset_column INTO v_class, v_reset_col
        FROM pgfr_record.column_classes
        WHERE source_view = p_source_view AND column_name = v_col;

        IF v_class = 'counter' THEN
            IF v_reset_col IS NOT NULL THEN
                v_select_list := v_select_list || format(
                    'CASE WHEN t.%I < f.%I OR t.%I IS DISTINCT FROM f.%I THEN NULL ELSE t.%I - f.%I END AS %I',
                    v_col, v_col, v_reset_col, v_reset_col, v_col, v_col, v_col || '_delta'
                );
            ELSE
                v_select_list := v_select_list || format(
                    'CASE WHEN t.%I < f.%I THEN NULL ELSE t.%I - f.%I END AS %I',
                    v_col, v_col, v_col, v_col, v_col || '_delta'
                );
            END IF;
        ELSIF v_class = 'odometer' THEN
            v_select_list := v_select_list || format('(t.%I - f.%I) AS %I', v_col, v_col, v_col || '_delta');
        ELSE
            v_select_list := v_select_list || format('t.%I AS %I', v_col, v_col);
        END IF;
    END LOOP;

    IF array_length(v_manifest.natural_key, 1) IS NULL THEN
        v_join_clause := 'ON true';
    ELSE
        SELECT string_agg(quote_ident(k), ', ') INTO v_key_cols FROM unnest(v_manifest.natural_key) k;
        v_join_clause := format('USING (%s)', v_key_cols);
    END IF;

    v_sql := format(
        'SELECT %s, f.captured_at AS from_captured_at, t.captured_at AS to_captured_at
         FROM pgfr_record.state_as_of(%L, %L::timestamptz) AS t(%s)
         JOIN pgfr_record.state_as_of(%L, %L::timestamptz) AS f(%s)
         %s',
        array_to_string(v_select_list, ', '),
        p_source_view, p_to_t, v_col_defs,
        p_source_view, p_from_t, v_col_defs,
        v_join_clause
    );

    RETURN QUERY EXECUTE v_sql;
END;
$$;

COMMENT ON FUNCTION pgfr_record.deltas(text, timestamptz, timestamptz) IS
    'Consecutive-sample differences per key between from_t and to_t (§4.5): counter columns are reset-aware (a decreased value, or an advanced reset_column, yields NULL rather than a negative rate); odometer columns skip reset detection; everything else passes through as the to_t value. A key present at to_t but absent at from_t is excluded (an inner join on state_as_of() of both points), not fabricated. Returns SETOF record; supply a column-definition list, e.g. deltas(''pg_catalog.pg_stat_wal'', t1, t2) AS d(wal_records_delta bigint, wal_bytes_delta numeric, ..., from_captured_at timestamptz, to_captured_at timestamptz) -- note an LSN odometer''s _delta column is numeric, not pg_lsn (pg_lsn - pg_lsn yields numeric).';
