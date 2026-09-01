-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- Definitional helpers (§4.5): mechanical, deterministic, threshold-free
-- functions over recorded facts. Nothing here has an opinion; everything
-- here has exactly one correct answer, which is the agent test (§1
-- invariant 2, acceptance criterion 11).

-- state_as_of(): LOCF reconstruction (§6). Bounded by the containing
-- anchor without a separate last-anchor tracking table, using the same
-- reasoning as run_tier()'s anchor detection: anchor cadence equals
-- partition width by manifest construction, so "the containing anchor"
-- for time t is simply the start of t's own partition -- never search
-- further back than that.
--
-- Returns SETOF record (not a fixed shape) because each source_view has
-- a different column set; callers supply it via a column-definition
-- list, the standard PostgreSQL idiom for dynamically-shaped set-
-- returning functions, e.g.:
--
--   SELECT * FROM pgfr_record.state_as_of('pg_catalog.pg_stat_database', now())
--       AS t(captured_at timestamptz, datid oid, datname name, ...);
--
-- \d pgfr_record.v_pg_stat_database shows the exact column list to use.
CREATE OR REPLACE FUNCTION pgfr_record.state_as_of(p_source_view text, p_t timestamptz)
RETURNS SETOF record
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_manifest record;
    v_view     text;
    v_unit     text;
    v_bucket   timestamptz;
    v_key_cols text;
    v_sql      text;
BEGIN
    SELECT * INTO v_manifest FROM pgfr_record.manifest WHERE source_view = p_source_view;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'pgfr_record.state_as_of: unknown source_view %', p_source_view;
    END IF;

    v_view   := 'pgfr_record.v_' || pgfr_record._short_name(p_source_view);
    v_unit   := pgfr_record._partition_unit(v_manifest.retention);
    v_bucket := date_trunc(v_unit, p_t);

    IF v_manifest.keyless OR array_length(v_manifest.natural_key, 1) IS NULL THEN
        -- Keyless or singleton: one identity. Every capture of a
        -- non-debounced target (true of every current keyless/singleton
        -- row) is already a complete snapshot, so LOCF is just "the
        -- latest capture at or before t".
        v_sql := format(
            'SELECT * FROM %s WHERE captured_at = (SELECT max(captured_at) FROM %s WHERE captured_at <= $1 AND captured_at >= $2)',
            v_view, v_view
        );
    ELSE
        SELECT string_agg(quote_ident(k), ', ') INTO v_key_cols FROM unnest(v_manifest.natural_key) k;
        v_sql := format(
            'SELECT DISTINCT ON (%s) * FROM %s WHERE captured_at <= $1 AND captured_at >= $2 ORDER BY %s, captured_at DESC',
            v_key_cols, v_view, v_key_cols
        );
    END IF;

    RETURN QUERY EXECUTE v_sql USING p_t, v_bucket;
END;
$$;

COMMENT ON FUNCTION pgfr_record.state_as_of(text, timestamptz) IS
    'LOCF reconstruction (§6): for each key, the most recent sample at or before t, never searching further back than the start of t''s own partition (anchor cadence = partition width, by manifest construction). Returns SETOF record -- supply a column-definition list matching \d pgfr_record.v_<short_name>, e.g. state_as_of(''pg_catalog.pg_stat_database'', now()) AS t(captured_at timestamptz, datid oid, ...).';

-- latest_state(): the true current state of a non-debounced target, as
-- distinct from state_as_of()'s per-key LOCF. A debounce = false target
-- (every row of Group A/C) fully recaptures its entire current row set
-- on every tick, with one captured_at shared by the whole tick (the
-- single-stamp rule, §5); LOCF is the wrong tool here, because a key
-- that has since vanished (a backend that disconnected, a lock that was
-- released) has no future row to ever supersede its last one, so
-- state_as_of() would keep returning that stale row as if it were still
-- current for as long as it remains within the partition bound.
-- latest_state() instead returns every row at the single most recent
-- captured_at: exactly the true current set, whether the target is
-- keyed or keyless, since a non-debounced tick is a full snapshot either
-- way. Confirmed against a live install: a pg_cron-spawned backend,
-- captured once mid-execution, otherwise reads as a false long-running
-- transaction under state_as_of() for the rest of that partition.
CREATE OR REPLACE FUNCTION pgfr_record.latest_state(p_source_view text, p_t timestamptz DEFAULT clock_timestamp())
RETURNS SETOF record
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_manifest record;
    v_view     text;
    v_unit     text;
    v_bucket   timestamptz;
    v_sql      text;
