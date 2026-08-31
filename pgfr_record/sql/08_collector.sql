-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- Collector core (§5): one function per tier invocation, run by its own
-- pg_cron job (scheduling itself is milestone 5's enable()).
--
-- Corrected during implementation, beyond the pseudocode's original
-- draft, in two ways:
--   1. The ledger is a single append per run (see 04_ledger.sql), not
--      open-then-close.
--   2. The "arming gotcha": confirmed against a live server that
--      statement_timeout's enforcement timer is armed once, at the start
--      of the current top-level statement, and is NOT re-armed by a
--      SET/SET LOCAL statement_timeout executed from inside that same
--      top-level statement's own execution -- including via a nested
--      EXECUTE inside a called function. Since run_tier() is itself
--      invoked as one top-level call, no SET LOCAL statement_timeout
--      inside this function body can ever preemptively cancel anything
--      about its own execution. lock_timeout does not share this
--      defect -- a lock wait is checked dynamically against whatever
--      lock_timeout is currently in effect, confirmed against a live
--      server -- so it remains a real, per-target bound. See §5's
--      "arming gotcha" for the full writeup and the resulting design:
--      lock_timeout (real, per target), a cooperative job_timeout
--      deadline check (real, stops the tier from starting further
--      targets once its budget is spent), and a genuine caller-side
--      SET statement_timeout as the backstop against a truly hung
--      target (apply_profile() dispatches "SET statement_timeout = ...;
--      SELECT run_tier(...)" as two top-level statements for exactly
--      this reason). A standalone per-target section_timeout was
--      dropped entirely: it cannot be implemented without dispatching
--      each target as its own top-level statement, which would need a
--      dependency this design deliberately does not take on.

CREATE OR REPLACE FUNCTION pgfr_record._interval_ms_literal(p_interval interval)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT (extract(epoch FROM p_interval) * 1000)::bigint::text || 'ms';
$$;
COMMENT ON FUNCTION pgfr_record._interval_ms_literal(interval) IS
    'Renders an interval as a GUC-parseable millisecond literal (e.g. ''250ms''), for SET LOCAL statement_timeout/lock_timeout, whose unit-suffixed value syntax does not accept a general interval literal.';

-- Placeholder default, safely under each tier's interval (fast=1m,
-- medium/on_change=5m, slow=15m per §9's default profile), used only
-- when run_tier() is called without an explicit p_job_timeout (e.g.
-- direct/manual invocation). Real operation goes through profiles
-- (13_profiles.sql), which always supplies one explicitly.
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
    p_job_timeout   interval DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_job_timeout       interval := coalesce(p_job_timeout, pgfr_record._default_job_timeout(p_tier));
    v_t0                timestamptz := clock_timestamp();
    v_run_id            bigint;
    v_target            record;
    v_started_at        timestamptz;
    v_unit              text;
    v_bucket            timestamptz;
    v_anchor_due        boolean;
    v_sql               text;
    v_rows              int;
    v_orig_lock_timeout text := current_setting('lock_timeout');
    -- Rollup bucket-close (milestone 8).
    v_rollup_unit        text;
    v_missing_sql        text;
    v_rollup_bucket      timestamptz;
BEGIN
    v_run_id := nextval(pg_get_serial_sequence('pgfr_record.ledger_runs', 'run_id'));

    FOR v_target IN
        SELECT * FROM pgfr_record.capture_plan WHERE cadence_tier = p_tier ORDER BY plan_order
    LOOP
        -- Cooperative deadline check: cannot interrupt an
        -- already-running target (that needs the caller's own
        -- statement_timeout, see the comment atop this file), but it
        -- does stop the tier from *starting* any further target once
        -- job_timeout's budget is spent. A target skipped this way
        -- simply has no ledger_captures row for this run -- detectable
        -- by comparing against capture_plan, not a distinct outcome.
        EXIT WHEN clock_timestamp() - v_t0 >= v_job_timeout;

        v_started_at := clock_timestamp();
        BEGIN
            -- lock_timeout is checked dynamically at the moment a lock
            -- wait begins, not armed once like statement_timeout, so
            -- this genuinely bounds *this* target's lock wait.
            EXECUTE format('SET LOCAL lock_timeout = %L', pgfr_record._interval_ms_literal(p_lock_timeout));

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

        -- Rollup bucket-close (milestone 8): a second, sibling subtransaction
        -- from the raw capture above, not nested inside it -- the raw
        -- capture's BEGIN...EXCEPTION block has already completed and
        -- released its own subtransaction by this point, so a failure here
        -- can never roll back an already-succeeded raw capture. No ledger
        -- row either way (§8.2's append-only ledger governs the *record*;
        -- see the comment on health_check() for how rollup lag is surfaced
        -- instead): a bucket-close failure just gets retried on the next
        -- tick, the same self-healing posture as anchor detection and
        -- partition-detach retry.
        --
        -- Self-healing over a bounded range, not just "the bucket
        -- immediately before now": every closed bucket between the oldest
        -- one still covered by this target's own raw retention and the
        -- most recently closed one, that (a) has no rollup row yet and
        -- (b) has at least one raw row to aggregate (an empty candidate is
        -- left alone rather than recorded as a spurious "zero observed" --
        -- see 16_rollups.sql's header for why that distinction matters for
        -- the stat shape). A gap wider than retention simply falls outside
        -- this range and is silently, correctly abandoned: its source data
        -- is already gone, so there is nothing left to recover.
        IF v_target.rollup_table IS NOT NULL THEN
            BEGIN
                v_rollup_unit := pgfr_record._partition_unit(v_target.rollup_granularity);
                v_missing_sql := format(
                    'SELECT gs FROM generate_series(%L::timestamptz, %L::timestamptz, %L::interval) gs
                     WHERE NOT EXISTS (SELECT 1 FROM pgfr_record.%I r WHERE r.bucket_start = gs)
                       AND EXISTS (SELECT 1 FROM pgfr_record.%I a WHERE a.captured_at >= gs AND a.captured_at < gs + %L::interval)',
                    date_trunc(v_rollup_unit, v_t0 - v_target.retention),
                    date_trunc(v_rollup_unit, v_t0) - v_target.rollup_granularity,
                    v_target.rollup_granularity,
                    v_target.rollup_table,
                    v_target.archive_table,
                    v_target.rollup_granularity
                );
                FOR v_rollup_bucket IN EXECUTE v_missing_sql LOOP
                    BEGIN
                        EXECUTE v_target.rollup_close_sql USING v_rollup_bucket, v_rollup_bucket + v_target.rollup_granularity;
                    EXCEPTION WHEN others THEN
                        -- One bad bucket must not stop the catch-up loop
                        -- from attempting the others in this same run.
                        RAISE WARNING 'pgfr_record.run_tier: rollup close failed for % bucket %: %', v_target.source_view, v_rollup_bucket, SQLERRM;
                    END;
                END LOOP;
            EXCEPTION WHEN others THEN
                RAISE WARNING 'pgfr_record.run_tier: rollup bucket scan failed for %: %', v_target.source_view, SQLERRM;
            END;
        END IF;
    END LOOP;

    -- SET LOCAL only auto-reverts on a subtransaction's own rollback (the
    -- per-target EXCEPTION blocks above), never on normal completion --
    -- so without this, the last target's lock_timeout would leak forward
    -- to whatever runs next in this session/transaction after run_tier()
    -- returns. In production that's harmless (each pg_cron invocation is
    -- its own transaction), but a caller running run_tier() interactively,
    -- or a test harness running several in one transaction, would
    -- otherwise inherit a tight lock_timeout unrelated to anything else
    -- they run afterward.
    EXECUTE format('SET LOCAL lock_timeout = %L', v_orig_lock_timeout);

    -- Single append, not open-then-close (§8.2): both timestamps are
    -- already known, so there is nothing to update later.
    INSERT INTO pgfr_record.ledger_runs (run_id, tier, captured_at, finished_at)
    OVERRIDING SYSTEM VALUE VALUES (v_run_id, p_tier, v_t0, clock_timestamp());
END;
$$;

COMMENT ON FUNCTION pgfr_record.run_tier(text, interval, interval) IS
    'Runs one tier''s capture_plan targets under one shared captured_at (§5). Each target executes in its own EXCEPTION block (ok/timeout/lock_timeout/denied/error), recorded in ledger_captures; one target''s failure cannot fail the tier. lock_timeout is a real per-target bound; job_timeout is enforced cooperatively here (stops further targets from starting) and, when dispatched via apply_profile()''s two-statement cron command, preemptively by the caller''s own statement_timeout -- see the comment atop this file for why a per-target statement_timeout could not be implemented directly. For a target with a rollup (milestone 8), also closes every eligible bucket since the last successful close, in its own subtransaction separate from the raw capture -- see the comment above that step for the self-healing range and why it is not ledger-visible.';
