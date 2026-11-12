#!/bin/bash
# Removes RouterStats, its login agent, settings, history and saved password.
set -uo pipefail
LABEL="io.github.bj97301.RouterStats"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
pkill -x RouterStats 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/RouterStats.app"
if [[ "${1:-}" == "--all" ]]; then
  defaults delete "$LABEL" 2>/dev/null
  rm -rf "$HOME/Library/Application Support/RouterStats"
  while security delete-generic-password -s RouterStats >/dev/null 2>&1; do :; done
  echo "Removed RouterStats, its settings, history and Keychain password."
else
  echo "Removed RouterStats. Run with --all to also delete settings, history and the saved password."
fi