BEGIN
    SELECT * INTO v_manifest FROM pgfr_record.manifest WHERE source_view = p_source_view;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'pgfr_record.latest_state: unknown source_view %', p_source_view;
    END IF;
    IF v_manifest.debounce THEN
        RAISE EXCEPTION 'pgfr_record.latest_state: % is debounced; a missing row means unchanged, not absent -- use state_as_of() instead', p_source_view;
    END IF;

    v_view   := 'pgfr_record.v_' || pgfr_record._short_name(p_source_view);
    v_unit   := pgfr_record._partition_unit(v_manifest.retention);
    v_bucket := date_trunc(v_unit, p_t);

    v_sql := format(
        'SELECT * FROM %s WHERE captured_at = (SELECT max(captured_at) FROM %s WHERE captured_at <= $1 AND captured_at >= $2)',
        v_view, v_view
    );

    RETURN QUERY EXECUTE v_sql USING p_t, v_bucket;
END;
$$;

COMMENT ON FUNCTION pgfr_record.latest_state(text, timestamptz) IS
    'The true current state of a non-debounced (Group A/C) target as of t: every row at the single most recent captured_at within t''s partition, never a stale per-key carry-forward. Raises if called on a debounced target, where a missing row means unchanged rather than gone and state_as_of() is the correct choice instead. Returns SETOF record -- same column-definition-list calling convention as state_as_of().';

-- resolve_relation() / resolve_index() (§4.5): join through the catalog
-- identity dimension as of t, OID-reuse-safe by construction. Mechanically
-- identical -- pg_class covers every relkind, including indexes -- named
-- separately only so a caller resolving an indexrelid doesn't have to
-- know that.
-- DROP + CREATE, not CREATE OR REPLACE: PostgreSQL refuses to change a
-- RETURNS TABLE shape in place (same restriction as presentation views,
-- §4.3.2), and relfrozenxid/relminmxid/reltuples were added to
-- src_catalog_identity after these functions' initial shape shipped.
DROP FUNCTION IF EXISTS pgfr_record.resolve_index(oid, timestamptz);
DROP FUNCTION IF EXISTS pgfr_record.resolve_relation(oid, timestamptz);

CREATE FUNCTION pgfr_record.resolve_relation(p_oid oid, p_t timestamptz DEFAULT clock_timestamp())
RETURNS TABLE(captured_at timestamptz, oid oid, relname name, relnamespace oid, nspname name, relkind "char", relispartition boolean, relfrozenxid xid, relminmxid xid, reltuples real)
LANGUAGE sql STABLE AS $$
    SELECT * FROM pgfr_record.state_as_of('pgfr_record.src_catalog_identity', p_t)
        AS t(captured_at timestamptz, oid oid, relname name, relnamespace oid, nspname name, relkind "char", relispartition boolean, relfrozenxid xid, relminmxid xid, reltuples real)
    WHERE t.oid = p_oid;
$$;

COMMENT ON FUNCTION pgfr_record.resolve_relation(oid, timestamptz) IS
    'What relation was this OID, as of t? Survives OID reuse across DROP/CREATE by reading pgfr_record.src_catalog_identity''s history (§4.5) rather than the live catalog. Defaults t to now(), matching a live lookup when no historical point is specified. Carries relfrozenxid/relminmxid/reltuples for per-relation XID/MultiXID wraparound distance tracking.';

CREATE FUNCTION pgfr_record.resolve_index(p_oid oid, p_t timestamptz DEFAULT clock_timestamp())
RETURNS TABLE(captured_at timestamptz, oid oid, relname name, relnamespace oid, nspname name, relkind "char", relispartition boolean, relfrozenxid xid, relminmxid xid, reltuples real)
LANGUAGE sql STABLE AS $$
    SELECT * FROM pgfr_record.resolve_relation(p_oid, p_t);
$$;

COMMENT ON FUNCTION pgfr_record.resolve_index(oid, timestamptz) IS
    'What index was this OID, as of t? Identical mechanism to resolve_relation() -- pg_class covers every relkind -- named separately for callers resolving an indexrelid.';
