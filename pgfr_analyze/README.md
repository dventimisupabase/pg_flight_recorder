# pgfr_analyze

Optional reporting and analysis extension for [pgfr_record](https://github.com/dventimisupabase/pg_flight_recorder). Reads `pgfr_record`'s captured data and definitional helpers; never writes to the core schema.

## Contents

- [Status](#status)
- [What it's designed to own](#what-its-designed-to-own)
- [Install](#install)
- [Related](#related)

## Status

Not yet rebuilt for pgfr v2. The schema exists as a placeholder: `CREATE SCHEMA pgfr_analyze` with a `COMMENT ON SCHEMA` explaining the deferral, and no tables, views, or functions. This keeps the two-extension install pipeline working while `pgfr_analyze` is built out, and lets `pgfr_record` ship and be useful on its own in the meantime: everything definitional (what was captured, its shape, what kind of quantity each column is, how identity resolves over time) lives in `pgfr_record`, so a `pgfr_record`-only install already answers real troubleshooting questions. See [REFERENCE.md](../REFERENCE.md#pgfr_analyze) and [pgfr_record/README.md](../pgfr_record/README.md).

## What it's designed to own

Everything requiring a threshold, baseline, or opinion, consuming `pgfr_record`'s column classes and definitional helpers, owning none of them: anomaly, regression, and storm detection; trend analysis; capacity views; and `report()`, a markdown diagnostic report for a time window. See `pgfr-v2-context-pack.md`'s Appendix for the full design.

## Install

Requires `pgfr_record` installed first:

```bash
psql --single-transaction -f pgfr_record/install.sql
psql --single-transaction -f pgfr_analyze/install.sql
```

Currently installs the placeholder schema only.

## Related

- [Top-level README](../README.md): project overview and the two-extension structure.
- [pgfr_record/README.md](../pgfr_record/README.md): the required core extension.
- [REFERENCE.md](../REFERENCE.md): the full technical reference.
