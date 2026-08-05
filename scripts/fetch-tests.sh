#!/usr/bin/env bash
#
# Downloads the SingleStepTests SM83 suite and samples it down to a size worth
# committing.
#
# The full suite is 1,000 tests for each of 500 opcodes — around 145 MB, far
# too much for a repository and far more than is needed to catch a broken
# instruction. Sampling keeps every opcode covered while the whole suite still
# runs in seconds.
#
#   ./scripts/fetch-tests.sh          # 25 tests per opcode (~2 MB)
#   SAMPLE=200 ./scripts/fetch-tests.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/GameBoyKitTests/Resources/sm83"
BASE="https://raw.githubusercontent.com/SingleStepTests/sm83/main/v1"
SAMPLE="${SAMPLE:-25}"

rm -rf "$OUT" && mkdir -p "$OUT"
echo "▸ Fetching SM83 tests ($SAMPLE per opcode) into $OUT"

# $1 = URL prefix (percent-encoded), $2 = local filename prefix.
# The CB-prefixed page is published as "cb 00.json" — with a literal space,
# which has to be encoded in the URL but not in the local name.
fetch_page() {
  local url_prefix="$1" file_prefix="$2" found=0
  for i in $(seq 0 255); do
    local hex; hex=$(printf "%02x" "$i")
    local url="$BASE/${url_prefix}${hex}.json"
    local out="$OUT/${file_prefix}${hex}.json"

    if curl -sSf -m 30 "$url" -o "$out.tmp" 2>/dev/null; then
      python3 -c "
import json, random
tests = json.load(open('$out.tmp'))
random.seed(0)                       # deterministic: same sample every run
sample = tests if len(tests) <= $SAMPLE else random.sample(tests, $SAMPLE)
json.dump(sample, open('$out', 'w'), separators=(',', ':'))
"
      rm -f "$out.tmp"
      found=$((found + 1))
    else
      rm -f "$out.tmp"
    fi
  done
  echo "  ${file_prefix:-unprefixed}: $found opcodes"
}

fetch_page "" ""
fetch_page "cb%20" "cb"

echo "✅ $(ls "$OUT" | wc -l | tr -d ' ') opcode files, $(du -sh "$OUT" | cut -f1) total"
