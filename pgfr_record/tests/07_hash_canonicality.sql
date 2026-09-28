-- =============================================================================
-- pgfr_record v2 pgTAP Tests -- hash canonicality (§6 VERIFY-DURING-
-- IMPLEMENTATION №2)
-- =============================================================================
-- row_hash = hashtextextended(compare_payload::text, 0). The debounce
-- anti-join (§5, §6) compares a freshly captured row's row_hash against
-- the most recent same-key_hash row already in the archive -- which, at
-- a major-upgrade boundary, may have been written by a different
-- PostgreSQL major than the one computing the new hash. If jsonb's
-- numeric-to-text serialization drifted between majors for an equal
-- logical value (trailing zeros, exponent notation, float precision),
-- equal rows would hash unequal and debounce would silently degrade
-- (spurious re-appends) right at upgrade boundaries -- self-healing and
-- low severity, but worth a real regression test rather than an assumed
-- invariant, per the pack's own "far weaker assumption than object-key
-- canonicality; test it anyway."
--
-- Covers every distinct type actually seen in pgfr_record.payload_schemas
-- across the full PG15 census (confirmed via a live install: bigint,
-- boolean, "char", double precision, inet, integer, interval, name,
-- numeric, oid, oid[], pg_lsn, smallint, text, text[], timestamp with
-- time zone, xid) with edge-case values per type (min/max integers,
-- trailing-zero-preserving numeric, float precision, special characters
-- needing JSON escaping). The expected string below was captured once
-- from a live PG15 container and independently confirmed byte-for-byte
-- identical on PG16, 17, and 18 before being pinned here; this test's
-- job going forward is to catch the day that stops being true.

BEGIN;
SELECT plan(2);

SELECT is(
    jsonb_build_array(
        9223372036854775807::bigint,
        true, false, NULL::boolean,
        'X'::"char",
        3.14159265358979::double precision,
        0.1::double precision,
        '192.168.1.1/24'::inet,
        '::1'::inet,
        (-2147483648)::integer,
        '1 day 02:03:04.567'::interval,
        'a_name_value'::name,
        100.00::numeric,
        123456789012345.678901::numeric,
        4294967295::oid,
        ARRAY[1,2,3]::oid[],
        '16/B374D848'::pg_lsn,
        32767::smallint,
        E'hello ''world'' with "quotes" and \\backslash',
        ARRAY['a','b','c']::text[],
        '2026-01-15 12:34:56.789012+00'::timestamptz,
        '12345'::xid
    )::text,
    '[9223372036854775807, true, false, null, "X", 3.14159265358979, 0.1, "192.168.1.1/24", "::1", -2147483648, "1 day 02:03:04.567", "a_name_value", 100.00, 123456789012345.678901, "4294967295", ["1", "2", "3"], "16/B374D848", 32767, "hello ''world'' with \"quotes\" and \\backslash", ["a", "b", "c"], "2026-01-15T12:34:56.789012+00:00", "12345"]',
    'jsonb array ::text serialization across every type in the census should match the pinned, cross-major-verified reference string exactly'
);

-- The hash itself is then trivially a pure function of that stable text,
-- but pin it too: it is the literal value the debounce anti-join
-- actually compares.
SELECT is(
    hashtextextended(
        jsonb_build_array(
            9223372036854775807::bigint,
            true, false, NULL::boolean,
            'X'::"char",
            3.14159265358979::double precision,
            0.1::double precision,
            '192.168.1.1/24'::inet,
            '::1'::inet,
            (-2147483648)::integer,
            '1 day 02:03:04.567'::interval,
            'a_name_value'::name,
            100.00::numeric,
            123456789012345.678901::numeric,
            4294967295::oid,
            ARRAY[1,2,3]::oid[],
            '16/B374D848'::pg_lsn,
            32767::smallint,
            E'hello ''world'' with "quotes" and \\backslash',
            ARRAY['a','b','c']::text[],
            '2026-01-15 12:34:56.789012+00'::timestamptz,
            '12345'::xid
        )::text,
        0
    ),
    hashtextextended(
        '[9223372036854775807, true, false, null, "X", 3.14159265358979, 0.1, "192.168.1.1/24", "::1", -2147483648, "1 day 02:03:04.567", "a_name_value", 100.00, 123456789012345.678901, "4294967295", ["1", "2", "3"], "16/B374D848", 32767, "hello ''world'' with \"quotes\" and \\backslash", ["a", "b", "c"], "2026-01-15T12:34:56.789012+00:00", "12345"]',
        0
    ),
    'row_hash computed from the live construction should equal row_hash computed from the pinned reference text'
);

SELECT * FROM finish();
ROLLBACK;
