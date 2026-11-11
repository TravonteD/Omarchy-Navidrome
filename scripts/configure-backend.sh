#!/usr/bin/env bash
set -euo pipefail

# Writes the playback settings the engine reads from backend.conf [global]:
# device_name, format, and max_bit_rate. The three stdin lines come from
# DaemonManager: device name, stream format, bit-rate cap. The accepted
# format list matches backend/src/config.rs validation exactly (it checks
# against backend/src/stream.rs FORMATS: "" plus mp3/flac/wav/ogg/opus/aac);
# "source" and a cap of 0 mean "keep the server's own format" and the keys
# are removed so the backend defaults stand. maxBitRate is only ever offered
# as the bounded UI list (0, 64, 96, 128, 192, 320), a subset of what the
# backend accepts. A leftover Spotify-era `bitrate` line passes through
# untouched and still validates (96/160/320).

config_root=${XDG_CONFIG_HOME:-"$HOME/.config"}
config_file="$config_root/omarchy-navidrome/backend.conf"

IFS= read -r device_name
format=""
format_specified=0
if IFS= read -r format; then
  format_specified=1
fi
max_bit_rate=""
max_bit_rate_specified=0
if IFS= read -r max_bit_rate; then
  max_bit_rate_specified=1
fi

if [[ -z $device_name || ${#device_name} -gt 64 || $device_name == *'"'* || $device_name == *'\'* ]]; then
  exit 3
fi
if [[ $device_name =~ [^[:print:]] ]]; then
  exit 3
fi
if (( format_specified )); then
  case $format in
    source|mp3|flac|wav|ogg|opus|aac) ;;
    *) exit 3 ;;
  esac
fi
if (( max_bit_rate_specified )); then
  if [[ ! $max_bit_rate =~ ^[0-9]+$ ]] || (( max_bit_rate > 65535 )); then
    exit 3
  fi
  case $max_bit_rate in
    0|64|96|128|192|320) ;;
    *) exit 3 ;;
  esac
fi
if [[ ! -f $config_file ]]; then
  exit 4
fi

temporary=$(mktemp "${config_file}.tmp.XXXXXX")
trap 'rm -f -- "$temporary"' EXIT
chmod 600 "$temporary"

awk -v name="$device_name" \
    -v format="$format" -v format_set="$format_specified" \
    -v rate="$max_bit_rate" -v rate_set="$max_bit_rate_specified" '
  /^device_name[[:space:]]*=/ {
    print "device_name = \"" name "\""
    found_name = 1
    next
  }
  /^format[[:space:]]*=/ {
    if (format_set && format == "source") { next }
    if (format_set) print "format = \"" format "\""
    else print
    found_format = 1
    next
  }
  /^max_bit_rate[[:space:]]*=/ {
    if (rate_set && rate == 0) { next }
    if (rate_set) print "max_bit_rate = " rate
    else print
    found_rate = 1
    next
  }
  /^device[[:space:]]*=/ {
    next
  }
  /^autoplay[[:space:]]*=/ {
    print "autoplay = true"
    found_autoplay = 1
    next
  }
  { print }
  END {
    if (!found_name) print "device_name = \"" name "\""
    if (!found_format && format_set && format != "source")
      print "format = \"" format "\""
    if (!found_rate && rate_set && rate != 0) print "max_bit_rate = " rate
    if (!found_autoplay) print "autoplay = true"
  }
' "$config_file" >"$temporary"

mv -f -- "$temporary" "$config_file"
trap - EXIT
