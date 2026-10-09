#!/usr/bin/env sh
# Fetch the Italian MASE weekly fuel-price report, validate it fail-closed,
# and convert it to a header-less CSV at $OUTPUT (EUR/1000 L -> EUR/L).
#
# On any validation failure this script exits 1 and leaves $OUTPUT untouched.
set -eu

MASE_URL="${MASE_URL:-https://sisen.mase.gov.it/dgsaie/api/v1/weekly-prices/report/export?format=JSON&lang=it}"
MIN_ROWS="${MIN_ROWS:-1000}"
MAX_AGE_DAYS="${MAX_AGE_DAYS:-14}"
OUTPUT="${OUTPUT:-/tmp/fuel-prices.csv}"

DATA_FILE="$(mktemp)"
CSV_FILE="$(mktemp)"
trap 'rm -f "$DATA_FILE" "$CSV_FILE"' EXIT

echo "Downloading weekly fuel prices..."
curl -fsSL --retry 3 --retry-delay 5 \
  -A "Mozilla/5.0" -H "Accept: application/json" \
  "$MASE_URL" -o "$DATA_FILE"

# Fail closed on a valid-JSON-but-wrong-shape response, before any write.
if ! jq -e 'type=="array" and length>0 and all(.[]; has("DATA_RILEVAZIONE") and has("BENZINA") and has("GASOLIO_AUTO"))' "$DATA_FILE" >/dev/null; then
  echo "ERROR: unexpected MASE response shape" >&2
  exit 1
fi

ROWS="$(jq 'length' "$DATA_FILE")"
LAST="$(jq -r '[.[].DATA_RILEVAZIONE] | max' "$DATA_FILE")"
AGE_DAYS="$(jq '((now - (([.[].DATA_RILEVAZIONE] | max) + "T00:00:00Z" | fromdateiso8601)) / 86400 | floor)' "$DATA_FILE")"
echo "Downloaded rows=$ROWS last=$LAST age_days=$AGE_DAYS"

if [ "$ROWS" -lt "$MIN_ROWS" ]; then
  echo "ERROR: only $ROWS rows in response; refusing to update the price data." >&2
  exit 1
fi

if [ "$AGE_DAYS" -gt "$MAX_AGE_DAYS" ]; then
  echo "ERROR: newest price is $AGE_DAYS days old; refusing to update the price data." >&2
  exit 1
fi

echo "Converting JSON to CSV (EUR/1000L -> EUR/L)..."
jq -r '
  def eur_l(k): if .[k] == null then null else (.[k] | tonumber / 1000) end;
  .[] | [
    .["DATA_RILEVAZIONE"],
    eur_l("BENZINA"),
    eur_l("GASOLIO_AUTO"),
    eur_l("GPL"),
    eur_l("METANO"),
    eur_l("GNL"),
    eur_l("GASOLIO_RISCALDAMENTO"),
    eur_l("O.C._FLUIDO_BTZ"),
    eur_l("O.C._DENSO_BTZ")
  ] | @csv' "$DATA_FILE" > "$CSV_FILE"

mv "$CSV_FILE" "$OUTPUT"
echo "Wrote $(wc -l < "$OUTPUT") rows to $OUTPUT"
