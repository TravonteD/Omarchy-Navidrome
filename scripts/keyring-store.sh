#!/bin/sh
set -eu

# Stores the plugin's Navidrome credential set in the keyring. The payload is
# a single-line JSON object {"v":1,"url":...,"username":...,"password":...}
# and arrives on stdin — never on argv, and it is never echoed or logged.
#
# Fixed attributes (service quickshell-navidrome, kind navidrome-credentials)
# mean one credential set per install: the URL inside the payload is the
# server identity, so storing again for the same identity overwrites in place
# and a different URL replaces it. Lookup/clear use the same attributes, so a
# stored set is found without knowing its URL ahead of time.

if [ "${1:-}" != "navidrome" ]; then
  exit 2
fi

IFS= read -r payload
if [ -z "$payload" ]; then
  exit 3
fi

if ! printf '%s' "$payload" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if not isinstance(data, dict) or data.get("v") != 1:
    sys.exit(1)
for key in ("url", "username", "password"):
    value = data.get(key)
    if not isinstance(value, str) or not value:
        sys.exit(1)
' >/dev/null; then
  exit 3
fi

printf '%s' "$payload" | secret-tool store \
  --label='Omarchy Navidrome server credentials' \
  service quickshell-navidrome \
  kind navidrome-credentials
