#!/usr/bin/env bash
# One-shot install on the Mac: builds everything, installs the server and the
# gate app as LaunchAgents, and prints the pairing page URL.
#
#   ./scripts/install-mac.sh            # install / update everything
#   ./scripts/install-mac.sh --no-gate  # server only (try the flow without locking the Mac)
#
# Secrets go in ~/.twelve/env (KEY=value lines, sourced by the server LaunchAgent):
#   ANTHROPIC_API_KEY=sk-ant-...
#   ELEVENLABS_API_KEY=...        (optional)
#   GEMINI_API_KEY=...            (optional)
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE="$(command -v node || true)"
GATE=1
for a in "$@"; do [ "$a" = "--no-gate" ] && GATE=0; done

if [ -z "$NODE" ]; then
  echo "node is required (brew install node)"; exit 1
fi
if [ "$(uname)" != "Darwin" ]; then
  echo "This installer is for macOS. On other systems run: npm install && npm run build && npm start"; exit 1
fi

echo "==> Installing dependencies and building"
cd "$REPO"
npm install
npm run build

mkdir -p "$HOME/.twelve" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/twelve"
touch "$HOME/.twelve/env"

echo "==> Installing the server LaunchAgent (com.twelve.server)"
# The plist runs node directly; secrets are loaded from ~/.twelve/env by a tiny wrapper.
cat > "$HOME/.twelve/run-server.sh" <<SH
#!/usr/bin/env bash
set -a
[ -f "\$HOME/.twelve/env" ] && . "\$HOME/.twelve/env"
set +a
exec "$NODE" "$REPO/packages/server/dist/cli.js"
SH
chmod +x "$HOME/.twelve/run-server.sh"
sed -e "s|__NODE__|/bin/bash|" -e "s|__REPO__/packages/server/dist/cli.js|$HOME/.twelve/run-server.sh|" \
    -e "s|__REPO__|$REPO|g" -e "s|__HOME__|$HOME|g" \
    "$REPO/scripts/launchd/com.twelve.server.plist" > "$HOME/Library/LaunchAgents/com.twelve.server.plist"
launchctl bootout "gui/$UID/com.twelve.server" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$HOME/Library/LaunchAgents/com.twelve.server.plist"

if [ "$GATE" = "1" ]; then
  echo "==> Building and installing the gate app (com.twelve.gate)"
  (cd "$REPO/apps/mac/TwelveGate" && ./scripts/bundle.sh)
  rm -rf /Applications/TwelveGate.app
  cp -R "$REPO/apps/mac/TwelveGate/build/TwelveGate.app" /Applications/
  sed "s|__HOME__|$HOME|g" "$REPO/apps/mac/TwelveGate/launchd/com.twelve.gate.plist" > "$HOME/Library/LaunchAgents/com.twelve.gate.plist"
  launchctl bootout "gui/$UID/com.twelve.gate" 2>/dev/null || true
  launchctl bootstrap "gui/$UID" "$HOME/Library/LaunchAgents/com.twelve.gate.plist"
fi

sleep 2
echo
echo "==> Done."
echo "    Pair your Daylight:  open http://127.0.0.1:7712/pair"
echo "    Logs:                ~/Library/Logs/twelve/server.log  ~/Library/Logs/twelve/gate.log"
echo "    Secrets:             ~/.twelve/env   (then: launchctl kickstart -k gui/$UID/com.twelve.server)"
echo "    Uninstall:           ./scripts/uninstall-mac.sh"
if ! grep -q ANTHROPIC_API_KEY "$HOME/.twelve/env"; then
  echo
  echo "    No ANTHROPIC_API_KEY in ~/.twelve/env yet. Until you add one, set brain.provider to \"mock\" in ~/.twelve/config.json (or run the server with --mock) to try the flow."
fi
