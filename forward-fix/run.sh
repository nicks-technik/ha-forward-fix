#!/bin/sh
# Forward Fix: ensure DOCKER-USER ACCEPT rules between LAN and VPN interfaces.
# Reads /data/options.json (Supervisor), falls back to defaults.
# Interface names are strictly validated to prevent rule injection.

OPTIONS_FILE="/data/options.json"
DEFAULT_LAN="end0 eth0 wlan0"
DEFAULT_VPN="wt0 tailscale0 wg0"
INTERVAL=30

log() { echo "[forward-fix] $1"; }

valid_iface() {
  # allow only kernel interface names: letters, digits, ., _, -
  case "$1" in
    ""|*[!a-zA-Z0-9._-]* ) return 1 ;;
    *) return 0 ;;
  esac
}

load_options() {
  LAN="$DEFAULT_LAN"
  VPN="$DEFAULT_VPN"
  if [ -f "$OPTIONS_FILE" ] && command -v jq >/dev/null 2>&1; then
    lan_json="$(jq -r '.lan_interfaces // empty | if type=="array" then join(" ") else empty end' "$OPTIONS_FILE" 2>/dev/null)"
    vpn_json="$(jq -r '.vpn_interfaces // empty | if type=="array" then join(" ") else empty end' "$OPTIONS_FILE" 2>/dev/null)"
    int_json="$(jq -r '.enforce_interval_seconds // empty' "$OPTIONS_FILE" 2>/dev/null)"
    [ -n "$lan_json" ] && LAN="$lan_json"
    [ -n "$vpn_json" ] && VPN="$vpn_json"
    case "$int_json" in
      ''|*[!0-9]* ) ;;
      *) if [ "$int_json" -ge 5 ] && [ "$int_json" -le 3600 ]; then INTERVAL="$int_json"; fi ;;
    esac
  fi
}

ensure_pair() {
  IN="$1"
  OUT="$2"
  if ! valid_iface "$IN" || ! valid_iface "$OUT"; then
    log "skipping invalid interface pair: '$IN' -> '$OUT'"
    return 0
  fi
  if ! iptables -C DOCKER-USER -i "$IN" -o "$OUT" -j ACCEPT 2>/dev/null; then
    if iptables -I DOCKER-USER -i "$IN" -o "$OUT" -j ACCEPT 2>&1; then
      log "added DOCKER-USER $IN -> $OUT"
    else
      log "failed to add DOCKER-USER $IN -> $OUT"
    fi
  fi
}

log "starting (interval ${INTERVAL}s)"
while true; do
  load_options
  if iptables -L DOCKER-USER >/dev/null 2>&1; then
    for lan in $LAN; do
      for vpn in $VPN; do
        ensure_pair "$lan" "$vpn"
        ensure_pair "$vpn" "$lan"
      done
    done
  else
    log "DOCKER-USER not ready, retrying..."
  fi
  sleep "$INTERVAL"
done
