#!/usr/bin/env bash
set -euo pipefail
source_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT
cp "$source_root/"{AuthManager.qml,BackendClient.qml,Api.js,Subsonic.js} "$test_root/"
# The credential save round-trip runs for real against a stubbed secret-tool:
# the plugin dir must carry scripts/keyring-store.sh, and the stub only
# records argv, never the stdin payload.
install -d -m 700 "$test_root/scripts"
install -m 755 "$source_root/scripts/keyring-store.sh" "$test_root/scripts/"
auth_secret_log="$test_root/secret-tool.log"
export auth_secret_log
mkdir -p "$test_root/stub-bin"
cat >"$test_root/stub-bin/secret-tool" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >>"\${OMARCHY_AUTH_TEST_LOG:?}"
cat >/dev/null
STUB
chmod 755 "$test_root/stub-bin/secret-tool"
sed 's|import "../.." as Plugin|import "." as Plugin|' \
  "$source_root/tests/integration/AuthIdentity.qml" > "$test_root/shell.qml"
env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen \
  OMARCHY_AUTH_TEST_DIR="$test_root" \
  OMARCHY_AUTH_TEST_LOG="$auth_secret_log" \
  PATH="$test_root/stub-bin:$PATH" \
  timeout 15s \
  qs --no-color -p "$test_root" > "$test_root/output" 2>&1 || {
  cat "$test_root/output"
  exit 1
}
rg -q AUTH_IDENTITY_PASS "$test_root/output" || {
  cat "$test_root/output"
  exit 1
}
grep -qF 'store --label=Omarchy Navidrome server credentials service quickshell-navidrome kind navidrome-credentials' \
  "$auth_secret_log"
if grep -qF 'test-pass-123' "$auth_secret_log"; then
  echo "The keyring stub log captured the credential payload" >&2
  exit 1
fi
echo 'Quickshell authorization integration passed.'

mkdir -p "$test_root/app/plugin" "$test_root/state"
cp "$source_root/"*.qml "$source_root/"*.js "$test_root/app/plugin/"
cp -r /usr/share/omarchy/shell/Commons /usr/share/omarchy/shell/Ui "$test_root/app/"
cp "$source_root/tests/integration/AppSmoke.qml" "$test_root/app/shell.qml"
if [[ -z ${WAYLAND_DISPLAY:-} ]]; then
  # Service/authentication tests still use real Quickshell without a compositor.
  sed -i '/Plugin.Panel {/d; /Plugin.BarWidget {/d; /panel.primaryNavigationItems()/,+1d; /PANEL_PAGE_BOOT_BEGIN/,/PANEL_PAGE_BOOT_END/d' "$test_root/app/shell.qml"
  app_platform=offscreen
else
  app_platform=wayland
fi
env QT_QPA_PLATFORM="$app_platform" QT_QPA_PLATFORMTHEME=generic NO_AT_BRIDGE=1 XDG_STATE_HOME="$test_root/state" \
  timeout 15s dbus-run-session -- qs --no-color -p "$test_root/app" > "$test_root/app-output" 2>&1 || {
  cat "$test_root/app-output"
  exit 1
}
rg -q APP_SMOKE_PASS "$test_root/app-output" || {
  cat "$test_root/app-output"
  exit 1
}
if rg -i 'ReferenceError|TypeError|binding loop|Cannot assign|Unable to assign|Failed to load configuration' "$test_root/app-output"; then
  exit 1
fi
echo 'Quickshell app smoke test passed.'
