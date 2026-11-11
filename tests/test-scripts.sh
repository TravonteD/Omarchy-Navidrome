#!/usr/bin/env bash
set -euo pipefail

source_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

# Release executables are published separately with exact-commit build
# provenance. The reviewed source snapshot must not contain an opaque ELF.
[[ ! -e $source_root/backend/dist/$(uname -m)/omarchy-navidrome-backend ]]
[[ -f $source_root/.github/workflows/release-backend.yml ]]
backend_source_id=$($source_root/scripts/backend-source-id.sh)
[[ $backend_source_id =~ ^[0-9a-f]{64}$ ]]

# A release built from the manifest's version tag remains valid when main has
# moved ahead with UI-only commits. The attestation must stay bound to the
# tagged commit, while any committed backend change must force a source build.
release_source="$test_root/release-source"
release_runtime="$test_root/release-runtime"
release_target="$test_root/release-target"
release_mock_bin="$test_root/release-mock-bin"
release_fixture="$test_root/release-fixture"
release_gh_log="$test_root/release-gh.log"
release_cargo_log="$test_root/release-cargo.log"
mkdir -p "$release_source/scripts" "$release_mock_bin" "$release_fixture"
while IFS= read -r backend_file; do
  mkdir -p "$release_source/$(dirname -- "$backend_file")"
  cp -- "$source_root/$backend_file" "$release_source/$backend_file"
done < <(git -C "$source_root" ls-files backend)
cp -- "$source_root/scripts/build-backend.sh" \
  "$source_root/scripts/backend-source-id.sh" "$release_source/scripts/"
cp -- "$source_root/manifest.json" "$source_root/rust-toolchain.toml" \
  "$release_source/"
git -C "$release_source" init -q
git -C "$release_source" config user.name "Omarchy Navidrome tests"
git -C "$release_source" config user.email "tests@example.invalid"
git -C "$release_source" add .
git -C "$release_source" commit -qm "Release source"
release_version=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["version"])' "$source_root/manifest.json")
git -C "$release_source" tag -a "v$release_version" -m "Release v$release_version"
release_commit=$(git -C "$release_source" rev-parse "refs/tags/v$release_version^{commit}")
printf '%s\n' 'UI-only change after the release' >"$release_source/Panel.qml"
git -C "$release_source" add Panel.qml
git -C "$release_source" commit -qm "Change only the UI"
[[ $(git -C "$release_source" rev-parse HEAD) != "$release_commit" ]]

release_asset_name="omarchy-navidrome-backend-$(uname -m)"
release_asset="$release_fixture/$release_asset_name"
release_sums="$release_fixture/SHA256SUMS"
printf '%s\n' 'mock attested release' >"$release_asset"
release_hash=$(sha256sum -- "$release_asset")
printf '%s  %s\n' "${release_hash%% *}" "$release_asset_name" >"$release_sums"

printf '%s\n' \
  '#!/bin/sh' \
  'set -eu' \
  'output=' \
  'while [ "$#" -gt 0 ]; do' \
  '  case $1 in' \
  '    -o) output=$2; shift 2 ;;' \
  '    *) shift ;;' \
  '  esac' \
  'done' \
  'case $output in' \
  '  */SHA256SUMS) cp -- "${TEST_RELEASE_SUMS:?}" "$output" ;;' \
  '  *) cp -- "${TEST_RELEASE_ASSET:?}" "$output" ;;' \
  'esac' >"$release_mock_bin/curl"
printf '%s\n' \
  '#!/bin/sh' \
  'set -eu' \
  'printf "%s\n" "$*" >>"${TEST_GH_LOG:?}"' \
  'digest=' \
  'while [ "$#" -gt 0 ]; do' \
  '  case $1 in' \
  '    --source-digest) digest=$2; shift 2 ;;' \
  '    *) shift ;;' \
  '  esac' \
  'done' \
  '[ "$digest" = "${TEST_EXPECTED_DIGEST:?}" ]' >"$release_mock_bin/gh"
printf '%s\n' \
  '#!/bin/sh' \
  'set -eu' \
  'printf "%s\n" "$*" >>"${TEST_CARGO_LOG:?}"' \
  'mkdir -p "${CARGO_TARGET_DIR:?}/release"' \
  'printf "%s\n" "mock changed-source build" >"$CARGO_TARGET_DIR/release/omarchy-navidrome-backend"' \
  'chmod 755 "$CARGO_TARGET_DIR/release/omarchy-navidrome-backend"' \
  'exit 0' >"$release_mock_bin/cargo"
chmod 755 "$release_mock_bin/curl" "$release_mock_bin/gh" \
  "$release_mock_bin/cargo"
: >"$release_gh_log"
: >"$release_cargo_log"

