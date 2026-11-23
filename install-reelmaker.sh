#!/bin/zsh
# Installs (or removes with --remove) the Mac job that PRODUCES Reels every 2 hours while the Mac is on.
# It never publishes anything: publishing is done by GitHub Actions (.github/workflows/reels.yml).
set -euo pipefail
DIR="${0:A:h}"
LABEL="com.nabdalsunnah.reelmaker"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [[ "${1:-}" == "--remove" ]]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"; echo "Reels-produktionen på Macen är avstängd."; exit 0
fi

mkdir -p "$HOME/Library/LaunchAgents" "$DIR/work"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/usr/bin/ruby</string><string>$DIR/reels/reelmaker.rb</string><string>run</string></array>
  <key>WorkingDirectory</key><string>$DIR</string>
  <key>StartInterval</key><integer>7200</integer>
  <key>RunAtLoad</key><true/>
  <key>LowPriorityIO</key><true/>
  <key>Nice</key><integer>10</integer>
  <key>EnvironmentVariables</key><dict><key>LANG</key><string>en_US.UTF-8</string></dict>
  <key>StandardOutPath</key><string>$DIR/work/reelmaker.log</string>
  <key>StandardErrorPath</key><string>$DIR/work/reelmaker.log</string>
</dict></plist>
EOF
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Klart: Macen letar efter nya länkar och producerar Reels varannan timme när den är på."
