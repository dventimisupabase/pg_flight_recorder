-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- Collector core (§5): one function per tier invocation, run by its own
-- pg_cron job (scheduling itself is milestone 5's enable()). Pseudocode
-- in §5, corrected during implementation planning: the ledger is a single
-- append per run (see 04_ledger.sql), and SET LOCAL statement_timeout is
-- set explicitly on every loop iteration rather than assumed to auto-
-- revert on success.

CREATE OR REPLACE FUNCTION pgfr_record._interval_ms_literal(p_interval interval)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT (extract(epoch FROM p_interval) * 1000)::bigint::text || 'ms';
$$;
COMMENT ON FUNCTION pgfr_record._interval_ms_literal(interval) IS
    'Renders an interval as a GUC-parseable millisecond literal (e.g. ''250ms''), for SET LOCAL statement_timeout/lock_timeout, whose unit-suffixed value syntax does not accept a general interval literal.';

-- Placeholder defaults, safely under each tier's interval (fast=1m,
-- medium/on_change=5m, slow=15m per §9's default profile), pending
-- milestone 5's profiles mechanism making these operator-configurable
-- rather than hardcoded.
CREATE OR REPLACE FUNCTION pgfr_record._default_job_timeout(p_tier text)
RETURNS interval
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE p_tier
        WHEN 'fast'      THEN interval '45 seconds'
        WHEN 'medium'    THEN interval '4 minutes'
        WHEN 'slow'      THEN interval '12 minutes'
        WHEN 'on_change' THEN interval '4 minutes'
    END;
$$;

-- run_tier(): the collector. One captured_at (v_t0) shared by every
-- target in the tier, so cross-view joins at equal captured_at (pg_locks
-- ⋈ pg_stat_activity) are exact (§5's single-stamp rule). Each target's
-- capture is a single dynamic INSERT ... SELECT wrapped in its own
-- EXCEPTION block (a subtransaction): a lock-queue hang, permission
-- failure, or error on one target cannot fail the tier, and kill -9 of
-- the collector backend at any point leaves no partial capture visible.
CREATE OR REPLACE FUNCTION pgfr_record.run_tier(
    p_tier          text,
    p_lock_timeout  interval DEFAULT interval '100 ms',
    p_job_timeout   interval DEFAULT NULL,
    p_section_timeout interval DEFAULT interval '250 ms'
)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_job_timeout interval := coalesce(p_job_timeout, pgfr_record._default_job_timeout(p_tier));
    v_t0          timestamptz := clock_timestamp();
    v_run_id      bigint;
    v_target      record;
    v_started_at  timestamptz;
    v_unit        text;
    v_bucket      timestamptz;
    v_anchor_due  boolean;
    v_sql         text;
    v_rows        int;
BEGIN
    EXECUTE format('SET LOCAL lock_timeout = %L', pgfr_record._interval_ms_literal(p_lock_timeout));
    EXECUTE format('SET LOCAL statement_timeout = %L', pgfr_record._interval_ms_literal(v_job_timeout));

    v_run_id := nextval(pg_get_serial_sequence('pgfr_record.ledger_runs', 'run_id'));

    FOR v_target IN
        SELECT * FROM pgfr_record.capture_plan WHERE cadence_tier = p_tier ORDER BY plan_order
    LOOP
        v_started_at := clock_timestamp();
        BEGIN
            EXECUTE format('SET LOCAL statement_timeout = %L', pgfr_record._interval_ms_literal(p_section_timeout));

            v_anchor_due := false;
            IF v_target.debounce THEN
                -- Stateless anchor detection (§6): anchor cadence equals
                -- partition width by manifest construction, so "anchor
                -- due" reduces to "the current partition has no rows
                -- yet" -- no separate last-anchor tracking table needed,
                -- and it self-heals if a prior anchor attempt failed.
                v_unit := pgfr_record._partition_unit(v_target.retention);
                v_bucket := date_trunc(v_unit, v_t0);
                EXECUTE format('SELECT NOT EXISTS (SELECT 1 FROM pgfr_record.%I WHERE captured_at >= $1)', v_target.archive_table)
                INTO v_anchor_due USING v_bucket;
            END IF;

            IF v_target.debounce AND NOT v_anchor_due THEN
                -- §6 anti-join: "changed" = (key_hash, row_hash) does not
                -- match this key's most recent capture within the
                -- current anchor window. A LEFT JOIN LATERAL against the
                -- most recent same-key_hash row (not a bare NOT IN)
                -- correctly re-appends a value that fluctuates back to
                -- something it held two samples ago, rather than
                -- silently treating that as unchanged.
                v_sql := format(
                    'INSERT INTO pgfr_record.%I (captured_at, key, key_hash, row_hash, schema_id, payload)
                     SELECT $1, k.key, k.key_hash, k.row_hash, %L::smallint, k.payload
                     FROM (%s) k
                     LEFT JOIN LATERAL (
                         SELECT a.row_hash FROM pgfr_record.%I a
                         WHERE a.key_hash = k.key_hash AND a.captured_at >= $2 AND a.captured_at < $1
                         ORDER BY a.captured_at DESC LIMIT 1
                     ) prev ON true
                     WHERE prev.row_hash IS DISTINCT FROM k.row_hash',
                    v_target.archive_table, v_target.schema_id, v_target.capture_select_sql, v_target.archive_table
                );
                EXECUTE v_sql USING v_t0, v_bucket;
            ELSE
                v_sql := format(
                    'INSERT INTO pgfr_record.%I (captured_at, key, key_hash, row_hash, schema_id, payload)
                     SELECT $1, k.key, k.key_hash, k.row_hash, %L::smallint, k.payload FROM (%s) k',
                    v_target.archive_table, v_target.schema_id, v_target.capture_select_sql
                );
                EXECUTE v_sql USING v_t0;
            END IF;
            GET DIAGNOSTICS v_rows = ROW_COUNT;

            INSERT INTO pgfr_record.ledger_captures
                (run_id, source_view, outcome, rows_appended, was_anchor, visibility, captured_at, elapsed)
            VALUES
                (v_run_id, v_target.source_view, 'ok', v_rows, (v_target.debounce AND v_anchor_due), 'full', v_t0, clock_timestamp() - v_started_at);
        EXCEPTION
            WHEN lock_not_available THEN
                INSERT INTO pgfr_record.ledger_captures (run_id, source_view, outcome, captured_at, elapsed)
                VALUES (v_run_id, v_target.source_view, 'lock_timeout', v_t0, clock_timestamp() - v_started_at);
            WHEN query_canceled THEN
                INSERT INTO pgfr_record.ledger_captures (run_id, source_view, outcome, captured_at, elapsed)
                VALUES (v_run_id, v_target.source_view, 'timeout', v_t0, clock_timestamp() - v_started_at);
            WHEN insufficient_privilege THEN
                INSERT INTO pgfr_record.ledger_captures (run_id, source_view, outcome, visibility, captured_at, elapsed)
                VALUES (v_run_id, v_target.source_view, 'denied', 'degraded', v_t0, clock_timestamp() - v_started_at);
            WHEN others THEN
                INSERT INTO pgfr_record.ledger_captures (run_id, source_view, outcome, detail, captured_at, elapsed)
                VALUES (v_run_id, v_target.source_view, 'error', SQLERRM, v_t0, clock_timestamp() - v_started_at);
        END;
    END LOOP;

    -- Single append, not open-then-close (§8.2): both timestamps are
    -- already known, so there is nothing to update later.
    INSERT INTO pgfr_record.ledger_runs (run_id, tier, captured_at, finished_at)
    OVERRIDING SYSTEM VALUE VALUES (v_run_id, p_tier, v_t0, clock_timestamp());
END;
$$;

COMMENT ON FUNCTION pgfr_record.run_tier(text, interval, interval, interval) IS
    'Runs one tier''s capture_plan targets under one shared captured_at (§5). Each target executes in its own EXCEPTION block (ok/timeout/lock_timeout/denied/error), recorded in ledger_captures; one target''s failure cannot fail the tier. Timeout arguments default to placeholder values pending milestone 5''s profiles.';
