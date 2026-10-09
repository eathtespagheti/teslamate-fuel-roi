#!/usr/bin/env sh
# Import the header-less fuel-price CSV produced by fetch.sh into Postgres.
#
# Idempotent by design: rows are copied into a staging table and merged into
# fuel.prices with ON CONFLICT (rilevazione) DO NOTHING, so re-running over the
# same (or an overlapping) CSV inserts only previously unseen dates.
#
# libpq's standard environment variables are honoured (PGHOST, PGPORT, PGUSER,
# PGPASSWORD, PGDATABASE); no connection flags are passed to psql. The input
# CSV defaults to fetch.sh's $OUTPUT default.
set -eu

INPUT="${INPUT:-/tmp/fuel-prices.csv}"

echo "Ensuring schema and table..."
psql -v ON_ERROR_STOP=1 <<'SQL'
CREATE SCHEMA IF NOT EXISTS fuel;
CREATE TABLE IF NOT EXISTS fuel.prices (
  rilevazione           date PRIMARY KEY,
  benzina               numeric(8,5),
  gasolio_auto          numeric(8,5),
  gpl                   numeric(8,5),
  metano                numeric(8,5),
  gnl                   numeric(8,5),
  gasolio_riscaldamento numeric(8,5),
  oc_fluido_btz         numeric(8,5),
  oc_denso_btz          numeric(8,5)
);
SQL

echo "Staging downloaded rows..."
psql -v ON_ERROR_STOP=1 \
  -c "DROP TABLE IF EXISTS fuel.prices_stage; CREATE TABLE fuel.prices_stage (LIKE fuel.prices);"
psql -v ON_ERROR_STOP=1 \
  -c "COPY fuel.prices_stage (rilevazione, benzina, gasolio_auto, gpl, metano, gnl, gasolio_riscaldamento, oc_fluido_btz, oc_denso_btz) FROM STDIN WITH (FORMAT csv, NULL '');" < "$INPUT"

echo "Inserting only new rows (ON CONFLICT DO NOTHING)..."
NEW="$(psql -v ON_ERROR_STOP=1 -tAc \
  "WITH ins AS (INSERT INTO fuel.prices SELECT * FROM fuel.prices_stage ON CONFLICT (rilevazione) DO NOTHING RETURNING 1) SELECT count(*) FROM ins;")"
psql -v ON_ERROR_STOP=1 \
  -c "DROP TABLE fuel.prices_stage;"
echo "Inserted ${NEW} new row(s)"

echo "Verifying..."
psql -tAc \
  "SELECT 'rows=' || count(*) || ' first=' || min(rilevazione) || ' last=' || max(rilevazione) || ' avg_diesel_eur_l=' || round(avg(gasolio_auto), 4) FROM fuel.prices;"
echo "Done."
