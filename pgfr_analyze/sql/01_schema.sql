-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- pgfr_analyze v2: schema bootstrap.
--
-- pgfr_analyze reads pgfr_record's captured data, column classes, and
-- definitional helpers to answer questions requiring a threshold, baseline,
-- or opinion. It never writes to pgfr_record's schema.

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'pgfr_record') THEN
        RAISE EXCEPTION E'\n\npgfr_analyze requires pgfr_record.\n\nInstall pgfr_record first:\n  psql --single-transaction -f pgfr_record/install.sql\n';
    END IF;
END $$;

CREATE SCHEMA IF NOT EXISTS pgfr_analyze;
COMMENT ON SCHEMA pgfr_analyze IS
    'pg_flight_recorder v2 analyze: anomaly/regression/storm detection, trends, capacity views, and report(), all consuming pgfr_record''s definitional helpers and column classes, owning none of them. Reads pgfr_record only; never writes to its schema.';

-- Tunable thresholds (severity bands, lookback windows, ratios). Opinions
-- belong here, not in pgfr_record, which has no equivalent table.
CREATE TABLE IF NOT EXISTS pgfr_analyze.config (
    key        text PRIMARY KEY,
    value      text NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE pgfr_analyze.config IS
    'Tunable thresholds for pgfr_analyze functions (severity bands, lookback windows, ratios). Read via pgfr_analyze._get_config(key, default); unset keys fall back to each function''s own default.';

CREATE OR REPLACE FUNCTION pgfr_analyze._get_config(p_key text, p_default text)
RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT coalesce((SELECT value FROM pgfr_analyze.config WHERE key = p_key), p_default);
$$;

COMMENT ON FUNCTION pgfr_analyze._get_config(text, text) IS
    'Reads a tunable threshold from pgfr_analyze.config, falling back to p_default when the key is unset.';
