-- Phase 1: Sparse statement_snapshots collector
-- SPEC §5.2 — storage-overhaul-spec branch
-- PG14+ minimum (requires pg_stat_statements_info, toplevel column)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 2. statement_snapshots_v2  — partitioned by range (sample_ts int4)
--    Dual-write: old statement_snapshots stays untouched (see SPEC Q2)
-- ---------------------------------------------------------------------------
create table if not exists pgfr_record.statement_snapshots_v2 (
    snapshot_id             bigint          not null,  -- BIGINT per SPEC Q5; accepts INT serial values safely
    sample_ts               INT4            not null,  -- seconds since pgfr_record.epoch()
    queryid                 bigint          not null,
    userid                  oid             not null,
    dbid                    oid             not null,
    toplevel                boolean         not null,  -- PG14+; part of PGSS uniqueness key
    query_preview           text,
    calls                   bigint,
    total_exec_time         DOUBLE PRECISION,
    min_exec_time           DOUBLE PRECISION,
    max_exec_time           DOUBLE PRECISION,
    mean_exec_time          DOUBLE PRECISION,
    rows                    bigint,
    shared_blks_hit         bigint,
    shared_blks_read        bigint,
    shared_blks_dirtied     bigint,
    shared_blks_written     bigint,
    temp_blks_read          bigint,
    temp_blks_written       bigint,
    blk_read_time           DOUBLE PRECISION,
    blk_write_time          DOUBLE PRECISION,
    wal_records             bigint,
    wal_bytes               numeric,
    pgss_dealloc_warning    boolean         not null default false  -- cluster-level PGSS eviction event
) partition by range (sample_ts);

create table if not exists pgfr_record.statement_snapshots_v2_default
    partition of pgfr_record.statement_snapshots_v2 default;

comment on table pgfr_record.statement_snapshots_v2 is
'Sparse PGSS history partitioned by int4 sample_ts (seconds since pgfr_record.epoch()). '
'Dual-write: old statement_snapshots retained. Missing row = no change since last stored row. '
'Readers reconstruct full state via DISTINCT ON ... ORDER BY sample_ts DESC. '
'See SPEC §5.2.';

comment on column pgfr_record.statement_snapshots_v2.pgss_dealloc_warning is
'TRUE when pg_stat_statements_info.dealloc increased since last tick. '
'This is a CLUSTER-WIDE signal: evictions on any database set this flag. '
'Do NOT interpret as "data for this database is missing" — say "cluster-level PGSS evictions".';

-- ---------------------------------------------------------------------------
-- 3. statement_last_state — UNLOGGED HOT-optimized side table
-- ---------------------------------------------------------------------------
create unlogged table if not exists pgfr_record.statement_last_state (
    queryid     bigint  not null,
    dbid        oid     not null,
    userid      oid     not null,
    toplevel    boolean not null,  -- PG14+; part of PGSS uniqueness key
    calls       bigint  not null,
    sample_ts   INT4    not null,
    primary key (queryid, dbid, userid, toplevel)
) with (
    fillfactor = 70,                        -- leave room for HOT updates
    autovacuum_vacuum_scale_factor  = 0.01, -- vacuum after 1% dead tuples
    autovacuum_analyze_scale_factor = 0.01
);

comment on table pgfr_record.statement_last_state is
'HOT-sensitive: do NOT index mutable columns (calls, sample_ts). '
'HOT updates require changed columns to be unindexed. '
'See: https://github.com/NikolayS/pg-flight-recorder/blueprints/SPEC.md §5.2';

-- ---------------------------------------------------------------------------
-- 4. _rebuild_statement_last_state()
-- ---------------------------------------------------------------------------
create or replace function pgfr_record._rebuild_statement_last_state(p_sample_ts int4 default null)
returns void
language plpgsql as $$
declare
    v_ts int4;
begin
    -- use caller-supplied tick timestamp when available to avoid skew between
    -- now() (transaction start) and the collector's clock_timestamp()-based v_sample_ts
    v_ts := coalesce(p_sample_ts,
                     extract(epoch from now() - pgfr_record.epoch())::int4);

    truncate pgfr_record.statement_last_state;
    insert into pgfr_record.statement_last_state (queryid, dbid, userid, toplevel, calls, sample_ts)
    select
        queryid,
        dbid,
        userid,
        toplevel,
        calls,
        v_ts
    from pg_stat_statements;
    analyze pgfr_record.statement_last_state;
end;
$$;
comment on function pgfr_record._rebuild_statement_last_state(int4) is
'Full rebuild of statement_last_state from pg_stat_statements. '
'p_sample_ts: caller-supplied tick timestamp (seconds since epoch()); avoids now() skew. '
'Called on crash recovery (UNLOGGED table empty) or clean-restart desync '
'(PGSS stats_reset newer than max(sample_ts) in last_state). '
'Caller must hold pg_try_advisory_xact_lock before calling. '
'ANALYZE is called immediately to lock in planner statistics post-TRUNCATE.';

