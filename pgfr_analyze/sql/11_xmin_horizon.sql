-- =============================================================================
-- pgfr_analyze: xmin horizon readers (blueprint §6.2, §6.3)
-- =============================================================================
-- Two reader functions exposed to operators:
--   xmin_horizon_history(p_start, p_end) — timeline of holders + per-source
--     statuses; pushes down sample_ts predicate so partition pruning works.
--   current_xmin_horizon_holder() — quick-answer view; one row per dominant
--     holder, zero rows on a healthy cluster.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- xmin_horizon_history(p_start, p_end)
-- ---------------------------------------------------------------------------
-- Returns a UNION ALL across the three holder sidecars and the replication
-- backend_xmin column on replication_snapshots, joined to snapshots, with
-- per-source status / truncated columns and a horizon_type disambiguator
-- ('data' | 'catalog' | 'both') so 'slot' rows can be distinguished by
-- whether they elevate the data horizon, catalog horizon, or both.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION pgfr_analyze.xmin_horizon_history(
    p_start TIMESTAMPTZ,
    p_end   TIMESTAMPTZ
)
RETURNS TABLE (
    captured_at             TIMESTAMPTZ,
    xmin_data_horizon_age   BIGINT,
    slot_catalog_xmin_age   BIGINT,
    xmin_any_horizon_age    BIGINT,
    activity_status         TEXT,
    slot_status             TEXT,
    prepared_status         TEXT,
    replication_status      TEXT,
    activity_truncated      INTEGER,
    slot_truncated          INTEGER,
    prepared_truncated      INTEGER,
    source                  TEXT,
    horizon_type            TEXT,
    xmin_age                BIGINT,
    holder_key              TEXT,
    holder_detail           TEXT
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_ts_start INTEGER := extract(epoch from (p_start - pgfr_record.epoch()))::integer;
    v_ts_end   INTEGER := extract(epoch from (p_end   - pgfr_record.epoch()))::integer;
BEGIN
    RETURN QUERY
    -- ACTIVITY rows
    SELECT s.captured_at,
           s.xmin_data_horizon_age, s.slot_catalog_xmin_age, s.xmin_any_horizon_age,
           s.xmin_activity_collection_status, s.xmin_slot_collection_status,
           s.xmin_prepared_collection_status, s.xmin_replication_collection_status,
           s.xmin_activity_truncated_count, s.xmin_slot_truncated_count, s.xmin_prepared_truncated_count,
           'activity'::text AS source,
           'data'::text AS horizon_type,
           h.backend_xmin_age AS xmin_age,
           h.pid::text AS holder_key,
           format('app=%s user=%s db=%s state=%s query=%s',
                  COALESCE(h.application_name,''), COALESCE(h.usename,''),
                  COALESCE(h.datname,''), COALESCE(h.state,''),
                  COALESCE(h.query_preview,'')) AS holder_detail
    FROM pgfr_record.xmin_activity_holders h
    JOIN pgfr_record.snapshots s ON s.id = h.snapshot_id
    WHERE h.sample_ts BETWEEN v_ts_start AND v_ts_end                  -- partition pruning
      AND s.captured_at BETWEEN p_start AND p_end

    UNION ALL
    -- SLOT rows (horizon_type discriminates which horizon the slot elevates)
    SELECT s.captured_at,
           s.xmin_data_horizon_age, s.slot_catalog_xmin_age, s.xmin_any_horizon_age,
           s.xmin_activity_collection_status, s.xmin_slot_collection_status,
           s.xmin_prepared_collection_status, s.xmin_replication_collection_status,
           s.xmin_activity_truncated_count, s.xmin_slot_truncated_count, s.xmin_prepared_truncated_count,
           'slot'::text AS source,
           CASE
               WHEN h.xmin_age IS NOT NULL AND h.catalog_xmin_age IS NOT NULL THEN 'both'
               WHEN h.xmin_age IS NOT NULL THEN 'data'
               WHEN h.catalog_xmin_age IS NOT NULL THEN 'catalog'
               ELSE NULL
           END AS horizon_type,
           GREATEST(COALESCE(h.xmin_age, 0), COALESCE(h.catalog_xmin_age, 0)) AS xmin_age,
           h.slot_name AS holder_key,
           format('type=%s active=%s wal_status=%s%s%s',
                  COALESCE(h.slot_type,''), h.active, COALESCE(h.wal_status,''),
                  CASE WHEN h.invalidation_reason IS NOT NULL
                       THEN ' invalidation_reason=' || h.invalidation_reason ELSE '' END,
                  CASE WHEN h.conflicting THEN ' conflicting=true' ELSE '' END
                 ) AS holder_detail
    FROM pgfr_record.xmin_slot_holders h
    JOIN pgfr_record.snapshots s ON s.id = h.snapshot_id
    WHERE h.sample_ts BETWEEN v_ts_start AND v_ts_end                  -- partition pruning
      AND s.captured_at BETWEEN p_start AND p_end

    UNION ALL
    -- PREPARED rows
    SELECT s.captured_at,
           s.xmin_data_horizon_age, s.slot_catalog_xmin_age, s.xmin_any_horizon_age,
           s.xmin_activity_collection_status, s.xmin_slot_collection_status,
           s.xmin_prepared_collection_status, s.xmin_replication_collection_status,
           s.xmin_activity_truncated_count, s.xmin_slot_truncated_count, s.xmin_prepared_truncated_count,
           'prepared'::text AS source,
           'data'::text AS horizon_type,
           h.prepared_xmin_age AS xmin_age,
           h.gid AS holder_key,
           format('owner=%s database=%s prepared_at=%s',
                  COALESCE(h.owner,''), COALESCE(h.database,''), h.prepared_at) AS holder_detail
    FROM pgfr_record.xmin_prepared_holders h
    JOIN pgfr_record.snapshots s ON s.id = h.snapshot_id
    WHERE h.sample_ts BETWEEN v_ts_start AND v_ts_end                  -- partition pruning
      AND s.captured_at BETWEEN p_start AND p_end

    UNION ALL
    -- REPLICATION rows (physical walsenders only — logicals routed via slot)
    SELECT s.captured_at,
           s.xmin_data_horizon_age, s.slot_catalog_xmin_age, s.xmin_any_horizon_age,
           s.xmin_activity_collection_status, s.xmin_slot_collection_status,
           s.xmin_prepared_collection_status, s.xmin_replication_collection_status,
           s.xmin_activity_truncated_count, s.xmin_slot_truncated_count, s.xmin_prepared_truncated_count,
           'replication'::text AS source,
           'data'::text AS horizon_type,
           r.backend_xmin_age AS xmin_age,
           COALESCE(r.application_name, r.pid::text) AS holder_key,
           format('pid=%s addr=%s sync_state=%s slot=%s',
                  r.pid, r.client_addr, COALESCE(r.sync_state,''), COALESCE(r.slot_name,''))
                  AS holder_detail
    FROM pgfr_record.replication_snapshots r
    JOIN pgfr_record.snapshots s ON s.id = r.snapshot_id
    WHERE s.captured_at BETWEEN p_start AND p_end
      AND r.backend_xmin IS NOT NULL
      AND NOT r.is_logical_walsender

    ORDER BY captured_at DESC, xmin_age DESC NULLS LAST;
END;
$$;
COMMENT ON FUNCTION pgfr_analyze.xmin_horizon_history(TIMESTAMPTZ, TIMESTAMPTZ) IS
'Timeline of xmin-horizon holders within a window. UNION ALL across three '
'holder sidecars and replication_snapshots; horizon_type disambiguates slot '
'rows (data/catalog/both). Pushes down sample_ts predicate for partition pruning.';

-- ---------------------------------------------------------------------------
-- current_xmin_horizon_holder()
-- ---------------------------------------------------------------------------
-- Returns zero rows on a healthy cluster (no holder), or one row representing
-- the dominant holder by §6.1 cross-source priority slot > prepared >
-- activity > replication. Dominant source is whichever has age equal to
-- xmin_data_horizon_age or slot_catalog_xmin_age.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION pgfr_analyze.current_xmin_horizon_holder()
RETURNS TABLE (
    captured_at       TIMESTAMPTZ,
    source            TEXT,
    horizon_type      TEXT,
    xmin_age          BIGINT,
    holder_key        TEXT,
    database          TEXT,
    application_name  TEXT,
    recommendation    TEXT,
    collection_status TEXT
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_snap RECORD;
    v_dom  TEXT;
BEGIN
    SELECT id, captured_at,
           xmin_data_horizon_age, slot_catalog_xmin_age,
           activity_xmin_age, slot_xmin_age, replication_xmin_age, prepared_xmin_age,
           xmin_activity_collection_status, xmin_slot_collection_status,
           xmin_prepared_collection_status, xmin_replication_collection_status
      INTO v_snap
    FROM pgfr_record.snapshots
    WHERE xmin_data_horizon_age IS NOT NULL OR slot_catalog_xmin_age IS NOT NULL
    ORDER BY captured_at DESC
    LIMIT 1;

    -- Healthy cluster (no holder): return zero rows.
    IF v_snap.id IS NULL THEN
        RETURN;
    END IF;

    -- Cross-source tie-breaking: slot > prepared > activity > replication.
    v_dom := CASE
        WHEN v_snap.slot_xmin_age IS NOT NULL
             AND v_snap.slot_xmin_age = v_snap.xmin_data_horizon_age THEN 'slot'
        WHEN v_snap.prepared_xmin_age IS NOT NULL
             AND v_snap.prepared_xmin_age = v_snap.xmin_data_horizon_age THEN 'prepared'
        WHEN v_snap.activity_xmin_age IS NOT NULL
             AND v_snap.activity_xmin_age = v_snap.xmin_data_horizon_age THEN 'activity'
        WHEN v_snap.replication_xmin_age IS NOT NULL
             AND v_snap.replication_xmin_age = v_snap.xmin_data_horizon_age THEN 'replication'
        WHEN v_snap.slot_catalog_xmin_age IS NOT NULL THEN 'slot'
        ELSE NULL
    END;

    IF v_dom IS NULL THEN
        RETURN;
    END IF;

    IF v_dom = 'activity' THEN
        RETURN QUERY
        SELECT v_snap.captured_at, 'activity'::text, 'data'::text,
               h.backend_xmin_age, h.pid::text, h.datname, h.application_name,
               format('PID %s state=%s query=%s', h.pid, COALESCE(h.state,''), COALESCE(h.query_preview,''))::text,
               v_snap.xmin_activity_collection_status
        FROM pgfr_record.xmin_activity_holders h
        WHERE h.snapshot_id = v_snap.id
        ORDER BY h.backend_xmin_age DESC, h.pid ASC
        LIMIT 1;
    ELSIF v_dom = 'slot' THEN
        RETURN QUERY
        SELECT v_snap.captured_at, 'slot'::text,
               (CASE
                  WHEN h.xmin_age IS NOT NULL AND h.catalog_xmin_age IS NOT NULL THEN 'both'
                  WHEN h.xmin_age IS NOT NULL THEN 'data'
                  WHEN h.catalog_xmin_age IS NOT NULL THEN 'catalog'
                  ELSE NULL
               END)::text,
               GREATEST(COALESCE(h.xmin_age,0), COALESCE(h.catalog_xmin_age,0)),
               h.slot_name::text, h.database::text, NULL::text,
               format('slot=%s type=%s active=%s', h.slot_name, COALESCE(h.slot_type,''), h.active)::text,
               v_snap.xmin_slot_collection_status
        FROM pgfr_record.xmin_slot_holders h
        WHERE h.snapshot_id = v_snap.id
        ORDER BY GREATEST(COALESCE(h.xmin_age,0), COALESCE(h.catalog_xmin_age,0)) DESC,
                 h.slot_name ASC
        LIMIT 1;
    ELSIF v_dom = 'prepared' THEN
        RETURN QUERY
        SELECT v_snap.captured_at, 'prepared'::text, 'data'::text,
               h.prepared_xmin_age, h.gid::text, h.database, NULL::text,
               format('gid=%s owner=%s', h.gid, COALESCE(h.owner,''))::text,
               v_snap.xmin_prepared_collection_status
        FROM pgfr_record.xmin_prepared_holders h
        WHERE h.snapshot_id = v_snap.id
        ORDER BY h.prepared_xmin_age DESC, h.gid ASC
        LIMIT 1;
    ELSIF v_dom = 'replication' THEN
        RETURN QUERY
        SELECT v_snap.captured_at, 'replication'::text, 'data'::text,
               r.backend_xmin_age, COALESCE(r.application_name, r.pid::text)::text,
               NULL::text, r.application_name,
               format('standby=%s pid=%s slot=%s', COALESCE(r.application_name,''), r.pid, COALESCE(r.slot_name,''))::text,
               v_snap.xmin_replication_collection_status
        FROM pgfr_record.replication_snapshots r
        WHERE r.snapshot_id = v_snap.id
          AND r.backend_xmin IS NOT NULL
          AND NOT r.is_logical_walsender
        ORDER BY r.backend_xmin_age DESC, r.pid ASC
        LIMIT 1;
    END IF;
END;
$$;
COMMENT ON FUNCTION pgfr_analyze.current_xmin_horizon_holder() IS
'Quick-answer reader: returns zero rows on a healthy cluster, otherwise '
'one row for the dominant xmin holder per cross-source tie-breaking '
'(slot > prepared > activity > replication). horizon_type disambiguates '
'slot rows.';
