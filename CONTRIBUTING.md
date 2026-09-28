# Contributing to pg_flight_recorder

Thanks for your interest in contributing.

## Contents

- [License of contributions](#license-of-contributions)
- [Before you open a PR](#before-you-open-a-pr)
- [Reporting issues](#reporting-issues)
- [Source file headers](#source-file-headers)

## License of contributions

By submitting a pull request, issue patch, or any other contribution to this
project, you agree that your contribution is licensed under the [Apache License,
Version 2.0](LICENSE) — the same license that covers the rest of the project.

No separate Contributor License Agreement (CLA) is required. Section 5 of the
Apache 2.0 license makes this automatic: unless you explicitly state otherwise,
contributions you submit for inclusion in this Work are licensed under the same
terms as the Work itself.

If you are contributing on behalf of an employer, please ensure you have the
authority to license the contribution under Apache 2.0.

## Before you open a PR

- Read [CLAUDE.md](CLAUDE.md) for project conventions: markdown formatting
  rules, schema evolution policy (additive-only), code style, and the
  two-extension structure (`pgfr_record` writes; `pgfr_analyze` reads only).
- Run the test suite locally: `./test.sh` runs the pgTAP suite across
  PostgreSQL 15, 16, 17, and 18 in Docker.
- For changes to the SQL extensions, add or update pgTAP tests in
  `pgfr_record/tests/` or `pgfr_analyze/tests/`.

## Reporting issues

Open an issue at <https://github.com/dventimisupabase/pg_flight_recorder/issues>.
For bug reports, please include:

- PostgreSQL version
- The output of `SELECT * FROM pgfr_record.health_check();`
- Steps to reproduce, or a minimal SQL repro if applicable

## Source file headers

New SQL source files in `pgfr_record/` or `pgfr_analyze/` (excluding tests)
should begin with the standard SPDX header:

```sql
-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia
```
