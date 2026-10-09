#!/usr/bin/env sh
# Test suite for teslamate-fuel-roi.
#
# Runs every test_* function and prints "PASS <name>" / "FAIL <name>".
# Exits non-zero if any test failed. No network access is required: the
# download tests point MASE_URL at local file:// fixtures.

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

fail=0
assert_eq() { [ "$1" = "$2" ] || { echo "  expected [$2] got [$1]"; fail=1; }; }

test_fetch_success() {
  out="$(mktemp)"; rm -f "$out"
  if OUTPUT="$out" MASE_URL="file://$ROOT/test/fixture.json" MIN_ROWS=1 MAX_AGE_DAYS=100000 \
       sh "$ROOT/scripts/fetch.sh" >/dev/null 2>&1; then assert_eq 0 0; else assert_eq "exit0" "exit$?"; fi
  assert_eq "$(wc -l < "$out" | tr -d ' ')" "3"
  assert_eq "$(sed -n 1p "$out")" '"2026-01-05",1.8,1.7,0.7,1.5,1.6,1.2,0.9,0.95'
  assert_eq "$(sed -n 2p "$out")" '"2026-01-12",1.81,1.71,,1.51,1.61,1.21,0.91,0.96'
  rm -f "$out"
}

test_fetch_short_response_fails() {
  out="$(mktemp)"; rm -f "$out"
  if OUTPUT="$out" MASE_URL="file://$ROOT/test/fixture.json" MIN_ROWS=10 MAX_AGE_DAYS=100000 \
       sh "$ROOT/scripts/fetch.sh" >/dev/null 2>&1; then assert_eq "fail" "ok"; else assert_eq "ok" "ok"; fi
  [ -e "$out" ] && assert_eq "no-output" "output-written"
  rm -f "$out"
}

test_fetch_stale_fails() {
  out="$(mktemp)"; rm -f "$out"
  if OUTPUT="$out" MASE_URL="file://$ROOT/test/fixture.json" MIN_ROWS=1 MAX_AGE_DAYS=1 \
       sh "$ROOT/scripts/fetch.sh" >/dev/null 2>&1; then assert_eq "fail" "ok"; else assert_eq "ok" "ok"; fi
  [ -e "$out" ] && assert_eq "no-output" "output-written"
  rm -f "$out"
}

test_fetch_unexpected_shape_fails() {
  out="$(mktemp)"; rm -f "$out"
  if OUTPUT="$out" MASE_URL="file://$ROOT/test/fixture-bad-shape.json" MIN_ROWS=1 MAX_AGE_DAYS=100000 \
       sh "$ROOT/scripts/fetch.sh" >/dev/null 2>&1; then assert_eq "fail" "ok"; else assert_eq "ok" "ok"; fi
  [ -e "$out" ] && assert_eq "no-output" "output-written"
  rm -f "$out"
}

# Import tests need a reachable throwaway Postgres. The psql client and
# import.sh read PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE from the
# environment; when PGHOST is unset this test is SKIPped (see the runner at
# the bottom) so the fetch-only suite still runs without a database.
test_import_loads_and_is_idempotent() {
  psql -c 'DROP SCHEMA IF EXISTS fuel CASCADE' >/dev/null
  csv="$(mktemp)"
  OUTPUT="$csv" MASE_URL="file://$ROOT/test/fixture.json" MIN_ROWS=1 MAX_AGE_DAYS=100000 sh "$ROOT/scripts/fetch.sh" >/dev/null
  PGPASSWORD="${PGPASSWORD:-}" INPUT="$csv" sh "$ROOT/scripts/import.sh" >/dev/null
  assert_eq "$(psql -tAc 'SELECT count(*) FROM fuel.prices')" "3"
  assert_eq "$(psql -tAc "SELECT benzina FROM fuel.prices WHERE rilevazione='2026-01-05'")" "1.80000"
  assert_eq "$(psql -tAc "SELECT gpl IS NULL FROM fuel.prices WHERE rilevazione='2026-01-12'")" "t"
  if PGPASSWORD="${PGPASSWORD:-}" INPUT="$csv" sh "$ROOT/scripts/import.sh" 2>&1 | grep -q 'Inserted 0 new row(s)'; then
    assert_eq ok ok
  else
    assert_eq "idempotent-line-missing" "ok"
  fi
  assert_eq "$(psql -tAc 'SELECT count(*) FROM fuel.prices')" "3"
  rm -f "$csv"
}

# Run each test in isolation so one failure does not mask another.
TOTAL_FAIL=0
run_test() {
  name="$1"
  fail=0
  "$name"
  if [ "$fail" -eq 0 ]; then
    echo "PASS $name"
  else
    echo "FAIL $name"
    TOTAL_FAIL=1
  fi
}

run_test test_fetch_success
run_test test_fetch_short_response_fails
run_test test_fetch_stale_fails
run_test test_fetch_unexpected_shape_fails

if [ -n "${PGHOST:-}" ]; then
  run_test test_import_loads_and_is_idempotent
else
  echo "SKIP test_import_loads_and_is_idempotent (PGHOST unset)"
fi

exit "$TOTAL_FAIL"
