# Project Guidelines

## Git Workflow

Branches follow [Conventional Branches](https://conventional-branch.github.io/): `<type>/<short-description>`, where `<type>` matches Conventional Commits (`feat`, `fix`, `docs`, `chore`, `refactor`, `test`, `perf`, `build`, `ci`, `style`, `revert`) and the description is kebab-case (e.g., `docs/improvements`, `feat/wraparound-monitoring`).

## Project Structure

Two extensions, each in its own subdirectory:

| Directory   | Extension      | Schema         | Purpose                                                  |
|-------------|----------------|----------------|----------------------------------------------------------|
| `pgfr_record/`  | `pgfr_record`  | `pgfr_record`  | Core: tables, collection, scheduling, ring buffers       |
| `pgfr_analyze/` | `pgfr_analyze` | `pgfr_analyze` | Optional: reporting, anomaly detection, time travel      |

Each subdirectory contains:

- `install.sql` — extension SQL
- `uninstall.sql` — `DROP SCHEMA ... CASCADE`
- `extension.control` — dbdev metadata (renamed to `pgfr_*.control` at publish time)
- `docker-compose.yml` — extension-specific volume mounts (merged with root via `-f`)
- `tests/` — pgTAP test files
- `README.md`

Other key files:

- `test.sh` — runs all tests on PG 15/16/17 via Docker
- `docker-compose.yml` — base test infrastructure (services, build, env, healthcheck, data volumes)

Docker Compose files are merged at invocation time: `test.sh` passes `-f docker-compose.yml -f pgfr_record/docker-compose.yml -f pgfr_analyze/docker-compose.yml`. Volume paths in extension compose files are relative to the project root (Docker Compose resolves all `-f` file paths relative to the first file's directory).

## Markdown Formatting

When writing or editing markdown files, follow these rules to pass linting:

- **Blank lines around blocks**: Always add a blank line before and after:
  - Lists (bulleted or numbered)
  - Headings
  - Fenced code blocks

- **List markers**: Use dashes (`-`) for unordered lists, not asterisks (`*`)

- **Indentation**: Use 2 spaces for nested list items

- **Table of contents**: Every authored, reader-facing markdown file needs a table of contents near the top, after the title and any intro paragraph and before the first section. Link to every top-level (`##`) heading. Skip this for auto-generated report output and one-off process notes, where a TOC doesn't serve a reader.

### Example

Wrong:

````markdown
**Some header text:**
- Item 1
- Item 2
#### Subheading
```code
example
```
````

Right:

````markdown
**Some header text:**

- Item 1
- Item 2

#### Subheading

```code
example
```
````

## Testing

Run tests with:

```bash
./test.sh
```

Tests are distributed across extension subdirectories:

- `pgfr_record/tests/` — 14 test files (core)
- `pgfr_analyze/tests/` — 4 test files (reporting/analysis)

## Code Style

- Follow existing patterns in the relevant `install.sql`
- Use the correct schema prefix: `pgfr_record.` for core, `pgfr_analyze.` for analyze
- Include COMMENT ON statements for new functions and tables
- Extensions read core tables cross-schema (e.g., `pgfr_record.snapshots`) but never write to another extension's schema

## Schema Evolution

pgfr_record uses **additive-only schema changes**:

- Add new nullable columns (never remove or rename existing ones)
- Historical data with NULL in new columns is correct ("not collected then")
- Re-running `pgfr_record/install.sql` is the upgrade path (uses `CREATE OR REPLACE` / `IF NOT EXISTS`)

**Why not JSONB + versioning?**

- Query performance matters during incident analysis
- Strong typing catches errors early
- Schema-as-documentation (`\d pgfr_record.snapshots` shows what's collected)
- Underlying pg_stat_* views evolve slowly and additively
