#!/bin/bash
# Render one hadith card to a 1080x1080 JPEG (macOS and Linux).
# Usage: ./render.sh <hadith-id> [output.jpg]
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
ID="$1"
OUT="${2:-$DIR/out/$ID.jpg}"
mkdir -p "$(dirname "$OUT")"

if [ -n "${CHROME_BIN:-}" ]; then CHROME="$CHROME_BIN"
elif [ -x "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ]; then CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
else CHROME="$(command -v google-chrome || command -v google-chrome-stable || command -v chromium || command -v chromium-browser)"; fi
EXTRA=()
[ "$(uname)" = "Linux" ] && EXTRA=(--no-sandbox)

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nabd.XXXXXX")"
TMP_PNG="$TMP_DIR/card.png"
URL="file://${DIR// /%20}/template.html?id=$ID"

"$CHROME" --headless=new --disable-gpu --hide-scrollbars --no-first-run ${EXTRA[@]+"${EXTRA[@]}"} \
  --user-data-dir="$TMP_DIR/profile" --allow-file-access-from-files \
  --window-size=1080,1080 --force-device-scale-factor=1 \
  --virtual-time-budget=8000 --screenshot="$TMP_PNG" "$URL" >/dev/null 2>&1

if command -v sips >/dev/null 2>&1; then
  sips -s format jpeg -s formatOptions 92 "$TMP_PNG" --out "$OUT" >/dev/null
else
  convert "$TMP_PNG" -quality 92 "$OUT"
fi
rm -rf "$TMP_DIR"
echo "$OUT"
