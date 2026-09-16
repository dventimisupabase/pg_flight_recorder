-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- Capture ledger (pgfr-v2-context-pack.md §8.2). Misses are telemetry, not
-- silence: every target's per-run outcome is recorded, never inferred from
-- absence.
--
-- ledger_runs is written exactly once per tier run, after the run's loop
-- over its capture plan completes -- never opened, then later UPDATEd to
-- close. Open-then-close-with-an-UPDATE would be SCD-2 interval-closing
-- applied to the one piece of state that looks mutable, which is exactly
-- the pattern invariant 1 rules out ("event-sourced... never SCD-2
-- interval-closing"). Since the whole tier run executes as one
-- transaction, nothing is visible to any other session until commit
-- regardless of when a row is written, so deferring the insert costs
-- nothing -- and a crash mid-run now simply leaves no row, rather than a
-- row wedged with finished_at IS NULL forever. cron.job_run_details
-- (pg_cron's own log) is the source of truth for whether the top-level
-- call itself errored or overran.
-- run_id is globally unique on its own (backed by one shared identity
-- sequence across all partitions); the primary key is composite only
-- because PostgreSQL requires a partitioned table's unique constraints to
-- include the partition key column (captured_at).
CREATE TABLE IF NOT EXISTS pgfr_record.ledger_runs (
  run_id      bigint GENERATED ALWAYS AS IDENTITY,
  tier        text NOT NULL,
  captured_at timestamptz NOT NULL,
  finished_at timestamptz NOT NULL,
  PRIMARY KEY (run_id, captured_at)
) PARTITION BY RANGE (captured_at);

COMMENT ON TABLE pgfr_record.ledger_runs IS
    'One row per completed tier run, appended once after the run''s capture-plan loop finishes (never opened then UPDATEd to close -- see invariant 1). Absence of a row for an expected tick means the run did not complete; cross-reference cron.job_run_details for why.';
COMMENT ON COLUMN pgfr_record.ledger_runs.captured_at IS 'The tier''s single stamp (t0), shared by every target and every ledger_captures row in this run.';
COMMENT ON COLUMN pgfr_record.ledger_runs.finished_at IS 'Wall-clock time the run''s loop completed. Always populated at insert time; this table has no UPDATE path.';

CREATE TABLE IF NOT EXISTS pgfr_record.ledger_captures (
  run_id        bigint NOT NULL,
  source_view   text NOT NULL,
  outcome       text NOT NULL CHECK (outcome IN ('ok','timeout','lock_timeout','denied','error','skipped_disabled')),
  rows_appended int,
  was_anchor    boolean,
  visibility    text CHECK (visibility IN ('full','masked','degraded')),
  detail        text,
  elapsed       interval,
  captured_at   timestamptz NOT NULL
) PARTITION BY RANGE (captured_at);

COMMENT ON TABLE pgfr_record.ledger_captures IS
    'One row per (run, target) outcome: ok | timeout | lock_timeout | denied | error | skipped_disabled. Written during the run''s loop, referencing a run_id reserved up front via nextval so it is available before ledger_runs itself is appended (§5).';
COMMENT ON COLUMN pgfr_record.ledger_captures.visibility IS 'Per run per target, not per row: full | masked | degraded, reflecting the caller''s actual privilege at capture time.';
COMMENT ON COLUMN pgfr_record.ledger_captures.detail IS 'sqlerrm for outcome = error; NULL otherwise.';
COMMENT ON COLUMN pgfr_record.ledger_captures.captured_at IS 'Denormalized copy of the owning run''s captured_at (t0), so this table partitions on its own retention timeline independent of ledger_runs.';

CREATE INDEX IF NOT EXISTS ledger_captures_run_id_idx ON pgfr_record.ledger_captures (run_id);
