-- This test exercised a bug in the legacy pgfr_record.sample() lock
-- collection (silent failure when snapshot_based_collection = false).
-- The legacy sampler has been retired; the v2 sample_ring() doesn't have
-- the snapshot_based_collection toggle or the _fr_psa_snapshot temp table
-- the bug depended on. Test is retired alongside the bug it guarded.

\set ON_ERROR_STOP 1
set client_min_messages to warning;

select plan(1);

select skip('Legacy sample() lock-collection bug fixed by v2 sample_ring; test retired alongside the legacy sampler');

select * from finish();
