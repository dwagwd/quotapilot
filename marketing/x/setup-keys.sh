#!/bin/zsh
# Stores the four X API keys in the login keychain. Paste each value when asked; nothing is echoed or saved to a file.
set -e
for name in AQW_X_API_KEY AQW_X_API_SECRET AQW_X_ACCESS_TOKEN AQW_X_ACCESS_SECRET; do
  printf "%s: " "$name"; read -rs value; echo
  [[ -n "$value" ]] || { echo "empty, stopped"; exit 1; }
  security add-generic-password -U -a "$USER" -s "$name" -w "$value"
done
echo "Saved 4 keys to the login keychain."
