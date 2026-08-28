-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- Partition maintenance (pgfr-v2-context-pack.md §4.2). In-house, on
-- purpose: pgfr's needs (pre-create calendar-regular empty partitions
-- ahead, drop expired ones behind) are deliberately simple enough to
-- handle without a partition-management dependency.

CREATE OR REPLACE FUNCTION pgfr_record._current_major()
RETURNS int
LANGUAGE sql IMMUTABLE AS $$
    SELECT current_setting('server_version_num')::int / 10000;
$$;
COMMENT ON FUNCTION pgfr_record._current_major() IS 'The running server''s PostgreSQL major version, e.g. 15.';

CREATE OR REPLACE FUNCTION pgfr_record._short_name(p_source_view text)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT regexp_replace(p_source_view, '^[^.]+\.', '');
$$;
COMMENT ON FUNCTION pgfr_record._short_name(text) IS 'source_view without its schema prefix, e.g. pg_catalog.pg_stat_database -> pg_stat_database (§4.1).';

-- Partition width derived from retention by rule (§4.2): width must scale
-- with retention at both ends.
CREATE OR REPLACE FUNCTION pgfr_record._partition_unit(p_retention interval)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN p_retention <= interval '6 hours' THEN 'hour'
        WHEN p_retention <= interval '60 days' THEN 'day'
        ELSE 'month'
    END;
$$;
COMMENT ON FUNCTION pgfr_record._partition_unit(interval) IS 'retention <= 6h -> hourly; <= 60d -> daily; > 60d -> monthly (§4.2).';

-- Every table pgfr owns that is partitioned by captured_at, with its
-- retention and logged flag. The single source maintain_partitions()
-- iterates: the two ledger tables (fixed 30d retention -- see 04_ledger.sql)
-- plus one row per enabled, version-applicable manifest entry whose archive
-- table has already been created by generate_archives(). to_regclass
-- returns NULL (rather than erroring) for archive tables not yet created,
-- so this function is safe to call before generate_archives() has run for
-- every row.
CREATE OR REPLACE FUNCTION pgfr_record._partition_targets()
RETURNS TABLE(parent_table text, retention interval, logged boolean)
LANGUAGE sql STABLE AS $$
    SELECT 'ledger_runs'::text, interval '30 days', true
    UNION ALL
    SELECT 'ledger_captures'::text, interval '30 days', true
    UNION ALL
    SELECT 'a_' || pgfr_record._short_name(m.source_view), m.retention, m.logged
    FROM pgfr_record.manifest m
    WHERE m.enabled
      AND m.min_major <= pgfr_record._current_major()
      AND pgfr_record._current_major() <= coalesce(m.max_major, 999)
      AND to_regclass('pgfr_record.a_' || pgfr_record._short_name(m.source_view)) IS NOT NULL;
$$;
COMMENT ON FUNCTION pgfr_record._partition_targets() IS 'Every pgfr-owned partitioned parent (ledger tables + created archive tables) with its retention and logged flag; the input to maintain_partitions().';

-- Deterministic partition naming lets maintain_partitions() recover a
-- child's lower bound from its name alone, so it never has to parse
-- pg_class.relpartbound.
CREATE OR REPLACE FUNCTION pgfr_record._partition_child_name(p_base text, p_lower timestamptz, p_unit text)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT p_base || '_p' || CASE p_unit
        WHEN 'hour'  THEN to_char(p_lower, 'YYYYMMDDHH24')
        WHEN 'day'   THEN to_char(p_lower, 'YYYYMMDD')
        WHEN 'month' THEN to_char(p_lower, 'YYYYMM')
    END;
$$;

CREATE OR REPLACE FUNCTION pgfr_record._partition_lower_bound(p_child_name text, p_base text, p_unit text)
RETURNS timestamptz
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE p_unit
        WHEN 'hour'  THEN to_timestamp(substring(p_child_name from length(p_base) + 3), 'YYYYMMDDHH24')
        WHEN 'day'   THEN to_timestamp(substring(p_child_name from length(p_base) + 3), 'YYYYMMDD')
        WHEN 'month' THEN to_timestamp(substring(p_child_name from length(p_base) + 3), 'YYYYMM')
    END;
$$;

