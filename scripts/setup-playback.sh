#!/usr/bin/env bash
set -euo pipefail

# Guided first-run for Navidrome. Installs the plugin's playback backend, then
# provisions the connection: the server URL, username, and password are
# verified against the live server with token auth and only then stored in the
# keyring. There is no OAuth, no callback server, and no browser round-trip.

source_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

server_url=${OMARCHY_NAVIDROME_SERVER_URL:-}
username=${OMARCHY_NAVIDROME_USERNAME:-}
password=${OMARCHY_NAVIDROME_PASSWORD:-}
password_file=
ping_timeout=${OMARCHY_NAVIDROME_PING_TIMEOUT:-10}
skip_credentials=0

usage() {
  cat <<'EOF'
Usage: scripts/setup-playback.sh [--server-url URL] [--username NAME]
       [--password-file PATH] [--ping-timeout SECONDS] [--skip-credentials]

Installs the plugin playback backend, then verifies and stores the Navidrome
connection. Unattended runs read OMARCHY_NAVIDROME_SERVER_URL,
OMARCHY_NAVIDROME_USERNAME, and OMARCHY_NAVIDROME_PASSWORD from the
environment, or take --server-url/--username/--password-file (the password
never rides argv: it reaches the probe through the environment or stdin
only). Without input and without a terminal, credential provisioning is
skipped so the automatic in-shell setup stays non-interactive.

Exit codes: 0 success · 2 usage · 3 invalid input · 10 wrong credentials ·
11 token authentication rejected · 12 not authorized · 1 could not connect
(or the keyring refused the write). Nothing is stored unless the live probe
succeeded.
EOF
}

