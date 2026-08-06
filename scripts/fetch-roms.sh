#!/usr/bin/env bash
#
# Downloads the hardware test ROMs the accuracy suite runs against.
#
# These aren't games. Blargg's tests are purpose-built diagnostics that report
# through the link port, so they can be run with no screen attached; dmg-acid2
# renders a single frame that is either pixel-exact or visibly wrong. All of
# them are freely redistributable, and none of them are committed here — the
# repository stays free of binaries and the script stays the source of truth.
#
#   ./scripts/fetch-roms.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/GameBoyKitTests/Resources/roms"
BLARGG="https://raw.githubusercontent.com/retrio/gb-test-roms/master"
ACID2="https://github.com/mattcurrie/dmg-acid2/releases/download/v1.0/dmg-acid2.gb"

mkdir -p "$OUT"
echo "▸ Fetching hardware test ROMs into $OUT"

get() {
  local url="$1" name="$2"
  if curl -sSfL -m 60 "$url" -o "$OUT/$name"; then
    printf '  %-20s %s bytes\n' "$name" "$(wc -c < "$OUT/$name" | tr -d ' ')"
  else
    echo "  ⚠️  $name failed" >&2
    rm -f "$OUT/$name"
  fi
}

get "$BLARGG/cpu_instrs/cpu_instrs.gb"     "cpu_instrs.gb"
get "$BLARGG/instr_timing/instr_timing.gb" "instr_timing.gb"
get "$BLARGG/mem_timing/mem_timing.gb"     "mem_timing.gb"
get "$BLARGG/halt_bug.gb"                  "halt_bug.gb"
get "$BLARGG/dmg_sound/dmg_sound.gb"       "dmg_sound.gb"
get "$ACID2"                               "dmg-acid2.gb"

echo "✅ $(ls "$OUT" | wc -l | tr -d ' ') ROMs"
