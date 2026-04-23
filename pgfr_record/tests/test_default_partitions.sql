-- pgTAP test: every range-partitioned parent has a DEFAULT partition.
--
-- A DEFAULT partition captures rows whose sample_ts doesn't fall into any
-- existing daily partition — turning a race-condition INSERT failure into
-- graceful "land it here for now" behavior.
--
-- Also verifies _partition_inventory() naturally excludes DEFAULT partitions
-- (pg_get_expr returns "DEFAULT", not the "FOR VALUES FROM ... TO ..." shape
-- the inventory's regex matches) so retention GC never targets them.

\set ON_ERROR_STOP 1
set client_min_messages to warning;

select plan(10);

-- =========================================================================
-- 1. Each of the 9 range-partitioned parents has a DEFAULT child (9 tests)
-- =========================================================================

select ok(
    exists(
        select 1
        from pg_inherits i
        join pg_class c on c.oid = i.inhrelid
        where i.inhparent = 'pgfr_record.statement_snapshots_v2'::regclass
          and pg_get_expr(c.relpartbound, c.oid) = 'DEFAULT'
    ),
    'statement_snapshots_v2 has DEFAULT partition'
);

select ok(
    exists(
        select 1
        from pg_inherits i
        join pg_class c on c.oid = i.inhrelid
        where i.inhparent = 'pgfr_record.table_snapshots_v2'::regclass
          and pg_get_expr(c.relpartbound, c.oid) = 'DEFAULT'
    ),
    'table_snapshots_v2 has DEFAULT partition'
);

select ok(
    exists(
        select 1
        from pg_inherits i
        join pg_class c on c.oid = i.inhrelid
        where i.inhparent = 'pgfr_record.index_snapshots_v2'::regclass
          and pg_get_expr(c.relpartbound, c.oid) = 'DEFAULT'
    ),
    'index_snapshots_v2 has DEFAULT partition'
);

select ok(
    exists(
        select 1
        from pg_inherits i
        join pg_class c on c.oid = i.inhrelid
        where i.inhparent = 'pgfr_record.snapshots_v2'::regclass
          and pg_get_expr(c.relpartbound, c.oid) = 'DEFAULT'
    ),
    'snapshots_v2 has DEFAULT partition'
);

select ok(
    exists(
        select 1
        from pg_inherits i
        join pg_class c on c.oid = i.inhrelid
        where i.inhparent = 'pgfr_record.replication_snapshots_v2'::regclass
          and pg_get_expr(c.relpartbound, c.oid) = 'DEFAULT'
    ),
    'replication_snapshots_v2 has DEFAULT partition'
);

select ok(
    exists(
        select 1
        from pg_inherits i
        join pg_class c on c.oid = i.inhrelid
        where i.inhparent = 'pgfr_record.vacuum_progress_snapshots_v2'::regclass
          and pg_get_expr(c.relpartbound, c.oid) = 'DEFAULT'
    ),
    'vacuum_progress_snapshots_v2 has DEFAULT partition'
);

select ok(
    exists(
        select 1
        from pg_inherits i
        join pg_class c on c.oid = i.inhrelid
        where i.inhparent = 'pgfr_record.activity_samples_archive_v2'::regclass
          and pg_get_expr(c.relpartbound, c.oid) = 'DEFAULT'
    ),
    'activity_samples_archive_v2 has DEFAULT partition'
);

select ok(
    exists(
        select 1
        from pg_inherits i
        join pg_class c on c.oid = i.inhrelid
        where i.inhparent = 'pgfr_record.lock_samples_archive_v2'::regclass
          and pg_get_expr(c.relpartbound, c.oid) = 'DEFAULT'
    ),
    'lock_samples_archive_v2 has DEFAULT partition'
);

select ok(
    exists(
        select 1
        from pg_inherits i
        join pg_class c on c.oid = i.inhrelid
        where i.inhparent = 'pgfr_record.wait_samples_archive_v2'::regclass
          and pg_get_expr(c.relpartbound, c.oid) = 'DEFAULT'
    ),
    'wait_samples_archive_v2 has DEFAULT partition'
);

-- =========================================================================
-- 2. _partition_inventory() excludes DEFAULT partitions (1 test)
-- =========================================================================
--
-- The inventory's regex matches "FOR VALUES FROM (NNN) TO (MMM)". DEFAULT
-- partitions return "DEFAULT" from pg_get_expr(), so parsed.bounds is NULL
-- and the `parsed.bounds is not null` filter drops them. This is the correct
-- behavior — DEFAULT partitions are meant to persist and catch misrouted
-- rows; retention GC should never target them.

select is(
    (select count(*)::int
       from pgfr_record._partition_inventory()
      where partition_name like '%_default'),
    0,
    '_partition_inventory() excludes DEFAULT partitions from retention GC'
);

select * from finish();
