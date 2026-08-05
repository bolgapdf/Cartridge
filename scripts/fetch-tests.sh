#!/usr/bin/env bash
#
# Downloads the SingleStepTests SM83 suite: 1,000 cases for each of 500
# opcodes, around 145 MB. Nothing is committed — the suite is reproducible from
# this script, and the repository stays text.
#
# It used to sample 25 cases per opcode, and that was a mistake worth recording.
# A wrong DAA shipped past it: the bug failed only 1% of DAA's reference cases,
# so a 25-case sample missed it 78% of the time, and Blargg's cpu_instrs caught
# it instead. The full suite runs in about eight seconds, which is a poor reason
# to gamble.
#
#   ./scripts/fetch-tests.sh          # everything (~145 MB)
#   SAMPLE=25 ./scripts/fetch-tests.sh    # sampled, for a slow connection
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/GameBoyKitTests/Resources/sm83"
BASE="https://raw.githubusercontent.com/SingleStepTests/sm83/main/v1"
SAMPLE="${SAMPLE:-0}"     # 0 keeps every case

# Cleared each run: an interrupted download leaves "cb00 2.json"
# duplicates behind, which silently inflate the opcode count.
rm -rf "$OUT" && mkdir -p "$OUT" && touch "$OUT/.gitkeep"
echo "▸ Fetching SM83 tests ($([ "$SAMPLE" -eq 0 ] && echo "all cases" || echo "$SAMPLE per opcode")) into $OUT"

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
limit = $SAMPLE
sample = tests if limit == 0 or len(tests) <= limit else random.sample(tests, limit)
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
