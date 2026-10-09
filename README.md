# teslamate-fuel-roi

## What it is

`teslamate-fuel-roi` loads Italy's official weekly fuel prices into your
TeslaMate Postgres and ships two Grafana dashboards that turn TeslaMate's trip
data into fuel cost avoided and EV return on investment.

**This project is Italy-only.** The price source is the Italian MASE
(Ministero dell'Ambiente e della Sicurezza Energetica) weekly report, and the
`fuel.prices` table stores exactly its columns. A country/provider abstraction
is explicitly out of scope; the feed, schema, and dashboards all assume Italian
fuel prices, so this will not work unchanged outside Italy.

One container runs `fetch.sh` then `import.sh` in a single pass: it downloads
and fail-closed-validates the MASE report, converts it to CSV, and upserts
previously unseen weeks into a `fuel.prices` table alongside your existing
TeslaMate data. Run it weekly from Docker Compose via host cron or a systemd
timer, or as a Kubernetes `CronJob`. The `ev-fuel-savings` dashboard reports
gross and net fuel savings; `ev-roi` tracks net savings against a configurable EV
purchase price and estimates a break-even date.

The design and plan for this extraction are maintained by the author and are
not published at a public URL.

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

## Build the image

Build the `teslamate-fuel-roi:dev` image from the repository root:

```sh
docker build -f docker/Dockerfile -t teslamate-fuel-roi:dev .
```

The Compose service below also declares a `build:` context and builds this image
automatically when it is missing. For Kubernetes the image must be made
available to the cluster — see [`kubernetes/README.md`](kubernetes/README.md).

## Quick start (Docker Compose)

From the `docker/` directory, copy the example environment file and fill in your
TeslaMate Postgres credentials (`.env` is gitignored):

```sh
cd docker
cp .env.example .env
$EDITOR .env          # set PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE
```

Then run one fetch-and-import cycle:

```sh
docker compose run --rm fuel-roi
```

The `fuel-roi` service is a one-shot job: the image's entrypoint runs
`fetch.sh` then `import.sh` and the container exits. There is no long-running
scheduler container — run it weekly from the host with cron or a systemd timer.
For example, this cron line runs it every Monday at 20:00, after MASE publishes
the weekly report:

```
0 20 * * 1  cd /path/to/teslamate-fuel-roi/docker && docker compose run --rm fuel-roi
```

## Quick start (Kubernetes)

From the repository root, create the database Secret and apply the Kustomize
overlay:

```sh
# PGPASSWORD must already be exported in your shell to your TeslaMate DB password.
kubectl -n teslamate create secret generic fuel-roi-db \
  --from-literal=PGHOST=teslamate-postgres-rw \
  --from-literal=PGPORT=5432 \
  --from-literal=PGUSER=teslamate \
  --from-literal=PGPASSWORD="$PGPASSWORD" \
  --from-literal=PGDATABASE=teslamate

kubectl apply -k kubernetes/
```

The overlay deploys a single `CronJob` named `fuel-roi` that runs every Monday
at 20:00, fetching and importing the MASE report in one container run. Its
default namespace is `teslamate` (TeslaMate's namespace); change it in
`kubernetes/kustomization.yaml` if your TeslaMate runs elsewhere. The container
takes its connection details from the `fuel-roi-db` Secret, which must use the
`PG*` keys shown above — reusing CloudNativePG's `teslamate-postgres-app` Secret
directly does not work because `envFrom` cannot rename its keys. See
[`kubernetes/README.md`](kubernetes/README.md) for the full walkthrough,
including the CNPG mapping.

## Dashboards

Two Grafana dashboards live in `dashboards/` as provision-ready JSON:

- **`ev-fuel-savings.json`** (UID `ev-fuel-savings`) — gross and net fuel
  savings. Stat panels show distance driven, litres of fuel avoided, and the
  fuel cost avoided; the `Weekly gross and net savings` timeseries (and the
  `Fuel prices comparison` row) break it down over time.
- **`ev-roi.json`** (UID `ev-roi`) — return on investment against the EV
  purchase price: net savings in range, average weekly net savings, a
  break-even progress gauge, distance driven, the estimated break-even date,
  and cumulative/weekly savings timeseries.

Both dashboards read TeslaMate's Postgres tables plus the `fuel.prices` table
created by this project, through a datasource whose UID is **`TeslaMate`**.
Before importing, point them at your own datasource: either keep your
TeslaMate/CloudNativePG datasource UID as `TeslaMate`, or edit the `uid` values
in the JSON files to match. The `fuel.prices` rows must be imported first (see
above) or the price panels will be empty.

`purchase_cost` is a text-box variable on the ROI dashboard (the hidden
`purchase_cost_neg` variable is derived from it). It defaults to the example
`30000` (EUR) in the committed JSON — **set your own** EV purchase price, either
in Grafana (`Dashboard settings → Variables → purchase_cost`) or by editing the
`purchase_cost` `query`/`current` in `dashboards/ev-roi.json`.

To provision the dashboards, see
[`dashboards/provisioning.example.yaml`](dashboards/provisioning.example.yaml):
copy the JSON files and the provider YAML into your Grafana provisioning
directory (`/etc/grafana/provisioning/dashboards`) and restart Grafana.

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

This project is **not affiliated with, sponsored by, or endorsed by
TeslaMate**. It reads from a TeslaMate Postgres database, and the dashboards
query TeslaMate's tables, but it does not modify TeslaMate itself.
[TeslaMate](https://github.com/teslamate/teslamate) is licensed under the
**AGPL-3.0**; this project and its dashboards are independent works released
under the **MIT** license (see [`LICENSE`](LICENSE)).

The fuel prices come from the Italian **MASE** (Ministero dell'Ambiente e della
Sicurezza Energetica) weekly price report. The feed is fetched **at runtime** by
`fetch.sh`; no MASE dataset is committed to this repository or redistributed.
You are responsible for complying with MASE's own reuse and attribution terms.

To stay clear of TeslaMate's AGPL-3.0 licensing, the upstream Trip dashboard's
"Comparison with ICE" panel is **intentionally not included** in this project.

Released under the MIT License — see [`LICENSE`](LICENSE).

