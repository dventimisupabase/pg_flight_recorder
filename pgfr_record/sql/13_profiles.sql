-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- Profiles (§9): reduced to cadence + bounds. apply_profile(name) remaps
-- tiers and bounds; it never touches the manifest.
--
-- profile_tiers.job_timeout < tier_interval is a real CHECK constraint,
-- not just a convention: this is §5's overrun-protection invariant
-- ("job_timeout(tier) < tier_interval(tier)"), enforced at the data
-- layer so a bad profile row cannot be inserted in the first place,
-- rather than merely documented (§10.1 acceptance criterion 6).
CREATE TABLE IF NOT EXISTS pgfr_record.profiles (
  profile_name    text PRIMARY KEY,
  lock_timeout    interval NOT NULL,
  section_timeout interval NOT NULL,
  notes           text
);

CREATE TABLE IF NOT EXISTS pgfr_record.profile_tiers (
  profile_name  text NOT NULL REFERENCES pgfr_record.profiles ON DELETE CASCADE,
  cadence_tier  text NOT NULL CHECK (cadence_tier IN ('fast','medium','slow','on_change')),
  tier_interval interval NOT NULL,
  job_timeout   interval NOT NULL,
  PRIMARY KEY (profile_name, cadence_tier),
  CHECK (job_timeout < tier_interval)
);

COMMENT ON TABLE pgfr_record.profiles IS
    'Profile-level bounds (lock_timeout, section_timeout). §9: reduced to cadence + bounds; apply_profile() never touches the manifest.';
COMMENT ON TABLE pgfr_record.profile_tiers IS
    'Per-tier cadence + job_timeout for each profile. job_timeout < tier_interval is enforced by CHECK constraint, not convention (§5, §10.1 acceptance criterion 6).';

INSERT INTO pgfr_record.profiles (profile_name, lock_timeout, section_timeout, notes) VALUES
    ('default', interval '100 ms', interval '250 ms', 'the shipped default (§9)'),
    ('troubleshooting', interval '100 ms', interval '500 ms', 'tighter fast/medium cadence for active incident work; looser section timeouts (§9)')
ON CONFLICT (profile_name) DO NOTHING;

INSERT INTO pgfr_record.profile_tiers (profile_name, cadence_tier, tier_interval, job_timeout) VALUES
    ('default', 'fast',      interval '1 minute',  interval '45 seconds'),
    ('default', 'medium',    interval '5 minutes', interval '4 minutes'),
    ('default', 'slow',      interval '15 minutes',interval '12 minutes'),
    ('default', 'on_change', interval '5 minutes', interval '4 minutes'),
    ('troubleshooting', 'fast',      interval '20 seconds', interval '15 seconds'),
    ('troubleshooting', 'medium',    interval '1 minute',   interval '45 seconds'),
    ('troubleshooting', 'slow',      interval '15 minutes', interval '12 minutes'),
    ('troubleshooting', 'on_change', interval '5 minutes',  interval '4 minutes')
ON CONFLICT (profile_name, cadence_tier) DO NOTHING;

-- pg_cron accepts two schedule syntaxes: standard 5-field crontab
-- (minute granularity) and a literal "N seconds" form for sub-minute
-- jobs (confirmed against a live container: it schedules and fires
-- correctly). This only needs to render clean whole-minute or
-- whole-second-under-a-minute intervals -- the only shapes any profile
-- above, or any profile a reasonable operator would define, actually
-- uses.
CREATE OR REPLACE FUNCTION pgfr_record._interval_to_cron(p_interval interval)
RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_seconds int := extract(epoch FROM p_interval)::int;
BEGIN
    IF v_seconds <= 0 THEN
        RAISE EXCEPTION 'pgfr_record._interval_to_cron: interval must be positive, got %', p_interval;
    ELSIF v_seconds < 60 THEN
        RETURN v_seconds || ' seconds';
    ELSIF v_seconds % 60 <> 0 THEN
        RAISE EXCEPTION 'pgfr_record._interval_to_cron: % is not a whole number of minutes or a sub-minute second count', p_interval;
    ELSE
        RETURN '*/' || (v_seconds / 60) || ' * * * *';
    END IF;
END;
$$;

-- Inverse of _interval_to_cron(), for health_check()'s "is the last
-- capture stale relative to this tier's own scheduled interval" check --
-- reads the interval back from cron.job's live schedule text rather than
-- assuming a fixed one, so health_check() stays correct under whichever
-- profile is actually applied. Returns NULL for a schedule shape it
-- cannot parse (the caller falls back to a conservative default).
CREATE OR REPLACE FUNCTION pgfr_record._cron_schedule_to_interval(p_schedule text)
RETURNS interval
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_match text[];
BEGIN
    IF p_schedule IS NULL THEN
        RETURN NULL;
    END IF;

    v_match := regexp_match(p_schedule, '^(\d+)\s+seconds$');
    IF v_match IS NOT NULL THEN
        RETURN (v_match[1] || ' seconds')::interval;
    END IF;

    IF p_schedule = '* * * * *' THEN
        RETURN interval '1 minute';
    END IF;

    v_match := regexp_match(p_schedule, '^\*/(\d+) \* \* \* \*$');
    IF v_match IS NOT NULL THEN
        RETURN (v_match[1] || ' minutes')::interval;
    END IF;

    RETURN NULL;
END;
$$;

-- apply_profile(): (re)schedules the four tier jobs to match the named
-- profile's cadence and bounds. cron.schedule() replaces a same-named
-- job, so this is idempotent and safe to call repeatedly (including to
-- switch profiles -- there is no separate "currently active profile"
-- state to keep in sync: cron.job's live schedule/command *is* the
-- source of truth for what is currently applied). Never touches the
-- manifest or capture_plan.
CREATE OR REPLACE FUNCTION pgfr_record.apply_profile(p_profile_name text)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_profile record;
    v_tier    record;
BEGIN
    SELECT * INTO v_profile FROM pgfr_record.profiles WHERE profile_name = p_profile_name;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'pgfr_record.apply_profile: unknown profile %', p_profile_name;
    END IF;

    FOR v_tier IN SELECT * FROM pgfr_record.profile_tiers WHERE profile_name = p_profile_name LOOP
        PERFORM cron.schedule(
            'pgfr_tier_' || v_tier.cadence_tier,
            pgfr_record._interval_to_cron(v_tier.tier_interval),
            format(
                'SELECT pgfr_record.run_tier(%L, %L::interval, %L::interval, %L::interval)',
                v_tier.cadence_tier, v_profile.lock_timeout, v_tier.job_timeout, v_profile.section_timeout
            )
        );
        -- cron.schedule() on an already-existing job updates its
        -- schedule/command but preserves whatever `active` it already
        -- had (confirmed against a live container) -- it does not
        -- reactivate a previously deactivated job. Applying a profile is
        -- an explicit "run this tier" instruction, so make that true
        -- regardless of prior state.
        UPDATE cron.job SET active = true WHERE jobname = 'pgfr_tier_' || v_tier.cadence_tier;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION pgfr_record.apply_profile(text) IS
    'Reschedules the four tier pg_cron jobs to the named profile''s cadence and bounds. Idempotent (cron.schedule() replaces a same-named job); never touches the manifest. There is no separate "active profile" marker -- cron.job''s live schedule/command is the source of truth for what is currently applied.';