PATH="$release_mock_bin:$PATH" \
TEST_RELEASE_ASSET="$release_asset" \
TEST_RELEASE_SUMS="$release_sums" \
TEST_EXPECTED_DIGEST="$release_commit" \
TEST_GH_LOG="$release_gh_log" \
TEST_CARGO_LOG="$release_cargo_log" \
OMARCHY_NAVIDROME_RUNTIME_DIR="$release_runtime" \
CARGO_TARGET_DIR="$release_target" \
  "$release_source/scripts/build-backend.sh" >/dev/null
cmp -s -- "$release_asset" "$release_runtime/omarchy-navidrome-backend"
[[ $(<"$release_runtime/backend-origin") == "attested-release:$release_commit" ]]
grep -q -- "--source-digest $release_commit" "$release_gh_log"
[[ ! -s $release_cargo_log ]]

printf '%s\n' '// committed backend change' >>"$release_source/backend/src/main.rs"
git -C "$release_source" add backend/src/main.rs
git -C "$release_source" commit -qm "Change backend after release"
: >"$release_gh_log"
: >"$release_cargo_log"
PATH="$release_mock_bin:$PATH" \
TEST_RELEASE_ASSET="$release_asset" \
TEST_RELEASE_SUMS="$release_sums" \
TEST_EXPECTED_DIGEST="$release_commit" \
TEST_GH_LOG="$release_gh_log" \
TEST_CARGO_LOG="$release_cargo_log" \
OMARCHY_NAVIDROME_RUNTIME_DIR="$release_runtime" \
CARGO_TARGET_DIR="$release_target" \
  "$release_source/scripts/build-backend.sh" >/dev/null
[[ ! -s $release_gh_log ]]
grep -q -- '--locked --release' "$release_cargo_log"
grep -q '^source-build:' "$release_runtime/backend-origin"

mkdir -p "$test_root/config/omarchy-navidrome"
cp -- "$source_root/config/spotifyd.conf" "$test_root/config/omarchy-navidrome/spotifyd.conf"
printf '%s\n' 'device = "legacy_output"' >>"$test_root/config/omarchy-navidrome/spotifyd.conf"
printf '%s\n%s\n' "Desk speakers" 320 |
  XDG_CONFIG_HOME="$test_root/config" "$source_root/scripts/configure-spotifyd.sh"
grep -qx 'device_name = "Desk speakers"' "$test_root/config/omarchy-navidrome/spotifyd.conf"
grep -qx 'bitrate = 320' "$test_root/config/omarchy-navidrome/spotifyd.conf"
grep -qx 'no_audio_cache = false' "$test_root/config/omarchy-navidrome/spotifyd.conf"
grep -qx 'max_cache_size = 1000000000' "$test_root/config/omarchy-navidrome/spotifyd.conf"
! grep -q '^device[[:space:]]*=' "$test_root/config/omarchy-navidrome/spotifyd.conf"
grep -qx 'autoplay = true' "$test_root/config/omarchy-navidrome/spotifyd.conf"

printf '%s\n' "Renamed speakers" |
  XDG_CONFIG_HOME="$test_root/config" "$source_root/scripts/configure-spotifyd.sh"
grep -qx 'device_name = "Renamed speakers"' "$test_root/config/omarchy-navidrome/spotifyd.conf"
grep -qx 'bitrate = 320' "$test_root/config/omarchy-navidrome/spotifyd.conf"
! grep -q '^device[[:space:]]*=' "$test_root/config/omarchy-navidrome/spotifyd.conf"

printf '%s\n%s\n\n' "Desk speakers" 96 |
  XDG_CONFIG_HOME="$test_root/config" "$source_root/scripts/configure-spotifyd.sh"
grep -qx 'bitrate = 96' "$test_root/config/omarchy-navidrome/spotifyd.conf"
! grep -q '^device[[:space:]]*=' "$test_root/config/omarchy-navidrome/spotifyd.conf"

set +e
printf '%s\n' 'invalid"name' |
  XDG_CONFIG_HOME="$test_root/config" "$source_root/scripts/configure-spotifyd.sh"
invalid_status=$?
set -e
[[ $invalid_status -eq 3 ]]

# Exercise setup and removal entirely inside the temporary tree. The mock
# spotifyd/systemctl binaries prevent package, service, keyring, or user-config
# changes while still covering the scripts' real file permissions and paths.
mock_bin="$test_root/mock-bin"
runtime_config="$test_root/runtime-config"
runtime_cache="$test_root/runtime-cache"
runtime_state="$test_root/runtime-state"
runtime_session="$test_root/runtime-session"
runtime_backend="$test_root/runtime-lib/omarchy-navidrome"
runtime_home="$test_root/runtime-home"
mock_target="$test_root/mock-target"
secret_log="$test_root/secret-tool.log"
systemctl_log="$test_root/systemctl.log"
omarchy_log="$test_root/omarchy.log"
mkdir -p "$mock_bin" "$runtime_config" "$runtime_cache" "$runtime_state" \
  "$runtime_session" "$runtime_backend" "$runtime_home"