-- ---------------------------------------------------------------------------
-- 5. _collect_statement_snapshot_sparse() — the core sparse collector
-- ---------------------------------------------------------------------------
create or replace function pgfr_record._collect_statement_snapshot_sparse(p_snapshot_id bigint)
returns void
language plpgsql as $$
declare
    v_sample_ts         INT4;
    v_pg_version        INTEGER;
    v_pgss_reset        TIMESTAMPTZ;
    v_last_sample_ts    INT4;
    v_orig_last_ts      INT4;   -- last_sample_ts before any Step-3 rebuild (used for Step-4 boundary check)
    v_last_dealloc      bigint;
    v_curr_dealloc      bigint;
    v_dealloc_warning   boolean := false;
    v_last_state_day    INT4;
    v_today_start_ts    INT4;
    v_at_boundary       boolean := false;
    v_locked            boolean;
    v_rows_inserted     INT;
begin
    -- Ensure partition exists for today (O(1) on happy path)
    perform pgfr_record._ensure_partition('statement_snapshots_v2', CURRENT_DATE);

    v_sample_ts   := extract(EPOCH from now() - pgfr_record.epoch())::INT4;
    v_pg_version  := pgfr_record._pg_version();

    -- -----------------------------------------------------------------------
    -- PGSS collection section — wrapped in BEGIN/EXCEPTION so failure here
    -- does not abort other collection sections (SPEC §5.2)
    -- -----------------------------------------------------------------------
    begin

        -- -------------------------------------------------------------------
        -- Step 1: Check clean-restart desync (SPEC §5.2)
        --         pg_stat_statements_info.stats_reset is PG14+ (always present
        --         per §2 minimum version requirement)
        -- -------------------------------------------------------------------
        select stats_reset into v_pgss_reset from pg_stat_statements_info;
        select MAX(sample_ts) into v_last_sample_ts from pgfr_record.statement_last_state;
        v_orig_last_ts := v_last_sample_ts;  -- preserve for Step-4 boundary check

        -- -------------------------------------------------------------------
        -- Step 2: Check PGSS dealloc counter (cluster-wide, not per-db)
        -- -------------------------------------------------------------------
        select dealloc into v_curr_dealloc from pg_stat_statements_info;
        select value::bigint into v_last_dealloc
        from pgfr_record.config
        where key = 'pgss_last_dealloc';

        if v_last_dealloc is not null and v_curr_dealloc > v_last_dealloc then
            v_dealloc_warning := true;
        end if;
        -- Store current dealloc for next tick comparison
        insert into pgfr_record.config (key, value, updated_at)
        values ('pgss_last_dealloc', v_curr_dealloc::text, now())
        on conflict (key) do update set value = EXCLUDED.value, updated_at = EXCLUDED.updated_at;

        -- -------------------------------------------------------------------
        -- Step 3: Decide if rebuild is needed
        --         Conditions:
        --           (a) last_state is empty (crash recovery — UNLOGGED truncated)
        --           (b) PGSS stats_reset is newer than our last sample_ts
        --               (clean restart with pg_stat_statements.save=off, or
        --                explicit pg_stat_statements_reset())
        -- -------------------------------------------------------------------
        if v_last_sample_ts is null
           or (v_pgss_reset is not null
               and v_pgss_reset > (pgfr_record.epoch() + v_last_sample_ts * interval '1 second'))
        then
            -- Advisory lock prevents two concurrent callers from both rebuilding.
            -- Lock held for entire transaction (intentional per SPEC §5.2).
            v_locked := pg_try_advisory_xact_lock(7382961::integer, hashtext('pgfr_last_state_rebuild')::integer);
            if not v_locked then
                -- Another session is rebuilding; skip this tick
                insert into pgfr_record.config (key, value, updated_at)
                values ('pgss_rebuild_skip_count',
                        (coalesce((select value from pgfr_record.config where key = 'pgss_rebuild_skip_count'), '0')::bigint + 1)::text,
                        now())
                on conflict (key) do update
                    set value = (coalesce(pgfr_record.config.value, '0')::bigint + 1)::text,
                        updated_at = EXCLUDED.updated_at;
                return;
            end if;
            perform pgfr_record._rebuild_statement_last_state(v_sample_ts);
            -- After rebuild, re-read last_sample_ts for boundary check below
            select max(sample_ts) into v_last_sample_ts from pgfr_record.statement_last_state;
        end if;

        -- -------------------------------------------------------------------
        -- Step 4: Daily partition boundary — TRUNCATE + rebuild last_state
        --         This keeps the side table aligned with current PGSS contents
        --         and prevents stale entries from accumulating (SPEC §5.2).
        -- -------------------------------------------------------------------
        v_today_start_ts := extract(EPOCH from (CURRENT_DATE::TIMESTAMPTZ at TIME zone 'UTC') - pgfr_record.epoch())::INT4;

        -- If the most recent last_state entry was from before today (use original
        -- pre-Step-3 value so a stats_reset rebuild does not mask a day boundary).
        if v_orig_last_ts is not null and v_orig_last_ts < v_today_start_ts then
            v_at_boundary := true;
            -- Acquire rebuild lock (if not already held from above)
            v_locked := pg_try_advisory_xact_lock(7382961::integer, hashtext('pgfr_last_state_rebuild')::integer);
            if not v_locked then
                insert into pgfr_record.config (key, value, updated_at)
                values ('pgss_rebuild_skip_count',
                        (coalesce((select value from pgfr_record.config where key = 'pgss_rebuild_skip_count'), '0')::bigint + 1)::text,
                        now())
                on conflict (key) do update
                    set value = (coalesce(pgfr_record.config.value, '0')::bigint + 1)::text,
                        updated_at = EXCLUDED.updated_at;
                return;
            end if;
            perform pgfr_record._rebuild_statement_last_state(v_sample_ts);
            select max(sample_ts) into v_last_sample_ts from pgfr_record.statement_last_state;

            -- B2 fix: after boundary rebuild last_state reflects current calls,
            -- so the sparse WHERE would match nothing and insert 0 rows —
            -- silently losing the baseline for the new day's partition.
            -- Force all rows to match by poisoning calls to -1 so pss.calls > ls.calls
            -- is always true on the next INSERT. This ensures a full baseline row
            -- is written to statement_snapshots_v2 at the start of every daily partition.
            update pgfr_record.statement_last_state set calls = -1;
        end if;

        -- -------------------------------------------------------------------
        -- Step 5: Hash join PGSS against last_state; insert only changed rows
        --         Insert condition: new queryid OR calls increased OR calls dropped
        --         (calls drop = pg_stat_statements_reset() partial/full reset)
        -- -------------------------------------------------------------------
        -- PG17 renamed blk_read_time -> shared_blk_read_time in pg_stat_statements.
        -- case when cannot reference a nonexistent column even in a dead branch,
        -- so use execute with the correct column name chosen at runtime.
        execute format(
            $q$
            insert into pgfr_record.statement_snapshots_v2 (
                snapshot_id, sample_ts, queryid, userid, dbid, toplevel,
                query_preview, calls, total_exec_time, min_exec_time,
                max_exec_time, mean_exec_time, rows,
                shared_blks_hit, shared_blks_read, shared_blks_dirtied,
                shared_blks_written, temp_blks_read, temp_blks_written,
                blk_read_time, blk_write_time,
                wal_records, wal_bytes, pgss_dealloc_warning
            )
            select
                $1, $2,
                pss.queryid, pss.userid, pss.dbid, pss.toplevel,
                left(pss.query, 500),
                pss.calls, pss.total_exec_time, pss.min_exec_time,
                pss.max_exec_time, pss.mean_exec_time, pss.rows,
                pss.shared_blks_hit, pss.shared_blks_read,
                pss.shared_blks_dirtied, pss.shared_blks_written,
                pss.temp_blks_read, pss.temp_blks_written,
                pss.%I, pss.%I,
                pss.wal_records, pss.wal_bytes,
                $3
            from pg_stat_statements pss
            left join pgfr_record.statement_last_state ls
                using (queryid, dbid, userid, toplevel)
            where
                ls.queryid is null
                or pss.calls > ls.calls
                or pss.calls < ls.calls
            $q$,
            case when v_pg_version >= 17 then 'shared_blk_read_time'  else 'blk_read_time'  end,
            case when v_pg_version >= 17 then 'shared_blk_write_time' else 'blk_write_time' end
        ) using p_snapshot_id, v_sample_ts, v_dealloc_warning;

        get diagnostics v_rows_inserted = ROW_COUNT;

        -- -------------------------------------------------------------------
        -- Step 6: Upsert last_state for all rows we just saw in PGSS
        --         Must use ON CONFLICT DO UPDATE (not DELETE+INSERT) to preserve
        --         HOT eligibility. Only calls and sample_ts change — never key
        --         columns — so HOT is always eligible (SPEC §5.2).
        -- -------------------------------------------------------------------
        if v_at_boundary then
            -- At boundary we already did a full rebuild; no incremental upsert needed
            -- (rebuild already reflects current PGSS state)
            null;
        else
            insert into pgfr_record.statement_last_state (queryid, dbid, userid, toplevel, calls, sample_ts)
            select
                pss.queryid,
                pss.dbid,
                pss.userid,
                pss.toplevel,
                pss.calls,
                v_sample_ts
            from pg_stat_statements pss
            on conflict (queryid, dbid, userid, toplevel) do update
                set calls     = EXCLUDED.calls,
                    sample_ts = EXCLUDED.sample_ts;
        end if;

    exception
        when undefined_table then
            -- pg_stat_statements not loaded; do NOT truncate last_state (SPEC §5.2)
            raise warning 'pgfr_record: pg_stat_statements unavailable (extension not loaded): %', sqlerrm;
        when others then
            -- Any other failure must not abort other collection sections
            raise warning 'pgfr_record: PGSS sparse collection failed [%]: %', sqlstate, sqlerrm;
    end;
