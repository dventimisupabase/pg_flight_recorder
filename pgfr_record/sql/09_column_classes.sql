-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- Column-class legend (§3.1, §4.5): counter/odometer/gauge/label/key,
-- consumed by deltas() and by pgfr_analyze, owned only here.
--
-- generate_column_classes() derives this mechanically rather than from a
-- hand-typed per-column list. Hand-classifying every column of all ~40
-- census views from memory would risk exactly the kind of confidently-
-- wrong answer invariant 2 warns against ("everything with a single
-- correct answer belongs in pgfr_record" -- a wrong answer is worse than
-- an honestly-derived mechanical one). Instead this is a rule-based
-- generator, consistent with every other artifact in this design being a
-- pure function of the manifest + the live catalog:
--
--   1. natural_key membership -> key. Checked first: identity always
--      wins, even over the override list below (pid, for instance, is a
--      natural_key column on several targets but also on that list, for
--      the targets where it is *not* part of the key).
--   2. An explicit override list for well-known exceptions that do not
--      follow the type-based default below (point-in-time counts and
--      identity attributes that happen to be numeric-typed).
--   3. A second, name-based override for point-in-time condition text
--      columns (wait_event, wait_event_type, state) -> gauge: the sampled
--      quantity Mode A's time-in-state estimation is built on, not inert
--      identity text like usename/datname, which the type-driven default
--      below cannot distinguish on its own.
--   4. The column literally named stats_reset -> label (and becomes the
--      reset_column for this view's own counters).
--   5. Type pg_lsn / xid / xid8 -> odometer (monotone, non-resettable --
--      this is §2's actual *definition* of odometer, not a guess).
--   6. A column in this manifest row's compare_ignore -> gauge (§3.2's
--      own rationale for compare_ignore is exactly "estimate churns
--      independent of real change", i.e. gauge behavior, not counter).
--   7. Column name matching min_/max_/mean_/stddev_ -> gauge (running
--      aggregates are not monotone counters, regardless of type).
--   8. Type timestamp with time zone / interval -> gauge (point-in-time
--      markers and lag/duration measurements).
--   9. Remaining numeric types -> counter (the documented common case:
--      "counters are monotone + resettable", §2), with reset_column set
--      to stats_reset when that column exists in the same view.
--   10. Everything else -> label.
--
-- This is a best-effort mechanical classification, not a hand-verified
-- audit of every column's Postgres documentation. The override list is a
-- starting point, expected to grow as misclassifications are found in
-- practice -- exactly the same maintenance posture as compare_ignore.
CREATE OR REPLACE FUNCTION pgfr_record.generate_column_classes()
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_target    record;
    v_has_reset boolean;
    v_i         int;
    v_col       text;
    v_type      text;
    v_class     text;
    v_reset_col text;
BEGIN
    TRUNCATE pgfr_record.column_classes;

    FOR v_target IN
        SELECT m.source_view, m.natural_key, m.compare_ignore, m.keyless, ps.columns, ps.type_names
        FROM pgfr_record.manifest m
        JOIN LATERAL (
            SELECT columns, type_names
            FROM pgfr_record.payload_schemas p
            WHERE p.source_view = m.source_view
            ORDER BY p.schema_id DESC
            LIMIT 1
        ) ps ON true
        WHERE m.enabled
          AND m.min_major <= pgfr_record._current_major()
          AND pgfr_record._current_major() <= coalesce(m.max_major, 999)
    LOOP
        v_has_reset := 'stats_reset' = ANY(v_target.columns);

        FOR v_i IN 1..array_length(v_target.columns, 1) LOOP
            v_col := v_target.columns[v_i];
            v_type := v_target.type_names[v_i];
            v_reset_col := NULL;

            IF NOT v_target.keyless AND v_col = ANY(v_target.natural_key) THEN
                -- Identity always wins: pid, for instance, is a natural_key
                -- column on several targets (pg_stat_activity, pg_stat_
                -- replication, the progress views) and must classify as
                -- key there, even though it is also on the override list
                -- below for targets where it is *not* part of the key
                -- (pg_stat_wal_receiver).
                v_class := 'key';
            ELSIF v_col = ANY(ARRAY['numbackends','pid','sender_port','client_port','sync_priority','reltuples','bits','client_serial','start_value','increment_by','cache_size','map_number','leader_pid','query_id']) THEN
                -- Known exceptions: numeric-typed but not cumulative --
                -- current counts, process/network identity, config, a
                -- periodically-recomputed estimate (reltuples can legitimately
                -- decrease when ANALYZE reruns, so it is not a counter), a
                -- per-connection TLS property (bits, client_serial: fixed for
                -- that connection's lifetime, not cumulative), fixed
                -- sequence config set at CREATE SEQUENCE time (start_value,
                -- increment_by, cache_size), or another identity-shaped
                -- numeric value alongside pid: leader_pid (a parallel
                -- worker's leader process id, on pg_stat_activity and
                -- pg_stat_subscription) and query_id (a query fingerprint
                -- hash, on pg_stat_activity). pg_sequences.last_value is
                -- deliberately NOT on this list: it is the one column here
                -- that behaves like a real counter (monotone under normal
                -- use, reset-aware protection from deltas() covers RESTART/
                -- CYCLE without needing a reset_column), and is exactly the
                -- consumption-rate signal this target exists to capture. And
                -- map_number: pg_ident_file_mappings' PG16+ ordinal position
                -- of a mapping rule within its file, not a cumulative count
                -- (a mid-major column addition of the same kind pg_stat_
                -- statements is already known for, discovered here via a
                -- live PG15-vs-PG17 comparison rather than assumed absent).
                v_class := 'gauge';
            ELSIF v_col = ANY(ARRAY['wait_event','wait_event_type','state']) THEN
                -- Point-in-time condition, not identity: on pg_stat_activity
                -- (wait_event, wait_event_type, state) and pg_stat_replication
                -- (state), these are the sampled quantity Mode A's ASH-style
                -- time-in-state estimation is actually built on (§ STATISTICS.md
                -- "Time-in-state estimation"), not an inert dimension like
                -- usename/datname. The type-driven default below would have
                -- left them label, indistinguishable from genuinely static
                -- identity text, discovered live: a departed backend's last-
                -- ever wait_event_type is exactly as stale as its state, and
                -- both needed the same latest_state() fix as xact_start.
                v_class := 'gauge';
            ELSIF v_col = 'stats_reset' THEN
                v_class := 'label';
            ELSIF v_type IN ('pg_lsn', 'xid', 'xid8') THEN
                v_class := 'odometer';
            ELSIF v_col = ANY(v_target.compare_ignore) THEN
                v_class := 'gauge';
            ELSIF v_col ~ '^(min|max|mean|stddev)_' THEN
                v_class := 'gauge';
            ELSIF v_type IN ('timestamp with time zone', 'interval') THEN
                v_class := 'gauge';
            ELSIF v_type IN ('bigint', 'numeric', 'integer', 'smallint', 'double precision') THEN
                v_class := 'counter';
                IF v_has_reset THEN
                    v_reset_col := 'stats_reset';
                END IF;
            ELSE
                v_class := 'label';
            END IF;

            INSERT INTO pgfr_record.column_classes (source_view, column_name, class, reset_column)
            VALUES (v_target.source_view, v_col, v_class, v_reset_col)
            ON CONFLICT (source_view, column_name) DO NOTHING;
        END LOOP;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION pgfr_record.generate_column_classes() IS
    'Rebuilds pgfr_record.column_classes wholesale via a type/name-driven ruleset over each target''s current live columns (see the comment above this function for the exact rule order and its known override list). Regenerate whenever the manifest or a target''s live shape changes; safe to re-run.';
