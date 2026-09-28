-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- Query dictionary: deduplicated queryid -> query text. pg_stat_statements
-- is a debounced Group B target, so its full row (including query text) is
-- recaptured every tick any of its counters change -- the manifest's own
-- notes call this an "analyze-side dictionary over queryid -> text", i.e.
-- this table was always meant to live here, not in pgfr_record.

CREATE TABLE IF NOT EXISTS pgfr_analyze.query_dict (
    queryid    bigint  NOT NULL,
    dbid       oid     NOT NULL,
    userid     oid     NOT NULL,
    toplevel   boolean NOT NULL,
    query_text text    NOT NULL,
    first_seen timestamptz NOT NULL,
    last_seen  timestamptz NOT NULL,
    PRIMARY KEY (queryid, dbid, userid, toplevel)
);

COMMENT ON TABLE pgfr_analyze.query_dict IS
    'Deduplicated (queryid, dbid, userid, toplevel) -> query text, refreshed from pgfr_record.v_pg_stat_statements via refresh_query_dict(). Lets analyze-side readers get query text without re-scanning the full archive.';

CREATE OR REPLACE FUNCTION pgfr_analyze.refresh_query_dict()
RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
    v_n int;
BEGIN
    WITH agg AS (
        SELECT queryid, dbid, userid, toplevel,
               min(captured_at) AS first_seen, max(captured_at) AS last_seen
        FROM pgfr_record.v_pg_stat_statements
        GROUP BY queryid, dbid, userid, toplevel
    ),
    upserted AS (
        INSERT INTO pgfr_analyze.query_dict (queryid, dbid, userid, toplevel, query_text, first_seen, last_seen)
        SELECT agg.queryid, agg.dbid, agg.userid, agg.toplevel, latest.query, agg.first_seen, agg.last_seen
        FROM agg
        JOIN LATERAL (
            SELECT query
            FROM pgfr_record.v_pg_stat_statements v
            WHERE v.queryid = agg.queryid AND v.dbid = agg.dbid AND v.userid = agg.userid AND v.toplevel = agg.toplevel
            ORDER BY v.captured_at DESC
            LIMIT 1
        ) latest ON true
        ON CONFLICT (queryid, dbid, userid, toplevel) DO UPDATE
            SET query_text = excluded.query_text,
                last_seen  = GREATEST(pgfr_analyze.query_dict.last_seen, excluded.last_seen)
            -- first_seen is intentionally never updated on conflict: it
            -- must not advance just because retention dropped the archive
            -- rows that would let it be recomputed from scratch.
        RETURNING 1
    )
    SELECT count(*) INTO v_n FROM upserted;

    RETURN v_n;
END;
$$;

COMMENT ON FUNCTION pgfr_analyze.refresh_query_dict() IS
    'Upserts pgfr_analyze.query_dict from every (queryid, dbid, userid, toplevel) currently in pgfr_record.v_pg_stat_statements. Returns the number of rows inserted or updated. Safe to re-run; writes only to pgfr_analyze.query_dict.';
