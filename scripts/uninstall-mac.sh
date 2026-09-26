#!/usr/bin/env bash
# Removes the LaunchAgents and the app. Keeps ~/.twelve (your journal) unless --purge.
set -uo pipefail
launchctl bootout "gui/$UID/com.twelve.gate" 2>/dev/null || true
launchctl bootout "gui/$UID/com.twelve.server" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.twelve.gate.plist" "$HOME/Library/LaunchAgents/com.twelve.server.plist"
rm -rf /Applications/TwelveGate.app
rm -f "$HOME/.twelve/run-server.sh"
if [ "${1:-}" = "--purge" ]; then rm -rf "$HOME/.twelve"; echo "Removed ~/.twelve"; fi
echo "Twelve uninstalled. The Mac is free."