while (( $# > 0 )); do
  case $1 in
    --server-url)
      [[ $# -ge 2 ]] || { echo "setup-playback.sh: --server-url requires a value" >&2; exit 2; }
      server_url=$2
      shift 2
      ;;
    --username)
      [[ $# -ge 2 ]] || { echo "setup-playback.sh: --username requires a value" >&2; exit 2; }
      username=$2
      shift 2
      ;;
    --password-file)
      [[ $# -ge 2 ]] || { echo "setup-playback.sh: --password-file requires a value" >&2; exit 2; }
      password_file=$2
      shift 2
      ;;
    --ping-timeout)
      [[ $# -ge 2 ]] || { echo "setup-playback.sh: --ping-timeout requires a value" >&2; exit 2; }
      ping_timeout=$2
      shift 2
      ;;
    --skip-credentials)
      skip_credentials=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "setup-playback.sh: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# Plugin installs intentionally do not run hooks. Prefer the verified or
# source-built plugin backend, and retain Arch spotifyd as a no-build fallback.
set +e
"$source_root/scripts/setup.sh"
setup_status=$?
set -e
if (( setup_status == 0 )); then
  :
else
  if (( setup_status != 30 )); then
    exit 22
  fi

  if ! command -v spotifyd >/dev/null 2>&1; then
    command -v pkexec >/dev/null 2>&1 || exit 20
    if ! pkexec /usr/bin/pacman -S --needed --noconfirm spotifyd; then
      exit 21
    fi
  fi

  if ! "$source_root/scripts/setup.sh" --skip-backend-build; then
    exit 22
  fi
fi

if (( skip_credentials )); then
  exit 0
fi

if [[ -n $password_file ]]; then
  [[ -z $password ]] || { echo "setup-playback.sh: --password-file conflicts with OMARCHY_NAVIDROME_PASSWORD" >&2; exit 2; }
  [[ -r $password_file ]] || { echo "setup-playback.sh: cannot read the password file" >&2; exit 3; }
  IFS= read -r password <"$password_file" || password=
fi

# Unattended input wins; otherwise prompt on a terminal; otherwise skip
# quietly (the automatic in-shell path must never block on stdin).
if [[ -z $server_url || -z $username || -z $password ]]; then
  if [[ -t 0 ]]; then
    if [[ -z $server_url ]]; then
      read -r -p "Navidrome server base URL (e.g. https://music.example.com): " server_url
    fi
    if [[ -z $username ]]; then
      read -r -p "Navidrome username: " username
    fi
    if [[ -z $password ]]; then
      read -rs -p "Navidrome password: " password
      printf '\n'
    fi
  else
    exit 0
  fi
fi

server_url=${server_url//[[:space:]]/}
username=${username//[[:space:]]/}
if [[ -z $server_url || -z $username || -z $password ]]; then
  echo "setup-playback.sh: the server URL, username, and password are all required. Nothing was stored." >&2
  exit 3
fi

# Live probe against the actual server before anything is written. The
# embedded python owns URL normalization, token auth (t = md5(password+salt)
# with a fresh salt per request), and the typed outcome mapping. The password
# reaches it through the environment, never argv, and is never echoed; TLS
# certificate validation is never bypassed.
set +e
probe_output=$(OMARCHY_NAVIDROME_PROBE_URL="$server_url" \
  OMARCHY_NAVIDROME_USERNAME="$username" \
  OMARCHY_NAVIDROME_PASSWORD="$password" \
  OMARCHY_NAVIDROME_PING_TIMEOUT="$ping_timeout" \
  python3 - <<'NAVPROBE'
import hashlib, json, os, re, ssl, sys, urllib.error, urllib.parse, urllib.request

def fail(code, message):
    sys.stderr.write(message + "\n")
    sys.exit(code)

raw = os.environ.get("OMARCHY_NAVIDROME_PROBE_URL", "").strip()
username = os.environ.get("OMARCHY_NAVIDROME_USERNAME", "").strip()
password = os.environ.get("OMARCHY_NAVIDROME_PASSWORD", "")
try:
    timeout = float(os.environ.get("OMARCHY_NAVIDROME_PING_TIMEOUT") or "10")
except ValueError:
    timeout = 10.0
if timeout <= 0:
    timeout = 10.0

# Mirrors Subsonic.splitServerUrl: http/https only, lowercased host, optional
# numeric port, query/fragment stripped, trailing slashes trimmed.
match = re.match(r"^([A-Za-z][A-Za-z0-9+.\-]*)://([^/?#]*)([^#]*)?$", raw)
if not match:
    fail(3, "The server address is not a valid http or https URL.")
scheme = match.group(1).lower()
if scheme not in ("http", "https"):
    fail(3, "The server address is not a valid http or https URL.")
host = match.group(2)
port = ""
if host.startswith("["):
    close = host.find("]")
    if close < 0:
        fail(3, "The server address is not a valid http or https URL.")
    rest = host[close + 1:]
    host = host[:close + 1]
    if rest.startswith(":"):
        port = rest[1:]
    elif rest:
        fail(3, "The server address is not a valid http or https URL.")
elif ":" in host:
    parts = host.split(":")
    if len(parts) != 2:
        fail(3, "The server address is not a valid http or https URL.")
    host, port = parts
if not host:
    fail(3, "The server address is not a valid http or https URL.")
if port and not re.match(r"^[0-9]{1,5}$", port):
    fail(3, "The server address is not a valid http or https URL.")
path = match.group(3) or ""
if "?" in path:
    path = path[:path.index("?")]
path = path.rstrip("/")
base = scheme + "://" + host + ((":" + port) if port else "") + path


def call(endpoint):
    salt = os.urandom(12).hex()
    token = hashlib.md5((password + salt).encode("utf-8")).hexdigest()
    query = urllib.parse.urlencode({
        "u": username, "t": token, "s": salt,
        "v": "1.16.1", "c": "omarchy-navidrome", "f": "json",
    })
    request = urllib.request.Request(
        base + "/rest/" + endpoint + "?" + query,
        headers={"User-Agent": "omarchy-navidrome"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            if not 200 <= response.status < 300:
                fail(1, "The server answered with HTTP " + str(response.status)
                     + ". Check the server address and try again.")
            return json.loads(response.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as error:
        fail(1, "The server answered with HTTP " + str(error.code)
             + ". Check the server address and try again.")
    except urllib.error.URLError as error:
        reason = getattr(error, "reason", error)
        if isinstance(reason, ssl.SSLError):
            fail(1, "The server's TLS certificate could not be validated. "
                    "The connection was not downgraded; fix the certificate "
                    "or use the plain-http address deliberately.")
        fail(1, "Could not reach the server. Check the address, your network, "
                "and try again.")
    except OSError:
        fail(1, "Could not reach the server. Check the address, your network, "
                "and try again.")


def typed_failure(payload):
    node = payload.get("subsonic-response", {}) if isinstance(payload, dict) else {}
    error = node.get("error") if isinstance(node, dict) else None
    code = error.get("code") if isinstance(error, dict) else None
    if code == 40:
        fail(10, "Wrong username or password for this server. Nothing was stored.")
    if code in (41, 42):
        fail(11, "The server rejected token authentication. Nothing was stored.")
    if code == 50:
        fail(12, "This user is not authorized to use the server. Nothing was stored.")
    if code == 30:
        fail(1, "The server needs a newer client version. Nothing was stored.")
    fail(1, "The server reported an error. Nothing was stored.")


ping = call("ping")
if not isinstance(ping, dict) \
    or ping.get("subsonic-response", {}).get("status") != "ok":
    typed_failure(ping if isinstance(ping, dict) else None)

user = call("getUser")
node = user.get("subsonic-response", {}) if isinstance(user, dict) else {}
if not isinstance(node, dict) or node.get("status") != "ok":
    typed_failure(user)
if not isinstance(node.get("user"), dict) or not node["user"].get("username"):
    fail(1, "The server answered, but the user could not be verified. Nothing was stored.")

if scheme == "http":
    sys.stderr.write(
        "Warning: " + base + " uses plain http://. The connection is NOT "
        "private; traffic can be read on the network. The credentials were "
        "still stored as requested.\n")
print(base)
NAVPROBE
)
probe_status=$?
set -e

case $probe_status in
  0) ;;
  3) echo "setup-playback.sh: nothing was stored." >&2; exit 3 ;;
  10|11|12) echo "setup-playback.sh: nothing was stored." >&2; exit $probe_status ;;
  *) echo "setup-playback.sh: nothing was stored." >&2; exit 1 ;;
esac

normalized_url=$(printf '%s\n' "$probe_output" | head -n 1)
if [[ -z $normalized_url ]]; then
  echo "setup-playback.sh: the probe did not return a server address. Nothing was stored." >&2
  exit 1
fi

# Exactly one credential set per server identity: the fixed keyring
# attributes make a re-run for the same server overwrite in place.
if ! OMARCHY_NAVIDROME_KEYRING_URL="$normalized_url" \
  OMARCHY_NAVIDROME_USERNAME="$username" \
  OMARCHY_NAVIDROME_PASSWORD="$password" \
  python3 -c 'import json, os; print(json.dumps({
    "v": 1,
    "url": os.environ["OMARCHY_NAVIDROME_KEYRING_URL"],
    "username": os.environ["OMARCHY_NAVIDROME_USERNAME"],
    "password": os.environ["OMARCHY_NAVIDROME_PASSWORD"]}))' \
    | "$source_root/scripts/keyring-store.sh" navidrome; then
  echo "setup-playback.sh: the connection was verified, but the keyring refused to store it. Unlock your keyring and try again." >&2
  exit 1
fi

echo "Connected to the Navidrome server. The credentials were stored in your keyring."