-- The maintenance state machine itself (§4.2). Run hourly by its own
-- pg_cron job. DETACH PARTITION ... CONCURRENTLY cannot be executed from
-- inside a function or procedure body on any supported PostgreSQL version
-- (confirmed against the manual and pgsql-hackers -- no CALL/procedure
-- workaround exists), so this function never issues that statement
-- directly. Instead it is a small hourly reconciliation loop:
--
--   1. Create-ahead: pre-create partitions covering >= 2 widths beyond
--      now(), for every target. Ordinary DDL.
--   2. Schedule detaches: for each expired, still-attached partition,
--      cron.schedule() a one-off job (exact one-time minute/hour/day/month
--      spec, not a recurring wildcard) whose command text is *only* the
--      bare ALTER TABLE ... DETACH PARTITION ... CONCURRENTLY statement --
--      nothing else may share that command string, since pg_cron dispatches
--      it as a lone top-level statement and a multi-statement command would
--      be wrapped in an implicit transaction, breaking CONCURRENTLY again.
--   3. Drop retired tables: any standalone table (relispartition = false)
--      matching a target's naming convention, left over once a prior
--      cycle's detach job fired. Ordinary DDL -- no longer attached to
--      anything, so none of step 2's locking concerns apply.
--   4. Reap: unschedule one-off jobs from step 2 whose target has been
--      fully dropped by step 3.
--
-- A partition's full retirement therefore spans up to two maintenance
-- cycles (schedule -> detach fires within a minute -> next hourly cycle
-- drops + reaps), immaterial given retention windows measured in hours to
-- months and create-ahead already buffering two widths.
CREATE OR REPLACE FUNCTION pgfr_record.maintain_partitions()
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_now         timestamptz := clock_timestamp();
    v_target      record;
    v_unit        text;
    v_step        interval;
    v_bucket0     timestamptz;
    v_lower       timestamptz;
    v_upper       timestamptz;
    v_i           int;
    v_child       text;
    v_jobname     text;
    v_cron_spec   text;
    v_job         record;
BEGIN
    -- Step 1: create-ahead.
    FOR v_target IN SELECT * FROM pgfr_record._partition_targets() LOOP
        v_unit    := pgfr_record._partition_unit(v_target.retention);
        v_step    := ('1 ' || v_unit)::interval;
        v_bucket0 := date_trunc(v_unit, v_now);
        FOR v_i IN 0..2 LOOP
            v_lower := v_bucket0 + v_step * v_i;
            v_upper := v_lower + v_step;
            v_child := pgfr_record._partition_child_name(v_target.parent_table, v_lower, v_unit);
            IF to_regclass('pgfr_record.' || v_child) IS NULL THEN
                EXECUTE format(
                    'CREATE %sTABLE pgfr_record.%I PARTITION OF pgfr_record.%I FOR VALUES FROM (%L) TO (%L)',
                    CASE WHEN v_target.logged THEN '' ELSE 'UNLOGGED ' END,
                    v_child, v_target.parent_table, v_lower, v_upper
                );
            END IF;
        END LOOP;
    END LOOP;

    -- Step 2: schedule detaches for expired, still-attached partitions.
    FOR v_target IN SELECT * FROM pgfr_record._partition_targets() LOOP
        v_unit := pgfr_record._partition_unit(v_target.retention);
        FOR v_child IN
            SELECT c.relname
            FROM pg_inherits i
            JOIN pg_class c ON c.oid = i.inhrelid
            JOIN pg_class p ON p.oid = i.inhparent
            JOIN pg_namespace n ON n.oid = p.relnamespace
            WHERE n.nspname = 'pgfr_record'
              AND p.relname = v_target.parent_table
        LOOP
            v_lower := pgfr_record._partition_lower_bound(v_child, v_target.parent_table, v_unit);
            v_upper := v_lower + ('1 ' || v_unit)::interval;
            IF v_upper < v_now - v_target.retention THEN
                v_jobname := 'pgfr_detach_' || v_child;
                IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = v_jobname) THEN
                    v_cron_spec := to_char(v_now + interval '1 minute', 'MI HH24 DD MM') || ' *';
                    PERFORM cron.schedule(
                        v_jobname,
                        v_cron_spec,
                        format(
                            'ALTER TABLE pgfr_record.%I DETACH PARTITION pgfr_record.%I CONCURRENTLY',
                            v_target.parent_table, v_child
                        )
                    );
                END IF;
            END IF;
        END LOOP;
    END LOOP;

    -- Step 3: drop tables retired by a prior cycle's detach.
    FOR v_target IN SELECT * FROM pgfr_record._partition_targets() LOOP
        FOR v_child IN
            SELECT c.relname
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'pgfr_record'
              AND c.relkind = 'r'
              AND c.relispartition = false
              AND c.relname LIKE (v_target.parent_table || '\_p%') ESCAPE '\'
        LOOP
            EXECUTE format('DROP TABLE pgfr_record.%I', v_child);
        END LOOP;
    END LOOP;

    -- Step 4: reap one-off detach jobs whose target is now fully gone.
    FOR v_job IN
        SELECT jobname, substring(jobname from length('pgfr_detach_') + 1) AS child_name
        FROM cron.job
        WHERE jobname LIKE 'pgfr_detach_%'
    LOOP
        IF to_regclass('pgfr_record.' || v_job.child_name) IS NULL THEN
            PERFORM cron.unschedule(v_job.jobname);
        END IF;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION pgfr_record.maintain_partitions() IS
    'Hourly reconciliation: create partitions >= 2 widths ahead, schedule CONCURRENTLY detaches for expired ones via one-off pg_cron jobs, drop tables a prior cycle detached, and reap completed one-off jobs. DETACH ... CONCURRENTLY never runs from inside this function -- see the comment above its definition.';
