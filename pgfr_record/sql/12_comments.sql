-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- Generated COMMENT ON (§4.5): the discovery channel an agent actually
-- uses. \d+ on any archive table or presentation view should explain
-- itself -- what it is, its cadence/retention/debounce facts from the
-- manifest, and per-column class/reset-linkage from column_classes --
-- without needing this pack open alongside it.
CREATE OR REPLACE FUNCTION pgfr_record.generate_comments()
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_row     record;
    v_short   text;
    v_archive text;
    v_view    text;
    v_col     record;
BEGIN
    FOR v_row IN
        SELECT m.source_view, m.cadence_tier, m.retention, m.debounce, m.anchor_every, m.notes
        FROM pgfr_record.manifest m
        WHERE m.enabled
          AND m.min_major <= pgfr_record._current_major()
          AND pgfr_record._current_major() <= coalesce(m.max_major, 999)
          AND EXISTS (SELECT 1 FROM pgfr_record.payload_schemas p WHERE p.source_view = m.source_view)
    LOOP
        v_short   := pgfr_record._short_name(v_row.source_view);
        v_archive := 'a_' || v_short;
        v_view    := 'v_' || v_short;

        EXECUTE format('COMMENT ON TABLE pgfr_record.%I IS %L', v_archive, format(
            'Archive of %s. Cadence: %s. Retention: %s. Debounce: %s%s.%s',
            v_row.source_view, v_row.cadence_tier, v_row.retention, v_row.debounce,
            CASE WHEN v_row.anchor_every IS NOT NULL THEN format(' (anchor every %s)', v_row.anchor_every) ELSE '' END,
            CASE WHEN v_row.notes IS NOT NULL THEN ' ' || v_row.notes ELSE '' END
        ));
        EXECUTE format('COMMENT ON COLUMN pgfr_record.%I.captured_at IS %L', v_archive,
            'When this sample was taken -- the tier''s single stamp for this run (§5).');
        EXECUTE format('COMMENT ON COLUMN pgfr_record.%I.key IS %L', v_archive,
            'Natural-key columns extracted as a jsonb object; NULL when keyless or singleton.');
        EXECUTE format('COMMENT ON COLUMN pgfr_record.%I.key_hash IS %L', v_archive,
            'hashtextextended(key::text, 0); NULL when key IS NULL. Used for the debounce anti-join and LOCF (§6).');
        EXECUTE format('COMMENT ON COLUMN pgfr_record.%I.row_hash IS %L', v_archive,
            'hashtextextended(compare_payload::text, 0), with compare_ignore columns nulled and schema_id folded into the compared text (§6).');
        EXECUTE format('COMMENT ON COLUMN pgfr_record.%I.schema_id IS %L', v_archive,
            'Which pgfr_record.payload_schemas row this payload''s positions follow.');
        EXECUTE format('COMMENT ON COLUMN pgfr_record.%I.payload IS %L', v_archive,
            'Positional jsonb array of every captured column value, per payload_schemas.columns for this row''s schema_id (§4.4).');

        EXECUTE format('COMMENT ON VIEW pgfr_record.%I IS %L', v_view, format(
            'Typed projection of %s, reconstructed from its archive (§4.3.2).%s',
            v_row.source_view, CASE WHEN v_row.notes IS NOT NULL THEN ' ' || v_row.notes ELSE '' END
        ));

        FOR v_col IN
            SELECT column_name, class, reset_column FROM pgfr_record.column_classes WHERE source_view = v_row.source_view
        LOOP
            EXECUTE format('COMMENT ON COLUMN pgfr_record.%I.%I IS %L', v_view, v_col.column_name, format(
                'class: %s%s', v_col.class,
                CASE WHEN v_col.reset_column IS NOT NULL THEN format('; reset: %s', v_col.reset_column) ELSE '' END
            ));
        END LOOP;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION pgfr_record.generate_comments() IS
    'Generates COMMENT ON for every archive table, presentation view, and column, derived from the manifest and column_classes (§4.5) -- so psql \d+ is self-documenting. Regenerate whenever the manifest or column_classes changes; safe to re-run.';
