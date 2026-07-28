#!/bin/bash
# Check that SOURCE_DATE_EPOCH is validated up front, before anything is built.
#
# The validation block runs before the root check, so every case here can be
# exercised unprivileged: a rejected value prints its own diagnostic, while an
# accepted one falls through to "need root". That difference is the assertion.
#
# Usage: tests/source-date-epoch-validation-test.sh

set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GRML_DEBOOTSTRAP="$(dirname "$SCRIPT_DIR")/grml-debootstrap"

if [ "$(id -u)" -eq 0 ]; then
  echo "$0: refusing to run as root -- the accept cases rely on the root check to stop the run" >&2
  exit 1
fi

failures=0

# Run grml-debootstrap far enough to hit the validation block and report which
# diagnostic came out: 'range' / 'notinteger' / 'empty' for a rejected value,
# 'accepted' when it got past validation to the root check.
verdict_for() {
  local output
  output="$(SOURCE_DATE_EPOCH="$1" "$GRML_DEBOOTSTRAP" --vmfile --target /nonexistent/gd.img 2>&1 || true)"
  case "$output" in
    *'larger than INT64_MAX'*)      echo 'range' ;;
    *'is not a decimal integer'*)   echo 'notinteger' ;;
    *'set but empty'*)              echo 'empty' ;;
    *'need root'*|*'root permission'*|*'For usage instructions'*) echo 'accepted' ;;
    *) echo "unknown: $(printf '%s' "$output" | tail -1)" ;;
  esac
}

check() {
  local value="$1" expected="$2" actual
  actual="$(verdict_for "$value")"
  if [ "$expected" = "$actual" ]; then
    echo "ok   - SOURCE_DATE_EPOCH='${value}' -> ${actual}"
  else
    echo "FAIL - SOURCE_DATE_EPOCH='${value}': expected ${expected}, got ${actual}"
    failures=$((failures + 1))
  fi
}

echo '== rejected =='
check ''                     empty
check 'notanumber'           notinteger
check '0'                    notinteger       # zero is not a usable build timestamp
check '-1'                   notinteger
check '1.5'                  notinteger
check '0123'                 notinteger       # leading zero would read as octal
check ' 123'                 notinteger
check '9999999999999999999'  range            # 19 digits, wraps negative
check '18446744073709551616' range            # 2**64, wraps to 0, not negative
check '99999999999999999999' range            # 20 digits, wraps to a bogus positive

echo '== accepted =='
check '1'                    accepted         # single digit must not be rejected
check '9'                    accepted
check '1767225600'           accepted
check '9223372036854775807'  accepted         # INT64_MAX itself

echo
if [ "$failures" -eq 0 ]; then
  echo 'source-date-epoch-validation-test: all checks passed'
else
  echo "source-date-epoch-validation-test: ${failures} check(s) failed"
  exit 1
fi
