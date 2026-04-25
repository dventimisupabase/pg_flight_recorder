-- =============================================================================
-- pgfr_analyze: xmin horizon readers
-- =============================================================================
-- Two reader functions exposed to operators:
--   xmin_horizon_history(p_start, p_end) — timeline of xmin horizon ages and
--     dominant-holder JSONB detail across snapshots in a window.
--   current_xmin_horizon_holder() — quick-answer view; one row from the latest
--     snapshot, or zero rows if no holder.
--
-- Both read directly from pgfr_record.snapshots (no sidecar joins, no
-- partition trickery). The dominant-holder JSONB carries source-specific
-- fields populated by the collector.
-- =============================================================================

CREATE OR REPLACE FUNCTION pgfr_analyze.xmin_horizon_history(
    p_start TIMESTAMPTZ,
    p_end   TIMESTAMPTZ
)
RETURNS TABLE (
    captured_at           TIMESTAMPTZ,
    xmin_data_horizon_age BIGINT,
    slot_catalog_xmin_age BIGINT,
    xmin_any_horizon_age  BIGINT,
    source                TEXT,
    holder                JSONB
)
LANGUAGE sql STABLE AS $$
    SELECT s.captured_at,
           s.xmin_data_horizon_age,
           s.slot_catalog_xmin_age,
           s.xmin_any_horizon_age,
           s.xmin_horizon_detail->>'source'   AS source,
           s.xmin_horizon_detail->'holder'    AS holder
    FROM pgfr_record.snapshots s
    WHERE s.captured_at BETWEEN p_start AND p_end
      AND (s.xmin_data_horizon_age IS NOT NULL OR s.slot_catalog_xmin_age IS NOT NULL)
    ORDER BY s.captured_at DESC;
$$;
COMMENT ON FUNCTION pgfr_analyze.xmin_horizon_history(TIMESTAMPTZ, TIMESTAMPTZ) IS
'Timeline of xmin horizon ages + dominant-holder JSONB detail across snapshots '
'in a window. Reads pgfr_record.snapshots directly; no sidecars.';

CREATE OR REPLACE FUNCTION pgfr_analyze.current_xmin_horizon_holder()
RETURNS TABLE (
    captured_at           TIMESTAMPTZ,
    xmin_data_horizon_age BIGINT,
    slot_catalog_xmin_age BIGINT,
    source                TEXT,
    holder                JSONB
)
LANGUAGE sql STABLE AS $$
    SELECT s.captured_at,
           s.xmin_data_horizon_age,
           s.slot_catalog_xmin_age,
           s.xmin_horizon_detail->>'source' AS source,
           s.xmin_horizon_detail->'holder'  AS holder
    FROM pgfr_record.snapshots s
    WHERE s.xmin_horizon_detail IS NOT NULL
    ORDER BY s.captured_at DESC
    LIMIT 1;
$$;
COMMENT ON FUNCTION pgfr_analyze.current_xmin_horizon_holder() IS
'Quick-answer reader: returns zero rows on a healthy cluster, otherwise one '
'row for the dominant xmin holder at the latest snapshot.';