printf '%s\n' '#!/bin/sh' 'exit 0' >"$mock_bin/spotifyd"
printf '%s\n' \
  '#!/bin/sh' \
  'mkdir -p "${CARGO_TARGET_DIR:?}/release"' \
  'printf "%s\n" "mock source-built backend" >"$CARGO_TARGET_DIR/release/omarchy-navidrome-backend"' \
  'chmod 755 "$CARGO_TARGET_DIR/release/omarchy-navidrome-backend"' \
  'exit 0' >"$mock_bin/cargo"
printf '%s\n' \
  '#!/bin/sh' \
  'if [ -n "${TEST_SYSTEMCTL_LOG:-}" ]; then printf "%s\n" "$*" >>"$TEST_SYSTEMCTL_LOG"; fi' \
  'if [ "${1:-}" = "--user" ]; then shift; fi' \
  'if [ "${1:-}" = "is-enabled" ]; then exit 1; fi' \
  'if [ "${1:-}" = "is-active" ]; then [ "${TEST_SERVICE_ACTIVE:-0}" = 1 ]; exit; fi' \
  'exit 0' >"$mock_bin/systemctl"
printf '%s\n' \
  '#!/bin/sh' \
  'printf "%s\n" "$*" >>"${TEST_SECRET_LOG:?}"' \
  'exit 1' >"$mock_bin/secret-tool"
printf '%s\n' \
  '#!/bin/sh' \
  'printf "%s\n" "$*" >>"${TEST_OMARCHY_LOG:?}"' \
  'if [ "$*" = "plugin remove quickshell.navidrome --yes" ]; then' \
  '  rm -f -- "$HOME/.config/omarchy/plugins/quickshell.navidrome"' \
  'fi' \
  'exit 0' >"$mock_bin/omarchy"
chmod 755 "$mock_bin/cargo" "$mock_bin/spotifyd" "$mock_bin/systemctl" \
  "$mock_bin/secret-tool" "$mock_bin/omarchy"

[[ -x $source_root/scripts/spotify-connect-device.py ]]
"$source_root/scripts/spotify-connect-device.py" self-test |
  jq -e '.status == "ok"' >/dev/null

PATH="$mock_bin:$PATH" \
XDG_CONFIG_HOME="$runtime_config" \
XDG_CACHE_HOME="$runtime_cache" \
XDG_STATE_HOME="$runtime_state" \
OMARCHY_NAVIDROME_RUNTIME_DIR="$runtime_backend" \
OMARCHY_NAVIDROME_SKIP_BACKEND_BUILD=1 \
  "$source_root/scripts/setup.sh" --device-name "Test speakers" >/dev/null

runtime_spotify_config="$runtime_config/omarchy-navidrome/spotifyd.conf"
runtime_unit="$runtime_config/systemd/user/omarchy-navidrome-spotifyd.service"
[[ -f $runtime_spotify_config && -f $runtime_unit ]]
[[ $(stat -c '%a' "$runtime_spotify_config") == 600 ]]
[[ $(stat -c '%a' "$runtime_unit") == 644 ]]
grep -qx 'device_name = "Test speakers"' "$runtime_spotify_config"
grep -qx 'no_audio_cache = false' "$runtime_spotify_config"
grep -qx 'max_cache_size = 1000000000' "$runtime_spotify_config"
grep -qx 'Environment=PULSE_LATENCY_MSEC=30' "$runtime_unit"

PATH="$mock_bin:$PATH" \
XDG_CONFIG_HOME="$runtime_config" \
XDG_CACHE_HOME="$runtime_cache" \
XDG_STATE_HOME="$runtime_state" \
OMARCHY_NAVIDROME_RUNTIME_DIR="$runtime_backend" \
  "$source_root/scripts/remove-runtime.sh" >/dev/null

[[ ! -e $runtime_unit && ! -e $runtime_config/omarchy-navidrome ]]
find "$runtime_config" -maxdepth 1 -type d -name 'omarchy-navidrome.bak.*' \
  | grep -q .

# The in-app first-run wrapper must complete the unprivileged setup directly
# when spotifyd is already present.
PATH="$mock_bin:$PATH" \
XDG_CONFIG_HOME="$runtime_config" \
XDG_CACHE_HOME="$runtime_cache" \
XDG_STATE_HOME="$runtime_state" \
OMARCHY_NAVIDROME_RUNTIME_DIR="$runtime_backend" \
OMARCHY_NAVIDROME_SKIP_BACKEND_BUILD=1 \
  "$source_root/scripts/setup-playback.sh" >/dev/null