end;
$$;
comment on function pgfr_record._collect_statement_snapshot_sparse(bigint) is
'Sparse PGSS collector per SPEC §5.2. '
'Inserts rows into statement_snapshots_v2 only when calls changed. '
'Maintains statement_last_state as HOT-update-friendly side table. '
'Handles: crash recovery (UNLOGGED empty), clean-restart desync (stats_reset check), '
'daily partition boundary (TRUNCATE+rebuild), advisory lock (skip if rebuild in flight), '
'PGSS dealloc tracking (cluster-wide, not per-db). '
'Wrapped in EXCEPTION block — failure does not abort other collection sections.';

-- Register config keys for sparse collector observability
-- Initialize pgss_last_dealloc to current dealloc value to avoid false-positive
-- dealloc warnings on first run (pre-existing evictions are not our fault).
insert into pgfr_record.config (key, value, updated_at)
select 'pgss_last_dealloc', dealloc::text, now()
from pg_stat_statements_info
on conflict (key) do nothing;

insert into pgfr_record.config (key, value) values
    ('pgss_rebuild_skip_count', '0')
on conflict (key) do nothing;

-- =============================================================================
-- Phase 1: Sparse table_snapshots and index_snapshots collectors (Issue #8)
-- SPEC §5.3 — storage-overhaul-spec branch
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. table_snapshots_v2 — partitioned by range (sample_ts int4)
-- ---------------------------------------------------------------------------
create table if not exists pgfr_record.table_snapshots_v2 (
    snapshot_id         bigint not null,
    sample_ts           int4 not null,   -- seconds since pgfr_record.epoch()
    relid               oid not null,
    dbid                oid not null,    -- pg_database.oid
    seq_scan            bigint,
    seq_tup_read        bigint,
    idx_scan            bigint,
    idx_tup_fetch       bigint,
    n_tup_ins           bigint,
    n_tup_upd           bigint,
    n_tup_del           bigint,
    n_tup_hot_upd       bigint,
    n_live_tup          bigint,
    n_dead_tup          bigint,
    n_mod_since_analyze bigint,
    vacuum_count        bigint,
    autovacuum_count    bigint,
    analyze_count       bigint,
    autoanalyze_count   bigint,
    last_vacuum         timestamptz,
    last_autovacuum     timestamptz,
    last_analyze        timestamptz,
    last_autoanalyze    timestamptz,
    relfrozenxid_age    integer,
    reltuples           bigint,
    vacuum_running      boolean,
    table_size_bytes    bigint,
    total_size_bytes    bigint,
    indexes_size_bytes  bigint
) partition by range (sample_ts);

create table if not exists pgfr_record.table_snapshots_v2_default
    partition of pgfr_record.table_snapshots_v2 default;

comment on table pgfr_record.table_snapshots_v2 is
'Sparse table-level stats history partitioned by int4 sample_ts (seconds since pgfr_record.epoch()). '
'Missing row = no change since last stored row. '
'Readers reconstruct full state via DISTINCT ON (relid, dbid) ORDER BY sample_ts DESC. '
'Top-N filter applied (table_stats_top_n config key, default 50). '
'See Issue #8.';

-- ---------------------------------------------------------------------------
-- 2. table_last_state — UNLOGGED HOT-optimized side table
-- ---------------------------------------------------------------------------
create unlogged table if not exists pgfr_record.table_last_state (
    relid               oid not null,
    dbid                oid not null,
    sample_ts           int4 not null,
    seq_scan            bigint,
    idx_scan            bigint,
    n_tup_ins           bigint,
    n_tup_upd           bigint,
    n_tup_del           bigint,
    n_live_tup          bigint,
    n_dead_tup          bigint,
    n_mod_since_analyze bigint,
    primary key (relid, dbid)
) with (fillfactor = 70);

comment on table pgfr_record.table_last_state is
'HOT-sensitive: do NOT index mutable columns (seq_scan, idx_scan, n_tup_ins, etc.). '
'HOT updates require changed columns to be unindexed. '
'Only the PK index on (relid, dbid) is allowed. '
'UNLOGGED: truncated on crash — collector rebuilds automatically. '
'See Issue #8.';

-- ---------------------------------------------------------------------------
-- 3. _rebuild_table_last_state()
-- ---------------------------------------------------------------------------
create or replace function pgfr_record._rebuild_table_last_state()
returns void
language plpgsql as $$
declare
    v_dbid oid;
begin
    select oid into v_dbid from pg_database where datname = current_database();

    truncate pgfr_record.table_last_state;

    insert into pgfr_record.table_last_state (
        relid, dbid, sample_ts,
        seq_scan, idx_scan,
        n_tup_ins, n_tup_upd, n_tup_del,
        n_live_tup, n_dead_tup, n_mod_since_analyze
    )
    select
        st.relid,
        v_dbid,
        extract(epoch from now() - pgfr_record.epoch())::int4,
        st.seq_scan,
        st.idx_scan,
        st.n_tup_ins,
        st.n_tup_upd,
        st.n_tup_del,
        st.n_live_tup,
        st.n_dead_tup,
        st.n_mod_since_analyze
    from pg_stat_user_tables st;

    analyze pgfr_record.table_last_state;
end;
$$;

comment on function pgfr_record._rebuild_table_last_state() is
'Full rebuild of table_last_state from pg_stat_user_tables. '
'Called on crash recovery (UNLOGGED table empty after restart). '
'ANALYZE is called immediately to lock in planner statistics post-TRUNCATE. '
'Ghost rows (from dropped tables) are cleared on each rebuild — they do not '
'cause incorrect sparse inserts since the collector only joins against live '
'pg_stat_user_tables entries. '
'See Issue #8.';

-- ---------------------------------------------------------------------------
-- 4. _collect_table_snapshot_sparse(p_snapshot_id bigint)
-- ---------------------------------------------------------------------------
create or replace function pgfr_record._collect_table_snapshot_sparse(p_snapshot_id bigint)
returns void
language plpgsql as $$
declare
    v_sample_ts      int4;
    v_orig_last_ts   int4;
    v_today_start_ts int4;
    v_top_n          integer;
    v_dbid           oid;
begin
    -- ensure partition exists for today (O(1) on happy path)
    perform pgfr_record._ensure_partition('table_snapshots_v2', current_date,
        'relid, dbid, sample_ts desc');

    v_sample_ts := extract(epoch from now() - pgfr_record.epoch())::int4;
    v_top_n     := coalesce(pgfr_record._get_config('table_stats_top_n', '50')::integer, 50);

    select oid into v_dbid from pg_database where datname = current_database();

    begin
        -- crash recovery: if UNLOGGED table was truncated on restart, rebuild it
        -- exists() short-circuits on first row — avoids full scan on every tick
        if not exists (select 1 from pgfr_record.table_last_state) then
            perform pgfr_record._rebuild_table_last_state();
        end if;

        -- day-boundary: force full baseline into new partition.
        -- Poison numeric cols to -1 so every row matches the IS DISTINCT FROM
        -- predicate, guaranteeing a baseline row in the new day's partition.
        -- Mirrors the statement collector's calls=-1 trick (SPEC §5.2).
        select max(sample_ts) into v_orig_last_ts from pgfr_record.table_last_state;
        v_today_start_ts := extract(epoch from
            (current_date::timestamptz at time zone 'UTC') - pgfr_record.epoch())::int4;
        if v_orig_last_ts is not null and v_orig_last_ts < v_today_start_ts then
            update pgfr_record.table_last_state
            set seq_scan = -1, idx_scan = -1,
                n_tup_ins = -1, n_tup_upd = -1, n_tup_del = -1,
                n_live_tup = -1, n_dead_tup = -1, n_mod_since_analyze = -1;
        end if;

        -- single statement: sparse insert + upsert last_state via writeable CTE.
        -- The top-N subquery is materialized once and shared across both branches.
        -- Changed = any of the 8 tracked activity metrics differs from last_state.
        with top_n as (
            -- select top-N tables by cumulative activity score
            select relid
            from (
                select
                    st.relid,
                    coalesce(st.seq_scan, 0)
                    + coalesce(st.idx_scan, 0)
                    + coalesce(st.n_tup_ins, 0)
                    + coalesce(st.n_tup_upd, 0)
                    + coalesce(st.n_tup_del, 0) as activity_score
                from pg_stat_user_tables st
                order by activity_score desc
                limit v_top_n
            ) ranked
        ),
        current_stats as (
            select
                st.relid,
                v_dbid::oid                                                 as dbid,
                st.seq_scan,
                st.seq_tup_read,
                st.idx_scan,
                st.idx_tup_fetch,
                st.n_tup_ins,
                st.n_tup_upd,
                st.n_tup_del,
                st.n_tup_hot_upd,
                st.n_live_tup,
                st.n_dead_tup,
                st.n_mod_since_analyze,
                st.vacuum_count,
                st.autovacuum_count,
                st.analyze_count,
                st.autoanalyze_count,
                st.last_vacuum,
                st.last_autovacuum,
                st.last_analyze,
                st.last_autoanalyze,
                nullif(age(c.relfrozenxid)::integer, 2147483647)            as relfrozenxid_age,
                c.reltuples::bigint                                         as reltuples,
                exists(
                    select 1 from pg_stat_progress_vacuum pv
                    where pv.relid = st.relid
                )                                                           as vacuum_running,
                pg_relation_size(st.relid)                                  as table_size_bytes,
                pg_total_relation_size(st.relid)                            as total_size_bytes,
                pg_indexes_size(st.relid)                                   as indexes_size_bytes
            from pg_stat_user_tables st
            join top_n t on t.relid = st.relid
            left join pg_class c on c.oid = st.relid
        ),
        changed as (
            -- rows where any tracked metric differs from last recorded state
            select cs.*
            from current_stats cs
            left join pgfr_record.table_last_state ls
                   on ls.relid = cs.relid
                  and ls.dbid  = cs.dbid
            where ls.relid is null   -- never seen before
               or coalesce(cs.seq_scan, 0)            is distinct from coalesce(ls.seq_scan, 0)
               or coalesce(cs.idx_scan, 0)            is distinct from coalesce(ls.idx_scan, 0)
               or coalesce(cs.n_tup_ins, 0)           is distinct from coalesce(ls.n_tup_ins, 0)
               or coalesce(cs.n_tup_upd, 0)           is distinct from coalesce(ls.n_tup_upd, 0)
               or coalesce(cs.n_tup_del, 0)           is distinct from coalesce(ls.n_tup_del, 0)
               or coalesce(cs.n_live_tup, 0)          is distinct from coalesce(ls.n_live_tup, 0)
               or coalesce(cs.n_dead_tup, 0)          is distinct from coalesce(ls.n_dead_tup, 0)
               or coalesce(cs.n_mod_since_analyze, 0) is distinct from coalesce(ls.n_mod_since_analyze, 0)
        ),
        sparse_insert as (
            -- insert changed rows into the partitioned snapshot table
            insert into pgfr_record.table_snapshots_v2 (
                snapshot_id, sample_ts, relid, dbid,
                seq_scan, seq_tup_read, idx_scan, idx_tup_fetch,
                n_tup_ins, n_tup_upd, n_tup_del, n_tup_hot_upd,
                n_live_tup, n_dead_tup, n_mod_since_analyze,
                vacuum_count, autovacuum_count, analyze_count, autoanalyze_count,
                last_vacuum, last_autovacuum, last_analyze, last_autoanalyze,
                relfrozenxid_age, reltuples, vacuum_running,
                table_size_bytes, total_size_bytes, indexes_size_bytes
            )
            select
                p_snapshot_id, v_sample_ts,
                ch.relid, ch.dbid,
                ch.seq_scan, ch.seq_tup_read, ch.idx_scan, ch.idx_tup_fetch,
                ch.n_tup_ins, ch.n_tup_upd, ch.n_tup_del, ch.n_tup_hot_upd,
                ch.n_live_tup, ch.n_dead_tup, ch.n_mod_since_analyze,
                ch.vacuum_count, ch.autovacuum_count, ch.analyze_count, ch.autoanalyze_count,
                ch.last_vacuum, ch.last_autovacuum, ch.last_analyze, ch.last_autoanalyze,
                ch.relfrozenxid_age, ch.reltuples, ch.vacuum_running,
                ch.table_size_bytes, ch.total_size_bytes, ch.indexes_size_bytes
            from changed ch
            returning relid, dbid
        )
        -- upsert last_state from current_stats for all top-N tables
        -- (not just changed ones — keep last_state fresh for all tracked tables)
        insert into pgfr_record.table_last_state (
            relid, dbid, sample_ts,
            seq_scan, idx_scan,
            n_tup_ins, n_tup_upd, n_tup_del,
            n_live_tup, n_dead_tup, n_mod_since_analyze
        )
        select
            cs.relid, cs.dbid, v_sample_ts,
            cs.seq_scan, cs.idx_scan,
            cs.n_tup_ins, cs.n_tup_upd, cs.n_tup_del,
            cs.n_live_tup, cs.n_dead_tup, cs.n_mod_since_analyze
        from current_stats cs
        on conflict (relid, dbid) do update
            set sample_ts           = excluded.sample_ts,
                seq_scan            = excluded.seq_scan,
                idx_scan            = excluded.idx_scan,
                n_tup_ins           = excluded.n_tup_ins,
                n_tup_upd           = excluded.n_tup_upd,
                n_tup_del           = excluded.n_tup_del,
                n_live_tup          = excluded.n_live_tup,
                n_dead_tup          = excluded.n_dead_tup,
                n_mod_since_analyze = excluded.n_mod_since_analyze;

    exception
        when others then
            raise warning 'pgfr_record: table sparse collection failed [%]: %', sqlstate, sqlerrm;
    end;
end;
$$;

comment on function pgfr_record._collect_table_snapshot_sparse(bigint) is
'Sparse table stats collector per Issue #8. '
'Inserts rows into table_snapshots_v2 only when tracked metrics changed. '
'Applies top-N filter (table_stats_top_n config key, default 50). '
'Maintains table_last_state as HOT-update-friendly side table. '
'Crash recovery: detects empty UNLOGGED table and rebuilds. '
'Wrapped in EXCEPTION block — failure does not abort other collection sections.';

-- ---------------------------------------------------------------------------
-- 5. index_snapshots_v2 — partitioned by range (sample_ts int4)
-- ---------------------------------------------------------------------------
create table if not exists pgfr_record.index_snapshots_v2 (
    snapshot_id         bigint not null,
    sample_ts           int4 not null,
    relid               oid not null,
    indexrelid          oid not null,
    dbid                oid not null,
    idx_scan            bigint,
    idx_tup_read        bigint,
    idx_tup_fetch       bigint,
    index_size_bytes    bigint
) partition by range (sample_ts);

create table if not exists pgfr_record.index_snapshots_v2_default
    partition of pgfr_record.index_snapshots_v2 default;

comment on table pgfr_record.index_snapshots_v2 is
'Sparse index-level stats history partitioned by int4 sample_ts (seconds since pgfr_record.epoch()). '
'Missing row = no change since last stored row. '
'Readers reconstruct full state via DISTINCT ON (indexrelid, dbid) ORDER BY sample_ts DESC. '
'All indexes collected (no top-N filter). '
'See Issue #8.';

-- ---------------------------------------------------------------------------
-- 6. index_last_state — UNLOGGED HOT-optimized side table
-- ---------------------------------------------------------------------------
create unlogged table if not exists pgfr_record.index_last_state (
    indexrelid          oid not null,
    dbid                oid not null,
    sample_ts           int4 not null,
    idx_scan            bigint,
    idx_tup_read        bigint,
    idx_tup_fetch       bigint,
    primary key (indexrelid, dbid)
) with (fillfactor = 70);

comment on table pgfr_record.index_last_state is
'HOT-sensitive: do NOT index mutable columns (idx_scan, idx_tup_read, idx_tup_fetch, sample_ts). '
'HOT updates require changed columns to be unindexed. '
'Only the PK index on (indexrelid, dbid) is allowed. '
'UNLOGGED: truncated on crash — collector rebuilds automatically. '
'See Issue #8.';

-- ---------------------------------------------------------------------------
-- 7. _rebuild_index_last_state()
-- ---------------------------------------------------------------------------
create or replace function pgfr_record._rebuild_index_last_state()
returns void
language plpgsql as $$
declare
    v_dbid oid;
begin
    select oid into v_dbid from pg_database where datname = current_database();

    truncate pgfr_record.index_last_state;

    insert into pgfr_record.index_last_state (
        indexrelid, dbid, sample_ts,
        idx_scan, idx_tup_read, idx_tup_fetch
    )
    select
        i.indexrelid,
        v_dbid,
        extract(epoch from now() - pgfr_record.epoch())::int4,
        i.idx_scan,
        i.idx_tup_read,
        i.idx_tup_fetch
    from pg_stat_user_indexes i;

    analyze pgfr_record.index_last_state;
end;
$$;

comment on function pgfr_record._rebuild_index_last_state() is
'Full rebuild of index_last_state from pg_stat_user_indexes. '
'Called on crash recovery (UNLOGGED table empty after restart). '
'ANALYZE is called immediately to lock in planner statistics post-TRUNCATE. '
'Ghost rows (from dropped indexes) are cleared on each rebuild — they do not '
'cause incorrect sparse inserts since the collector only joins against live '
'pg_stat_user_indexes entries. '
'Note: no top-N filter — all indexes are collected. On schemas with thousands '
'of indexes, the pg_relation_size() calls may add meaningful overhead. '
'See Issue #8.';

-- ---------------------------------------------------------------------------
-- 8. _collect_index_snapshot_sparse(p_snapshot_id bigint)
-- ---------------------------------------------------------------------------
create or replace function pgfr_record._collect_index_snapshot_sparse(p_snapshot_id bigint)
returns void
language plpgsql as $$
declare
    v_sample_ts      int4;
    v_orig_last_ts   int4;
    v_today_start_ts int4;
    v_dbid           oid;
begin
    -- ensure partition exists for today (O(1) on happy path)
    perform pgfr_record._ensure_partition('index_snapshots_v2', current_date,
        'indexrelid, dbid, sample_ts desc');

    v_sample_ts := extract(epoch from now() - pgfr_record.epoch())::int4;

    select oid into v_dbid from pg_database where datname = current_database();

    begin
        -- crash recovery: if UNLOGGED table was truncated on restart, rebuild it
        -- exists() short-circuits on first row — avoids full scan on every tick
        if not exists (select 1 from pgfr_record.index_last_state) then
            perform pgfr_record._rebuild_index_last_state();
        end if;

        -- day-boundary: force full baseline into new partition.
        -- Poison numeric cols to -1 so every index row matches the IS DISTINCT FROM
        -- predicate, guaranteeing a baseline row in the new day's partition.
        select max(sample_ts) into v_orig_last_ts from pgfr_record.index_last_state;
        v_today_start_ts := extract(epoch from
            (current_date::timestamptz at time zone 'UTC') - pgfr_record.epoch())::int4;
        if v_orig_last_ts is not null and v_orig_last_ts < v_today_start_ts then
            update pgfr_record.index_last_state
            set idx_scan = -1, idx_tup_read = -1, idx_tup_fetch = -1;
        end if;

        -- sparse insert: only rows where tracked metrics changed vs last_state
        -- no top-N filter for indexes (collect all)
        with current_stats as (
            select
                i.relid,
                i.indexrelid,
                v_dbid                          as dbid,
                i.idx_scan,
                i.idx_tup_read,
                i.idx_tup_fetch,
                pg_relation_size(i.indexrelid)  as index_size_bytes
            from pg_stat_user_indexes i
        )
        insert into pgfr_record.index_snapshots_v2 (
            snapshot_id, sample_ts,
            relid, indexrelid, dbid,
            idx_scan, idx_tup_read, idx_tup_fetch,
            index_size_bytes
        )
        select
            p_snapshot_id,
            v_sample_ts,
            cs.relid, cs.indexrelid, cs.dbid,
            cs.idx_scan, cs.idx_tup_read, cs.idx_tup_fetch,
            cs.index_size_bytes
        from current_stats cs
        left join pgfr_record.index_last_state ls
               on ls.indexrelid = cs.indexrelid
              and ls.dbid       = cs.dbid
        where ls.indexrelid is null   -- never seen before
           or coalesce(cs.idx_scan, 0)      is distinct from coalesce(ls.idx_scan, 0)
           or coalesce(cs.idx_tup_read, 0)  is distinct from coalesce(ls.idx_tup_read, 0)
           or coalesce(cs.idx_tup_fetch, 0) is distinct from coalesce(ls.idx_tup_fetch, 0);

        -- upsert last_state (only mutable columns → HOT eligible)
        insert into pgfr_record.index_last_state (
            indexrelid, dbid, sample_ts,
            idx_scan, idx_tup_read, idx_tup_fetch
        )
        select
            i.indexrelid,
            v_dbid,
            v_sample_ts,
            i.idx_scan,
            i.idx_tup_read,
            i.idx_tup_fetch
        from pg_stat_user_indexes i
        on conflict (indexrelid, dbid) do update
            set sample_ts    = excluded.sample_ts,
                idx_scan     = excluded.idx_scan,
                idx_tup_read = excluded.idx_tup_read,
                idx_tup_fetch = excluded.idx_tup_fetch;

    exception
        when others then
            raise warning 'pgfr_record: index sparse collection failed [%]: %', sqlstate, sqlerrm;
    end;
end;
$$;

comment on function pgfr_record._collect_index_snapshot_sparse(bigint) is
'Sparse index stats collector per Issue #8. '
'Inserts rows into index_snapshots_v2 only when idx_scan, idx_tup_read, or idx_tup_fetch changed. '
'No top-N filter — all indexes are collected. '
'Maintains index_last_state as HOT-update-friendly side table. '
'Crash recovery: detects empty UNLOGGED table and rebuilds. '
'Wrapped in EXCEPTION block — failure does not abort other collection sections.';

-- End Phase 1: Sparse table_snapshots and index_snapshots collectors (Issue #8)

-- ---------------------------------------------------------------------------
-- _ensure_partition(p_table text, p_date date, p_btree_cols text)
-- Overload for tables with non-standard B-tree index columns.
-- p_btree_cols: comma-separated column list for the B-tree index, e.g.
--   'relid, dbid, sample_ts desc'
--   'indexrelid, dbid, sample_ts desc'
-- ---------------------------------------------------------------------------
create or replace function pgfr_record._ensure_partition(
    p_table       text,
    p_date        date,
    p_btree_cols  text
)
returns void
language plpgsql
security invoker  -- caller must have DDL rights; prevents privilege escalation via %s injection
as $$
declare
    v_partition_name text;
    v_bound_start    int4;
    v_bound_end      int4;
    v_date_start_ts  timestamptz;
    v_date_end_ts    timestamptz;
begin
    v_partition_name := p_table || '_' || to_char(p_date, 'YYYY_MM_DD');

    -- O(1) happy path
    if exists (
        select 1
        from pg_catalog.pg_class c
        join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'pgfr_record'
          and c.relname = v_partition_name
    ) then
        return;
    end if;

    v_date_start_ts := (to_char(p_date,     'YYYY-MM-DD') || ' 00:00:00+00')::timestamptz;
    v_date_end_ts   := (to_char(p_date + 1, 'YYYY-MM-DD') || ' 00:00:00+00')::timestamptz;

    v_bound_start := extract(epoch from (v_date_start_ts - pgfr_record.epoch()))::int4;
    v_bound_end   := extract(epoch from (v_date_end_ts   - pgfr_record.epoch()))::int4;

    execute format(
        'create table if not exists pgfr_record.%I
         partition of pgfr_record.%I
         for values from (%s) to (%s)',
        v_partition_name,
        p_table,
        v_bound_start,
        v_bound_end
    );

    -- B-tree index with caller-supplied column list
    execute format(
        'create index if not exists %I
         on pgfr_record.%I (%s)',
        v_partition_name || '_btree_idx',
        v_partition_name,
        p_btree_cols
    );

    -- BRIN index on sample_ts
    execute format(
        'create index if not exists %I
         on pgfr_record.%I
         using brin (sample_ts) with (pages_per_range = 8)',
        v_partition_name || '_brin_idx',
        v_partition_name
    );
end;
$$;

comment on function pgfr_record._ensure_partition(text, date, text) is
'Overload of _ensure_partition for tables with non-standard B-tree index columns. '
'p_btree_cols: raw SQL column list for the B-tree index (e.g. ''relid, dbid, sample_ts desc''). '
'SECURITY: p_btree_cols is injected via %s (not %I) — must only be called with '
'compile-time string literals, never from user input or config values. '
'Otherwise identical to _ensure_partition(text, date). See Issue #8.';

--------------------------------------------------------------------------------
