# pg_flight_recorder

[![GitHub release](https://img.shields.io/github/v/release/dventimisupabase/pg_flight_recorder)](https://github.com/dventimisupabase/pg_flight_recorder/releases/latest)
[![Test Suite](https://github.com/dventimisupabase/pg_flight_recorder/actions/workflows/test.yml/badge.svg)](https://github.com/dventimisupabase/pg_flight_recorder/actions/workflows/test.yml)
[![Lint](https://github.com/dventimisupabase/pg_flight_recorder/actions/workflows/lint.yml/badge.svg)](https://github.com/dventimisupabase/pg_flight_recorder/actions/workflows/lint.yml)

Server-side flight recorder for PostgreSQL. Answers "what was happening in my database?"

**[View the project website](https://dventimisupabase.github.io/pg_flight_recorder/)**

pg_flight_recorder continuously appends PostgreSQL's own stats views and system views into time-partitioned tables via `pg_cron`, no external agent, sidecar, or polling process required. Every archive table, typed view, and column classification is generated from one table (`pgfr_record.manifest`) plus the live catalog, so the whole install is one design artifact rather than a hand-maintained schema. Retention is partition drop; nothing is ever `UPDATE`d or `DELETE`d.

## Contents

- [Extensions](#extensions)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Documentation](#documentation)
- [Testing](#testing)
- [License](#license)

## Extensions

Two extensions:

| Extension | Schema | Status | Purpose |
|---|---|---|---|
| [pgfr_record](pgfr_record/README.md) | `pgfr_record` | Required, stable | Core: the manifest, capture, partitioning, retention, and the definitional helpers needed to reconstruct history |
| [pgfr_analyze](pgfr_analyze/README.md) | `pgfr_analyze` | Optional, stable | Reporting, anomaly detection, capacity views, and the diagnostic `report()` |

`pgfr_analyze` only ever reads from `pgfr_record`; it never writes to the core schema. `pgfr_record` alone, or a `pg_dump` of it, is fully self-contained: a dump restored into an empty database on a different PostgreSQL major, with the typed views regenerated offline and no `pgfr_analyze` object present, is enough to answer real troubleshooting questions using nothing but psql (`scripts/agent_test.sh` proves exactly this end to end). `pgfr_analyze` makes conclusions faster; it is not required to reach them.

## Requirements

- PostgreSQL 15, 16, 17, or 18
- The `pg_cron` extension
- Optional: `pg_stat_statements`, for per-query capture

## Quick start

```bash
psql --single-transaction -f pgfr_record/install.sql
```

```sql
-- install.sql already calls enable(); this just confirms it.
SELECT * FROM pgfr_record.health_check();
```

Other install channels (single-file bundle for SQL editors, [dbdev](https://database.dev)) and a full quick start are in [pgfr_record/README.md](pgfr_record/README.md).

## Documentation

- [pgfr_record/README.md](pgfr_record/README.md): what it is, how to install it, and the design's pitch (append-only, the record/analyze boundary and agent test, no adaptive safety mechanisms).
- [REFERENCE.md](REFERENCE.md): the full technical reference, every table, view, and function.
- [STATISTICS.md](STATISTICS.md): what's collected, in what shape, and why.
- [pgfr_analyze/README.md](pgfr_analyze/README.md): the optional analysis extension.

## Testing

```bash
./test.sh              # PostgreSQL 15-18, all three install channels, in parallel
./test.sh 17            # one version
./test.sh --channel=psql # one channel, all versions
```

## License

Licensed under the [Apache License, Version 2.0](LICENSE). See [NOTICE](NOTICE) for attribution.
