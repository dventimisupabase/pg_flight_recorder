-- =============================================================================
-- pgfr_analyze v2 pgTAP Tests -- placeholder
-- =============================================================================
-- pgfr_analyze v2 is deferred to milestone 7 of the v2 rewrite (see
-- pgfr-v2-context-pack.md, Appendix). This placeholder just confirms the
-- schema exists, matching install.sql.

BEGIN;
SELECT plan(1);

SELECT has_schema('pgfr_analyze', 'Schema pgfr_analyze should exist');

SELECT * FROM finish();
ROLLBACK;
