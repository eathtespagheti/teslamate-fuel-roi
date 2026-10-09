# teslamate-fuel-roi

## What it is

## Prerequisites

- A running TeslaMate Postgres, reachable through libpq's standard `PG*`
  environment variables (`PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`,
  `PGDATABASE`).
- A database user that can `CREATE SCHEMA fuel`. The image creates the schema
  and tables on first run; it only ever writes inside `fuel`.
- Outbound HTTPS to `sisen.mase.gov.it`, the MASE weekly-price feed.
- Docker, for the `teslamate-fuel-roi` image. Its entrypoint runs `fetch.sh`
  then `import.sh`, so one container run downloads the report, validates it,
  and imports any previously unseen dates.

## Quick start (Docker Compose)

## Quick start (Kubernetes)

## Dashboards

## Configuration

| Variable | Default | Notes |
| --- | --- | --- |
| `MASE_URL` | `https://sisen.mase.gov.it/dgsaie/api/v1/weekly-prices/report/export?format=JSON&lang=it` | MASE price source (read by `fetch.sh`) |
| `MIN_ROWS` | `1000` | Sanity guard: abort if the response has fewer rows; raise/lower for tests |
| `MAX_AGE_DAYS` | `14` | Staleness guard: abort if the newest `DATA_RILEVAZIONE` is older |
| `OUTPUT` | `/tmp/fuel-prices.csv` | CSV destination for `fetch.sh` |
| `INPUT` | `/tmp/fuel-prices.csv` | CSV source for `import.sh` (default matches `fetch.sh`'s `OUTPUT`) |
| `PGHOST` / `PGPORT` | — | libpq standard (read by `import.sh`) |
| `PGUSER` / `PGPASSWORD` | — | libpq standard |
| `PGDATABASE` | `teslamate` | libpq standard |

## How it works

`scripts/fetch.sh` downloads the Italian MASE weekly fuel-price report and
validates it fail-closed: the response must parse as a non-empty JSON array
whose rows carry the expected fields (`DATA_RILEVAZIONE`, `BENZINA`,
`GASOLIO_AUTO`, …), it must contain at least `MIN_ROWS` rows, and its newest
`DATA_RILEVAZIONE` must be no more than `MAX_AGE_DAYS` old. Only after every
check passes does it write the CSV — converting the eight price columns from
EUR/1000 L to EUR/L, preserving `null`s — to a temporary file and move it onto
`OUTPUT`. Any failure exits 1 and leaves `OUTPUT` untouched, so a broken, empty,
malformed, or stale MASE feed can never overwrite good data.

`scripts/import.sh` then stages that CSV into a throwaway `fuel.prices_stage`
table (dropped and recreated on every run) and merges it into `fuel.prices`
with `INSERT … ON CONFLICT (rilevazione) DO NOTHING`, so re-importing the same
or an overlapping file is idempotent and only previously unseen dates are
added. Connection details come from libpq's standard `PG*` environment
variables.

## Credits and license

