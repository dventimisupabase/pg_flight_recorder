-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- pg_flight_recorder: pgfr_analyze module install script (v2)
--
-- pgfr_analyze v2 is deferred to milestone 7 of the v2 rewrite (see
-- pgfr-v2-context-pack.md, Appendix). It is strictly optional by design
-- (pgfr-v2-context-pack.md §1, invariant 5): a pgfr_record-only install is
-- fully self-contained, so there is no functional gap in leaving this
-- schema empty in the interim. This placeholder keeps the two-extension
-- install pipeline (test.sh, scripts/build_install_bundle.sh,
-- scripts/build_dbdev_package.sh) working end to end while pgfr_record v2
-- is built out.
--
-- Requires pgfr_record installed first.

CREATE SCHEMA IF NOT EXISTS pgfr_analyze;
COMMENT ON SCHEMA pgfr_analyze IS
    'pg_flight_recorder v2 analyze: anomaly/regression/storm detection, trends, capacity views, and report() — all consuming pgfr_record''s definitional helpers, owning none of them. Not yet rebuilt for v2 (see pgfr-v2-context-pack.md, milestone 7).';