[[ -f $runtime_spotify_config && -f $runtime_unit ]]
grep -qx 'device_name = "Omarchy Navidrome"' "$runtime_spotify_config"

# Guided first-run: the live probe against a fake Navidrome decides whether
# anything is stored, typed outcomes map to exit codes, and a plain http://
# target stays allowed but is warned about in plain words. The stub
# secret-tool records argv only — the payload rides stdin and must never
# reach the log.
setup_probe_bin="$test_root/setup-probe-bin"
keyring_log="$test_root/keyring.log"
mkdir -p "$setup_probe_bin"
printf '%s\n' \
  '#!/bin/sh' \
  'printf "%s\n" "$*" >>"${TEST_KEYRING_LOG:?}"' \
  'cat >/dev/null' \
  'exit 0' >"$setup_probe_bin/secret-tool"
chmod 755 "$setup_probe_bin/secret-tool"

fake_dir="$test_root/fake-navidrome"
mkdir -p "$fake_dir"
cat >"$fake_dir/server.py" <<'FAKE'
import hashlib, json, os, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

password = "correct-pass-42"
mode_path, port_path = sys.argv[1], sys.argv[2]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(parsed.query)
        mode = ""
        if os.path.exists(mode_path):
            with open(mode_path) as fh:
                mode = fh.read().strip()
        expected = hashlib.md5(
            (password + query.get("s", [""])[0]).encode("utf-8")).hexdigest()

        def reply(payload):
            body = json.dumps({"subsonic-response": payload}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        if parsed.path not in ("/rest/ping", "/rest/getUser"):
            reply({"status": "failed",
                   "error": {"code": 70, "message": "unknown"}})
        elif mode == "token_reject":
            reply({"status": "failed",
                   "error": {"code": 41, "message": "auth"}})
        elif query.get("t", [""])[0] != expected:
            reply({"status": "failed",
                   "error": {"code": 40, "message": "auth"}})
        elif parsed.path == "/rest/ping":
            reply({"status": "ok"})
        else:
            reply({"status": "ok",
                   "user": {"username": "testuser", "streamRole": True}})


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(port_path, "w") as fh:
    fh.write(str(server.server_port))
server.serve_forever()
FAKE
python3 "$fake_dir/server.py" "$fake_dir/mode" "$fake_dir/port" &
fake_pid=$!
trap 'kill "$fake_pid" 2>/dev/null || true; rm -rf -- "$test_root"' EXIT
for _ in {1..100}; do
  [[ -s $fake_dir/port ]] && break
  sleep 0.05
done
[[ -s $fake_dir/port ]] || { echo "the fake Navidrome never started" >&2; exit 1; }
fake_port=$(<"$fake_dir/port")
printf 'ok\n' >"$fake_dir/mode"

run_first_run() {
  PATH="$setup_probe_bin:$mock_bin:$PATH" \
  XDG_CONFIG_HOME="$runtime_config" \
  XDG_CACHE_HOME="$runtime_cache" \
  XDG_STATE_HOME="$runtime_state" \
  XDG_RUNTIME_DIR="$runtime_session" \
  OMARCHY_NAVIDROME_RUNTIME_DIR="$runtime_backend" \
  env \
    OMARCHY_NAVIDROME_SKIP_BACKEND_BUILD=1 \
    TEST_KEYRING_LOG="$keyring_log" \
    "$@" \
    "$source_root/scripts/setup-playback.sh"
}

keyring_stores() {
  grep -cx 'store --label=Omarchy Navidrome server credentials service quickshell-navidrome kind navidrome-credentials' \
    "$keyring_log"
}

: >"$keyring_log"
set +e
probe_stderr=$(run_first_run \
  OMARCHY_NAVIDROME_SERVER_URL="http://127.0.0.1:$fake_port" \
  OMARCHY_NAVIDROME_USERNAME="testuser" \
  OMARCHY_NAVIDROME_PASSWORD="correct-pass-42" \
  2>&1 >/dev/null)
probe_status=$?
set -e
[[ $probe_status -eq 0 ]] || { echo "first-run probe failed: $probe_stderr" >&2; exit 1; }
grep -qi 'not private' <<<"$probe_stderr"
[[ $(keyring_stores) -eq 1 ]]

# Re-running for the same server identity overwrites cleanly: exactly one
# store per successful run, never a duplicate entry.
set +e
run_first_run \
  OMARCHY_NAVIDROME_SERVER_URL="http://127.0.0.1:$fake_port/" \
  OMARCHY_NAVIDROME_USERNAME="testuser" \
  OMARCHY_NAVIDROME_PASSWORD="correct-pass-42" \
  >/dev/null 2>&1
rerun_status=$?
set -e
[[ $rerun_status -eq 0 ]]
[[ $(keyring_stores) -eq 2 ]]
! grep -q 'correct-pass-42' "$keyring_log"

# A wrong password is a typed failure that stores nothing.
set +e
wrong_stderr=$(run_first_run \
  OMARCHY_NAVIDROME_SERVER_URL="http://127.0.0.1:$fake_port" \
  OMARCHY_NAVIDROME_USERNAME="testuser" \
  OMARCHY_NAVIDROME_PASSWORD="wrong-pass" \
  2>&1 >/dev/null)
wrong_status=$?
set -e
[[ $wrong_status -eq 10 ]]
grep -qi 'Wrong username or password' <<<"$wrong_stderr"
[[ $(keyring_stores) -eq 2 ]]

# A rejected token-auth scheme is typed too.
printf 'token_reject\n' >"$fake_dir/mode"
set +e
run_first_run \
  OMARCHY_NAVIDROME_SERVER_URL="http://127.0.0.1:$fake_port" \
  OMARCHY_NAVIDROME_USERNAME="testuser" \
  OMARCHY_NAVIDROME_PASSWORD="correct-pass-42" \
  >/dev/null 2>&1
token_status=$?
set -e
[[ $token_status -eq 11 ]]
printf 'ok\n' >"$fake_dir/mode"

# An unreachable server is generic and stores nothing.
set +e
run_first_run \
  OMARCHY_NAVIDROME_SERVER_URL="http://127.0.0.1:1" \
  OMARCHY_NAVIDROME_USERNAME="testuser" \
  OMARCHY_NAVIDROME_PASSWORD="correct-pass-42" \
  >/dev/null 2>&1
unreachable_status=$?
set -e
[[ $unreachable_status -eq 1 ]]
[[ $(keyring_stores) -eq 2 ]]

# An invalid address fails before the network and stores nothing.
set +e
run_first_run \
  OMARCHY_NAVIDROME_SERVER_URL="ftp://127.0.0.1:$fake_port" \
  OMARCHY_NAVIDROME_USERNAME="testuser" \
  OMARCHY_NAVIDROME_PASSWORD="correct-pass-42" \
  >/dev/null 2>&1
invalid_status=$?
set -e
[[ $invalid_status -eq 3 ]]
[[ $(keyring_stores) -eq 2 ]]

# Without input and without a terminal the automatic path stays quiet.
set +e
run_first_run >/dev/null 2>&1
quiet_status=$?
set -e
[[ $quiet_status -eq 0 ]]
[[ $(keyring_stores) -eq 2 ]]

# A clean source install records both the reviewed backend-source fingerprint
# and installed executable hash. The release path writes the same records only
# after its exact-commit attestation succeeds.
rm -f -- "$runtime_backend/omarchy-navidrome-backend" \
  "$runtime_backend/backend-source.sha256" \
  "$runtime_backend/backend-binary.sha256" \
  "$runtime_backend/backend-origin"
PATH="$mock_bin:$PATH" \
XDG_CONFIG_HOME="$runtime_config" \
XDG_CACHE_HOME="$runtime_cache" \
XDG_STATE_HOME="$runtime_state" \
OMARCHY_NAVIDROME_RUNTIME_DIR="$runtime_backend" \
CARGO_TARGET_DIR="$mock_target" \
OMARCHY_NAVIDROME_BUILD_FROM_SOURCE=1 \
  "$source_root/scripts/setup.sh" >/dev/null
runtime_backend_unit="$runtime_config/systemd/user/omarchy-navidrome.service"
[[ -x $runtime_backend/omarchy-navidrome-backend && -f $runtime_backend_unit ]]
[[ $(<"$runtime_backend/backend-source.sha256") == "$backend_source_id" ]]
installed_hash=$(sha256sum -- "$runtime_backend/omarchy-navidrome-backend")
[[ $(<"$runtime_backend/backend-binary.sha256") == "${installed_hash%% *}" ]]
[[ $(<"$runtime_backend/backend-origin") == "source-build:$backend_source_id" ]]
[[ $(stat -c '%a' "$runtime_backend/backend-source.sha256") == 600 ]]
[[ $(stat -c '%a' "$runtime_backend/backend-binary.sha256") == 600 ]]

# Existing installations must be checked against their recorded source and
# binary hashes. Re-run setup when the executable or static unit is stale, then
# restart an already-active backend so it immediately uses the replacement.
printf '%s\n' 'stale backend' >"$runtime_backend/omarchy-navidrome-backend"
chmod 755 "$runtime_backend/omarchy-navidrome-backend"
printf '%s\n' 'stale unit' >"$runtime_backend_unit"
selected_unit=$(PATH="$mock_bin:$PATH" \
  XDG_CONFIG_HOME="$runtime_config" \
  OMARCHY_NAVIDROME_RUNTIME_DIR="$runtime_backend" \
  "$source_root/scripts/playback-runtime.sh" unit)
[[ $selected_unit == omarchy-navidrome-spotifyd.service ]]

: >"$systemctl_log"
PATH="$mock_bin:$PATH" \
XDG_CONFIG_HOME="$runtime_config" \
XDG_CACHE_HOME="$runtime_cache" \
XDG_STATE_HOME="$runtime_state" \
OMARCHY_NAVIDROME_RUNTIME_DIR="$runtime_backend" \
CARGO_TARGET_DIR="$mock_target" \
OMARCHY_NAVIDROME_BUILD_FROM_SOURCE=1 \
TEST_SERVICE_ACTIVE=1 \
TEST_SYSTEMCTL_LOG="$systemctl_log" \
  "$source_root/scripts/setup.sh" >/dev/null
installed_hash=$(sha256sum -- "$runtime_backend/omarchy-navidrome-backend")
source_build_hash=$(sha256sum -- "$mock_target/release/omarchy-navidrome-backend")
[[ ${installed_hash%% *} == "${source_build_hash%% *}" ]]
cmp -s -- "$source_root/systemd/omarchy-navidrome.service" "$runtime_backend_unit"
PATH="$mock_bin:$PATH" \
XDG_CONFIG_HOME="$runtime_config" \
OMARCHY_NAVIDROME_RUNTIME_DIR="$runtime_backend" \
  "$source_root/scripts/playback-runtime.sh" check
grep -qx -- '--user restart omarchy-navidrome.service' "$systemctl_log"

: >"$systemctl_log"
PATH="$mock_bin:$PATH" \
XDG_CONFIG_HOME="$runtime_config" \
XDG_CACHE_HOME="$runtime_cache" \
XDG_STATE_HOME="$runtime_state" \
OMARCHY_NAVIDROME_RUNTIME_DIR="$runtime_backend" \
TEST_SERVICE_ACTIVE=1 \
TEST_SYSTEMCTL_LOG="$systemctl_log" \
  "$source_root/scripts/setup.sh" >/dev/null
! grep -q -- '--user restart omarchy-navidrome.service' "$systemctl_log"

mkdir -p "$runtime_config/omarchy-navidrome" \
  "$runtime_config/omarchy-navidrome.bak.20260827000000" \
  "$runtime_cache/spotifyd" "$runtime_cache/omarchy-navidrome/target" \
  "$runtime_session/omarchy-navidrome"
cp -- "$source_root/config/spotifyd.conf" "$runtime_config/omarchy-navidrome/spotifyd.conf"
printf '%s\n' stale >"$runtime_config/omarchy-navidrome.bak.20260827000000/spotifyd.conf"
printf '%s\n' stale >"$runtime_cache/omarchy-navidrome/target/build-artifact"
printf '%s\n' stale >"$runtime_session/omarchy-navidrome/backend.sock"
: >"$systemctl_log"
PATH="$mock_bin:$PATH" \
XDG_CONFIG_HOME="$runtime_config" \
XDG_CACHE_HOME="$runtime_cache" \
XDG_STATE_HOME="$runtime_state" \
XDG_RUNTIME_DIR="$runtime_session" \
OMARCHY_NAVIDROME_RUNTIME_DIR="$runtime_backend" \
TEST_SECRET_LOG="$secret_log" \
TEST_SYSTEMCTL_LOG="$systemctl_log" \
  "$source_root/scripts/remove-runtime.sh" --purge >/dev/null

[[ ! -e $runtime_config/omarchy-navidrome && ! -e $runtime_cache/spotifyd ]]
[[ ! -e $runtime_config/omarchy-navidrome.bak.20260827000000 ]]
[[ ! -e $runtime_cache/omarchy-navidrome ]]
[[ ! -e $runtime_state/omarchy-navidrome ]]
[[ ! -e $runtime_session/omarchy-navidrome ]]
[[ ! -e $runtime_backend ]]
grep -qx -- '--user disable --now omarchy-navidrome.service' "$systemctl_log"
grep -qx -- '--user disable --now omarchy-navidrome-spotifyd.service' "$systemctl_log"
grep -q 'clear service quickshell-spotify kind refresh-token' "$secret_log"

set +e
PATH="$mock_bin:$PATH" \
XDG_CACHE_HOME="relative-cache" \
  "$source_root/scripts/remove-runtime.sh" --purge >/dev/null 2>&1
unsafe_remove_status=$?
set -e
[[ $unsafe_remove_status -eq 3 ]]

# The top-level uninstaller wraps the runtime purge, removes the plugin through
# Omarchy, clears exact-ID backups, restarts the shell, and remains idempotent.
plugin_dir="$runtime_home/.config/omarchy/plugins/quickshell.navidrome"
plugin_backup="$runtime_home/.config/omarchy/plugins/.quickshell.navidrome.bak.20260827000000"
mkdir -p "$(dirname -- "$plugin_dir")" "$plugin_backup" \
  "$runtime_config/omarchy-navidrome" "$runtime_cache/spotifyd" \
  "$runtime_state/omarchy-navidrome" "$runtime_session/omarchy-navidrome" \
  "$runtime_backend"
ln -s -- "$source_root" "$plugin_dir"
printf '%s\n' stale >"$runtime_backend/omarchy-navidrome-backend"
: >"$omarchy_log"
(
  cd "$test_root"
  PATH="$mock_bin:$PATH" \
  HOME="$runtime_home" \
  XDG_CONFIG_HOME="$runtime_config" \
  XDG_CACHE_HOME="$runtime_cache" \
  XDG_STATE_HOME="$runtime_state" \
  XDG_RUNTIME_DIR="$runtime_session" \
  OMARCHY_NAVIDROME_RUNTIME_DIR="$runtime_backend" \
  TEST_SECRET_LOG="$secret_log" \
  TEST_SYSTEMCTL_LOG="$systemctl_log" \
  TEST_OMARCHY_LOG="$omarchy_log" \
    "$source_root/scripts/uninstall.sh" >/dev/null
)
[[ ! -e $plugin_dir && ! -L $plugin_dir && ! -e $plugin_backup ]]
[[ ! -e $runtime_config/omarchy-navidrome && ! -e $runtime_cache/spotifyd ]]
[[ ! -e $runtime_state/omarchy-navidrome && ! -e $runtime_session/omarchy-navidrome ]]
[[ ! -e $runtime_backend ]]
grep -qx 'plugin disable quickshell.navidrome' "$omarchy_log"
grep -qx 'plugin remove quickshell.navidrome --yes' "$omarchy_log"
grep -qx 'restart shell' "$omarchy_log"

PATH="$mock_bin:$PATH" \
HOME="$runtime_home" \
XDG_CONFIG_HOME="$runtime_config" \
XDG_CACHE_HOME="$runtime_cache" \
XDG_STATE_HOME="$runtime_state" \
XDG_RUNTIME_DIR="$runtime_session" \
OMARCHY_NAVIDROME_RUNTIME_DIR="$runtime_backend" \
TEST_SECRET_LOG="$secret_log" \
TEST_SYSTEMCTL_LOG="$systemctl_log" \
TEST_OMARCHY_LOG="$omarchy_log" \
  "$source_root/scripts/uninstall.sh" >/dev/null
[[ $(grep -c '^plugin remove quickshell.navidrome --yes$' "$omarchy_log") -eq 1 ]]

mkdir -p "$runtime_state/omarchy-navidrome/oauth" "$runtime_cache/spotifyd/oauth"
printf '%s\n' '{"mock":"credential"}' \
  >"$runtime_state/omarchy-navidrome/oauth/credentials.json"
printf '%s\n' '{"mock":"legacy-credential"}' \
  >"$runtime_cache/spotifyd/oauth/credentials.json"
XDG_CACHE_HOME="$runtime_cache" \
XDG_STATE_HOME="$runtime_state" \
  "$source_root/scripts/playback-runtime.sh" credentials
PATH="$mock_bin:$PATH" \
XDG_CACHE_HOME="$runtime_cache" \
XDG_STATE_HOME="$runtime_state" \
  "$source_root/scripts/playback-runtime.sh" logout
[[ ! -e $runtime_state/omarchy-navidrome/oauth/credentials.json ]]
[[ ! -e $runtime_cache/spotifyd/oauth/credentials.json ]]
if XDG_CACHE_HOME="$runtime_cache" XDG_STATE_HOME="$runtime_state" \
    "$source_root/scripts/playback-runtime.sh" credentials; then
  echo "playback-runtime.sh reported removed credentials" >&2
  exit 1
fi

set +e
PATH="$mock_bin:$PATH" \
XDG_CACHE_HOME="relative-cache" \
  "$source_root/scripts/playback-runtime.sh" logout >/dev/null 2>&1
unsafe_logout_status=$?
set -e
[[ $unsafe_logout_status -eq 3 ]]

[[ -x $source_root/scripts/setup-playback.sh ]]
[[ -x $source_root/scripts/backend-source-id.sh ]]
[[ -x $source_root/scripts/uninstall.sh ]]
grep -q 'remove-runtime.sh.*--purge' "$source_root/scripts/uninstall.sh"
grep -q 'omarchy plugin remove quickshell.navidrome --yes' "$source_root/scripts/uninstall.sh"
grep -q '^## Remove it completely$' "$source_root/README.md"
grep -q 'pkexec /usr/bin/pacman -S --needed --noconfirm spotifyd' \
  "$source_root/scripts/setup-playback.sh"
! grep -q 'sudo' "$source_root/scripts/setup-playback.sh"
# Package 2 removed the OAuth/browser authorization flow and its scripts with
# it; the plugin's only credential path is the Navidrome keyring identity.
for removed_script in pkce.sh return-from-auth.sh spotifyd-auth.sh \
  spotifyd-logout.sh; do
  [[ ! -e $source_root/scripts/$removed_script ]] || {
    echo "the OAuth-era script $removed_script must be gone" >&2
    exit 1
  }
done
[[ ! -e $source_root/OAuth.js ]] || { echo "OAuth.js must be gone" >&2; exit 1; }
! grep -qi 'pkce\|callbackListener\|quickshell-spotify' "$source_root/AuthManager.qml"
# The Navidrome credential model: keyring identity scoped by fixed attributes,
# validation through Subsonic.js, and the write path via keyring-store.sh.
grep -qF 'service", "quickshell-navidrome' "$source_root/AuthManager.qml"
grep -qF 'kind", "navidrome-credentials' "$source_root/AuthManager.qml"
grep -q 'navidromeCredentials' "$source_root/AuthManager.qml"
grep -q 'normalizeServerUrl' "$source_root/AuthManager.qml"
grep -qF 'service quickshell-navidrome' "$source_root/scripts/keyring-store.sh"
grep -qF 'kind navidrome-credentials' "$source_root/scripts/keyring-store.sh"
grep -qF 'keyring-store.sh' "$source_root/scripts/setup-playback.sh"
grep -qF 'navidrome-credentials' "$source_root/scripts/remove-runtime.sh"
! grep -q 'socat\|xdg-open' "$source_root/scripts/setup.sh"
# The legacy Spotify client-ID setting stays for settings-file compatibility
# until the settings cleanup pass; nothing in the port consumes it.
grep -q '"clientId"' "$source_root/manifest.json"
! grep -q 'settings.clientId' "$source_root/Service.qml"
! grep -q '"oauthPort"' "$source_root/manifest.json"
grep -q 'gh attestation verify' "$source_root/scripts/build-backend.sh"
grep -q -- '--cert-identity' "$source_root/scripts/build-backend.sh"
grep -q -- '--source-ref' "$source_root/scripts/build-backend.sh"
grep -q -- '--source-digest' "$source_root/scripts/build-backend.sh"
grep -q -- '--deny-self-hosted-runners' "$source_root/scripts/build-backend.sh"
! grep -q 'ALLOW_UNVERIFIED' "$source_root/scripts/build-backend.sh"
if grep -E '^[[:space:]]*uses:' \
    "$source_root/.github/workflows/release-backend.yml" \
    | grep -Ev '@[0-9a-f]{40}([[:space:]]+#.*)?$'; then
  echo "release-backend.yml contains a mutable action reference" >&2
  exit 1
fi
jq -e '.version == "0.1.0"
  and .barWidget.defaultSection == "left"
  and .barWidget.defaults.showMiniPlayer == "On"
  and (.barWidget.schema[] | select(.key == "showMiniPlayer").defaultValue) == "On"
  and .barWidget.defaults.showPausedTrack == "On"
  and (.barWidget.schema[] | select(.key == "showPausedTrack").defaultValue) == "On"
  and .barWidget.defaults.showVinylRecord == "Off"
  and (.barWidget.schema[] | select(.key == "showVinylRecord").defaultValue) == "Off"
  and .barWidget.defaults.shortcutHints == "On"
  and (.barWidget.schema[] | select(.key == "shortcutHints").defaultValue) == "On"
  and .barWidget.defaults.showLyrics == "On"
  and (.barWidget.schema[] | select(.key == "showLyrics").defaultValue) == "On"
  and .barWidget.defaults.maxBarTextWidth == "240"
  and (.barWidget.schema[] | select(.key == "maxBarTextWidth").defaultValue) == "240"
  and .barWidget.defaults.audioQuality == "320 kbps"
  and (.barWidget.schema[] | select(.key == "audioQuality").defaultValue) == "320 kbps"' \
  "$source_root/manifest.json" >/dev/null
grep -qx 'section=left' "$source_root/scripts/install-local.sh"
grep -qx 'bitrate = 320' "$source_root/config/spotifyd.conf"
grep -qx 'no_audio_cache = false' "$source_root/config/spotifyd.conf"
grep -qx 'max_cache_size = 1000000000' "$source_root/config/spotifyd.conf"
grep -qx 'Conflicts=omarchy-navidrome-spotifyd.service' \
  "$source_root/systemd/omarchy-navidrome.service"
grep -qx 'Environment=PULSE_LATENCY_MSEC=30' \
  "$source_root/systemd/omarchy-navidrome.service"
grep -qx 'Environment=TOKIO_WORKER_THREADS=2' \
  "$source_root/systemd/omarchy-navidrome.service"

echo "Script tests passed."
