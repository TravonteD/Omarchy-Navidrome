#!/usr/bin/env bash
set -euo pipefail

source_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
action=${1:-}
if (( $# != 1 )); then
  echo "Usage: scripts/playback-runtime.sh check|credentials|start|start-explicit|stop|status|failure|unit|logout" >&2
  exit 2
fi

runtime_dir=${OMARCHY_NAVIDROME_RUNTIME_DIR:-"$HOME/.local/lib/omarchy-navidrome"}
backend_binary="$runtime_dir/omarchy-navidrome-backend"
backend_source_id_file="$runtime_dir/backend-source.sha256"
backend_binary_hash_file="$runtime_dir/backend-binary.sha256"
backend_unit=omarchy-navidrome.service
fallback_unit=omarchy-navidrome-spotifyd.service
config_root=${XDG_CONFIG_HOME:-"$HOME/.config"}
installed_backend_unit="$config_root/systemd/user/omarchy-navidrome.service"
source_backend_unit="$source_root/systemd/omarchy-navidrome.service"
state_root=${XDG_STATE_HOME:-"$HOME/.local/state"}
cache_root=${XDG_CACHE_HOME:-"$HOME/.cache"}

unit_exists() {
  systemctl --user cat "$1" >/dev/null 2>&1
}

backend_install_is_current() {
  local current_source_id expected_source_id expected_binary_hash actual_binary_hash

  [[ -x $backend_binary && -s $backend_source_id_file \
    && -s $backend_binary_hash_file ]] || return 1
  command -v sha256sum >/dev/null 2>&1 || return 1
  current_source_id=$("$source_root/scripts/backend-source-id.sh") || return 1
  expected_source_id=$(<"$backend_source_id_file")
  [[ $expected_source_id == "$current_source_id" ]] || return 1
  expected_binary_hash=$(<"$backend_binary_hash_file")
  [[ $expected_binary_hash =~ ^[0-9a-f]{64}$ ]] || return 1
  actual_binary_hash=$(sha256sum -- "$backend_binary") || return 1
  [[ ${actual_binary_hash%% *} == "$expected_binary_hash" ]] || return 1
  [[ ! -f $source_backend_unit ]] \
    || { [[ -f $installed_backend_unit ]] \
      && cmp -s -- "$source_backend_unit" "$installed_backend_unit"; }
}

preferred_unit() {
  if backend_install_is_current && unit_exists "$backend_unit"; then
    printf '%s\n' "$backend_unit"
  elif command -v spotifyd >/dev/null 2>&1 && unit_exists "$fallback_unit"; then
    printf '%s\n' "$fallback_unit"
  else
    return 1
  fi
}

case $action in
  check)
    preferred_unit >/dev/null
    ;;
  credentials)
    credential_paths=(
      "$state_root/omarchy-navidrome/oauth/credentials.json"
      "$state_root/omarchy-navidrome/zeroconf/credentials.json"
      "$cache_root/spotifyd/oauth/credentials.json"
      "$cache_root/spotifyd/zeroconf/credentials.json"
    )
    for path in "${credential_paths[@]}"; do
      [[ -s $path ]] && exit 0
    done
    exit 1
    ;;
  start|start-explicit)
    unit=$(preferred_unit) || {
      echo "playback-runtime.sh: no installed playback runtime is available" >&2
      exit 1
    }
    failure_path="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/omarchy-navidrome/startup-error.json"
    if [[ $action == start-explicit ]]; then
      rm -f -- "$failure_path"
      systemctl --user reset-failed "$unit" || true
    else
      failure_code=$(jq -r '.code // ""' "$failure_path" 2>/dev/null || true)
      case $failure_code in
        invalid_configuration|missing_credentials|reconnect_exhausted) exit 75 ;;
      esac
      [[ $(systemctl --user show "$unit" -p Result --value) != start-limit-hit ]] || exit 75
    fi
    systemctl --user start "$unit"
    ;;
  stop)
    systemctl --user stop "$backend_unit" 2>/dev/null || true
    systemctl --user stop "$fallback_unit" 2>/dev/null || true
    ;;
  logout)
    # Removes only the spotifyd fallback's saved OAuth files, exactly the
    # surface the removed spotifyd-logout.sh owned. The Navidrome keyring
    # credential set is cleared through AuthManager / remove-runtime.sh.
    [[ $state_root == /* && $state_root != / && $cache_root == /* && $cache_root != / ]] || exit 3
    credential_paths=(
      "$state_root/omarchy-navidrome/oauth/credentials.json"
      "$state_root/omarchy-navidrome/zeroconf/credentials.json"
      "$cache_root/spotifyd/oauth/credentials.json"
      "$cache_root/spotifyd/zeroconf/credentials.json"
    )
    [[ ${credential_paths[0]} == "$state_root/omarchy-navidrome/oauth/credentials.json" ]] || exit 3
    [[ ${credential_paths[2]} == "$cache_root/spotifyd/oauth/credentials.json" ]] || exit 3
    systemctl --user stop "$backend_unit" 2>/dev/null || true
    systemctl --user stop "$fallback_unit" 2>/dev/null || true
    rm -f -- "${credential_paths[@]}"
    ;;
  status)
    unit=$(preferred_unit) || exit 1
    systemctl --user is-active "$unit"
    ;;
  failure)
    unit=$(preferred_unit) || exit 1
    if [[ $(systemctl --user show "$unit" -p Result --value) == start-limit-hit ]]; then
      echo restart_limit
    else
      jq -r '.code // ""' "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/omarchy-navidrome/startup-error.json" 2>/dev/null || true
    fi
    ;;
  unit)
    preferred_unit
    ;;
  *)
    echo "playback-runtime.sh: unknown action: $action" >&2
    exit 2
    ;;
esac
