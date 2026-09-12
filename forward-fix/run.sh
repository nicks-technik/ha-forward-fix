#!/bin/sh
# Forward Fix: ensure DOCKER-USER ACCEPT rules between LAN and VPN interfaces.
#
# Features:
#   - merges configured interfaces with auto-detected ones (default-route
#     interface + existing tunnel devices), unless auto_detect is false
#   - optional CIDR scoping via lan_subnets / vpn_subnets (least privilege)
#   - optional IPv6 mirroring via ip6tables (enable_ipv6)
#   - diagnose mode logs addresses, routes and chain state once at startup
#   - writes /data/status.json for external health checks
#
# Interface names and CIDRs are strictly validated to prevent rule injection.

OPTIONS_FILE="/data/options.json"
STATUS_FILE="/data/status.json"
DEFAULT_LAN="end0 eth0 wlan0"
DEFAULT_VPN="wt0 tailscale0 wg0"
INTERVAL=30
AUTO_DETECT=true
ENABLE_IPV6=false
DIAGNOSE=false
FIRST_RUN=true
LAST_SIG=""

log() { echo "[forward-fix] $1"; }

valid_iface() {
  case "$1" in
    ""|*[!a-zA-Z0-9._-]* ) return 1 ;;
    *) return 0 ;;
  esac
}

valid_cidr() {
  # 192.168.0.0/24 or fd00::/64 style, digits/hex + . : / only
  case "$1" in
    ""|*[!0-9a-fA-F.:\/]* ) return 1 ;;
    *"/"* ) return 0 ;;
    *) return 1 ;;
  esac
}

is_v6() {
  case "$1" in *:*) return 0 ;; *) return 1 ;; esac
}

load_options() {
  LAN_CFG=""
  VPN_CFG=""
  LAN_SUB=""
  VPN_SUB=""
  if [ -f "$OPTIONS_FILE" ] && command -v jq >/dev/null 2>&1; then
    LAN_CFG="$(jq -r '.lan_interfaces // empty | if type=="array" then join(" ") else empty end' "$OPTIONS_FILE" 2>/dev/null)"
    VPN_CFG="$(jq -r '.vpn_interfaces // empty | if type=="array" then join(" ") else empty end' "$OPTIONS_FILE" 2>/dev/null)"
    LAN_SUB="$(jq -r '.lan_subnets // empty | if type=="array" then join(" ") else empty end' "$OPTIONS_FILE" 2>/dev/null)"
    VPN_SUB="$(jq -r '.vpn_subnets // empty | if type=="array" then join(" ") else empty end' "$OPTIONS_FILE" 2>/dev/null)"
    AD="$(jq -r '.auto_detect // empty' "$OPTIONS_FILE" 2>/dev/null)"
    IP6="$(jq -r '.enable_ipv6 // empty' "$OPTIONS_FILE" 2>/dev/null)"
    DG="$(jq -r '.diagnose // empty' "$OPTIONS_FILE" 2>/dev/null)"
    INT="$(jq -r '.enforce_interval_seconds // empty' "$OPTIONS_FILE" 2>/dev/null)"
    [ "$AD" = "true" ] && AUTO_DETECT=true
    [ "$AD" = "false" ] && AUTO_DETECT=false
    [ "$IP6" = "true" ] && ENABLE_IPV6=true
    [ "$IP6" = "false" ] && ENABLE_IPV6=false
    [ "$DG" = "true" ] && DIAGNOSE=true
    [ "$DG" = "false" ] && DIAGNOSE=false
    case "$INT" in
      ''|*[!0-9]* ) ;;
      *) if [ "$INT" -ge 5 ] && [ "$INT" -le 3600 ]; then INTERVAL="$INT"; fi ;;
    esac
  fi
  [ -n "$LAN_CFG" ] || LAN_CFG="$DEFAULT_LAN"
  [ -n "$VPN_CFG" ] || VPN_CFG="$DEFAULT_VPN"
  CFG_LAN="$LAN_CFG"
  CFG_VPN="$VPN_CFG"
  CFG_LAN_SUB="$LAN_SUB"
  CFG_VPN_SUB="$VPN_SUB"
}

# add_word LIST WORD -> LIST without duplicates
add_word() {
  case " $1 " in
    *" $2 "*) printf '%s' "$1" ;;
    *) if [ -z "$1" ]; then printf '%s' "$2"; else printf '%s %s' "$1" "$2"; fi ;;
  esac
}

detect_interfaces() {
  DET_LAN=""
  DET_VPN=""
  if [ "$AUTO_DETECT" = "true" ]; then
    # default-route interface (physical uplink), ignoring tunnels/docker/virt
    DEF_IF="$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | head -n 1)"
    if valid_iface "$DEF_IF"; then
      case "$DEF_IF" in
        wt*|tailscale*|wg*|tun*|zt*|docker*|hassio|veth*|br-*|lo) ;;
        *) DET_LAN="$(add_word "$DET_LAN" "$DEF_IF")" ;;
      esac
    fi
    # existing tunnel devices
    if [ -d /sys/class/net ]; then
      for IFPATH in /sys/class/net/*; do
        IF="$(basename "$IFPATH")"
        case "$IF" in
          wt*|tailscale*|wg*|tun*|zt*)
            if valid_iface "$IF"; then DET_VPN="$(add_word "$DET_VPN" "$IF")"; fi ;;
        esac
      done
    fi
  fi
  LAN="$CFG_LAN"
  for w in $DET_LAN; do LAN="$(add_word "$LAN" "$w")"; done
  VPN="$CFG_VPN"
  for w in $DET_VPN; do VPN="$(add_word "$VPN" "$w")"; done
}

ensure_rule4() {
  # ensure_rule4 IN OUT [SRC] [DST]
  IN="$1"; OUT="$2"; SRC="$3"; DST="$4"
  valid_iface "$IN" || { log "skipping invalid interface '$IN'"; return 0; }
  valid_iface "$OUT" || { log "skipping invalid interface '$OUT'"; return 0; }
  if [ -n "$SRC" ]; then
    valid_cidr "$SRC" || { log "skipping invalid source CIDR '$SRC'"; return 0; }
    is_v6 "$SRC" && { log "skipping IPv6 source '$SRC' for iptables"; return 0; }
  fi
  if [ -n "$DST" ]; then
    valid_cidr "$DST" || { log "skipping invalid dest CIDR '$DST'"; return 0; }
    is_v6 "$DST" && { log "skipping IPv6 dest '$DST' for iptables"; return 0; }
  fi
  if [ -n "$SRC" ] && [ -n "$DST" ]; then
    iptables -C DOCKER-USER -i "$IN" -o "$OUT" -s "$SRC" -d "$DST" -j ACCEPT 2>/dev/null && return 0
    iptables -I DOCKER-USER -i "$IN" -o "$OUT" -s "$SRC" -d "$DST" -j ACCEPT 2>&1 && { log "added DOCKER-USER $IN -> $OUT $SRC -> $DST"; ADDED=$((ADDED+1)); }
  elif [ -n "$SRC" ]; then
    iptables -C DOCKER-USER -i "$IN" -o "$OUT" -s "$SRC" -j ACCEPT 2>/dev/null && return 0
    iptables -I DOCKER-USER -i "$IN" -o "$OUT" -s "$SRC" -j ACCEPT 2>&1 && { log "added DOCKER-USER $IN -> $OUT src $SRC"; ADDED=$((ADDED+1)); }
  elif [ -n "$DST" ]; then
    iptables -C DOCKER-USER -i "$IN" -o "$OUT" -d "$DST" -j ACCEPT 2>/dev/null && return 0
    iptables -I DOCKER-USER -i "$IN" -o "$OUT" -d "$DST" -j ACCEPT 2>&1 && { log "added DOCKER-USER $IN -> $OUT dst $DST"; ADDED=$((ADDED+1)); }
  else
    iptables -C DOCKER-USER -i "$IN" -o "$OUT" -j ACCEPT 2>/dev/null && return 0
    iptables -I DOCKER-USER -i "$IN" -o "$OUT" -j ACCEPT 2>&1 && { log "added DOCKER-USER $IN -> $OUT"; ADDED=$((ADDED+1)); }
  fi
}

ensure_rule6() {
  # ensure_rule6 IN OUT [SRC] [DST] -- IPv6 CIDRs only for SRC/DST
  IN="$1"; OUT="$2"; SRC="$3"; DST="$4"
  valid_iface "$IN" || return 0
  valid_iface "$OUT" || return 0
  if [ -n "$SRC" ]; then
    valid_cidr "$SRC" || { log "skipping invalid source CIDR '$SRC'"; return 0; }
    is_v6 "$SRC" || return 0
  fi
  if [ -n "$DST" ]; then
    valid_cidr "$DST" || { log "skipping invalid dest CIDR '$DST'"; return 0; }
    is_v6 "$DST" || return 0
  fi
  if [ -n "$SRC" ] && [ -n "$DST" ]; then
    ip6tables -C DOCKER-USER -i "$IN" -o "$OUT" -s "$SRC" -d "$DST" -j ACCEPT 2>/dev/null && return 0
    ip6tables -I DOCKER-USER -i "$IN" -o "$OUT" -s "$SRC" -d "$DST" -j ACCEPT 2>&1 && { log "added DOCKER-USER(v6) $IN -> $OUT $SRC -> $DST"; ADDED6=$((ADDED6+1)); }
  elif [ -n "$SRC" ]; then
    ip6tables -C DOCKER-USER -i "$IN" -o "$OUT" -s "$SRC" -j ACCEPT 2>/dev/null && return 0
    ip6tables -I DOCKER-USER -i "$IN" -o "$OUT" -s "$SRC" -j ACCEPT 2>&1 && { log "added DOCKER-USER(v6) $IN -> $OUT src $SRC"; ADDED6=$((ADDED6+1)); }
  elif [ -n "$DST" ]; then
    ip6tables -C DOCKER-USER -i "$IN" -o "$OUT" -d "$DST" -j ACCEPT 2>/dev/null && return 0
    ip6tables -I DOCKER-USER -i "$IN" -o "$OUT" -d "$DST" -j ACCEPT 2>&1 && { log "added DOCKER-USER(v6) $IN -> $OUT dst $DST"; ADDED6=$((ADDED6+1)); }
  else
    ip6tables -C DOCKER-USER -i "$IN" -o "$OUT" -j ACCEPT 2>/dev/null && return 0
    ip6tables -I DOCKER-USER -i "$IN" -o "$OUT" -j ACCEPT 2>&1 && { log "added DOCKER-USER(v6) $IN -> $OUT"; ADDED6=$((ADDED6+1)); }
  fi
}

# v4-only subnet words (no colon)
v4_words() {
  OUT=""
  for w in $1; do
    case "$w" in *:*) ;; *) OUT="$OUT $w" ;; esac
  done
  printf '%s' "$OUT"
}

# v6-only subnet words (contain colon)
v6_words() {
  OUT=""
  for w in $1; do
    case "$w" in *:*) OUT="$OUT $w" ;; esac
  done
  printf '%s' "$OUT"
}

ensure_all() {
  ADDED=0
  ADDED6=0
  LAN4_SUB="$(v4_words "$CFG_LAN_SUB")"
  VPN4_SUB="$(v4_words "$CFG_VPN_SUB")"
  for lan in $LAN; do
    for vpn in $VPN; do
      # LAN -> VPN direction carries LAN source / VPN dest scope
      if [ -n "$LAN4_SUB" ] && [ -n "$VPN4_SUB" ]; then
        for s in $LAN4_SUB; do
          for d in $VPN4_SUB; do ensure_rule4 "$lan" "$vpn" "$s" "$d"; done
        done
      elif [ -n "$LAN4_SUB" ]; then
        for s in $LAN4_SUB; do ensure_rule4 "$lan" "$vpn" "$s" ""; done
      elif [ -n "$VPN4_SUB" ]; then
        for d in $VPN4_SUB; do ensure_rule4 "$lan" "$vpn" "" "$d"; done
      else
        ensure_rule4 "$lan" "$vpn" "" ""
      fi
      # VPN -> LAN direction carries VPN source / LAN dest scope
      if [ -n "$LAN4_SUB" ] && [ -n "$VPN4_SUB" ]; then
        for s in $VPN4_SUB; do
          for d in $LAN4_SUB; do ensure_rule4 "$vpn" "$lan" "$s" "$d"; done
        done
      elif [ -n "$VPN4_SUB" ]; then
        for s in $VPN4_SUB; do ensure_rule4 "$vpn" "$lan" "$s" ""; done
      elif [ -n "$LAN4_SUB" ]; then
        for d in $LAN4_SUB; do ensure_rule4 "$vpn" "$lan" "" "$d"; done
      else
        ensure_rule4 "$vpn" "$lan" "" ""
      fi
    done
  done
  if [ "$ENABLE_IPV6" = "true" ] && command -v ip6tables >/dev/null 2>&1; then
    LAN6_SUB="$(v6_words "$CFG_LAN_SUB")"
    VPN6_SUB="$(v6_words "$CFG_VPN_SUB")"
    for lan in $LAN; do
      for vpn in $VPN; do
        if [ -n "$LAN6_SUB" ] && [ -n "$VPN6_SUB" ]; then
          for s in $LAN6_SUB; do
            for d in $VPN6_SUB; do ensure_rule6 "$lan" "$vpn" "$s" "$d"; done
          done
          for s in $VPN6_SUB; do
            for d in $LAN6_SUB; do ensure_rule6 "$vpn" "$lan" "$s" "$d"; done
          done
        elif [ -n "$LAN6_SUB" ]; then
          for s in $LAN6_SUB; do ensure_rule6 "$lan" "$vpn" "$s" ""; done
          for d in $LAN6_SUB; do ensure_rule6 "$vpn" "$lan" "" "$d"; done
        elif [ -n "$VPN6_SUB" ]; then
          for d in $VPN6_SUB; do ensure_rule6 "$lan" "$vpn" "" "$d"; done
          for s in $VPN6_SUB; do ensure_rule6 "$vpn" "$lan" "$s" ""; done
        else
          ensure_rule6 "$lan" "$vpn" "" ""
          ensure_rule6 "$vpn" "$lan" "" ""
        fi
      done
    done
  fi
}

chain_totals() {
  # $1 = iptables|ip6tables ; echoes "packets bytes" for DOCKER-USER
  $1 -L DOCKER-USER -v -n -x 2>/dev/null | awk 'NR>2 {p+=$1; b+=$2} END {print p+0, b+0}'
}

write_status() {
  # $1 = rules_added_this_cycle
  NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  if [ -w "/data" ]; then
    COUNT="$(iptables -L DOCKER-USER 2>/dev/null | grep -c ACCEPT)"
    set -- $(chain_totals iptables); PKTS="$1"; BYTES="$2"
    COUNT6="null"; PKTS6="null"; BYTES6="null"
    if [ "$ENABLE_IPV6" = "true" ] && command -v ip6tables >/dev/null 2>&1; then
      COUNT6="$(ip6tables -L DOCKER-USER 2>/dev/null | grep -c ACCEPT)"
      set -- $(chain_totals ip6tables); PKTS6="$1"; BYTES6="$2"
    fi
    cat > "$STATUS_FILE" <<EOF
{"timestamp":"$NOW","lan_interfaces":"$LAN","vpn_interfaces":"$VPN","docker_user_accept_rules":$COUNT,"packets_total":$PKTS,"bytes_total":$BYTES,"docker_user_accept_rules_v6":$COUNT6,"packets_total_v6":$PKTS6,"bytes_total_v6":$BYTES6,"ipv6_enabled":$([ "$ENABLE_IPV6" = "true" ] && echo true || echo false),"added_this_cycle":$1}
EOF
  fi
}

diagnose() {
  log "=== diagnose: addresses ==="
  ip -o addr show 2>&1 | while IFS= read -r line; do log "  $line"; done
  log "=== diagnose: routes ==="
  ip route show 2>&1 | while IFS= read -r line; do log "  $line"; done
  log "=== diagnose: DOCKER-USER (ipv4) ==="
  iptables -L DOCKER-USER -v -n 2>&1 | while IFS= read -r line; do log "  $line"; done
  if [ "$ENABLE_IPV6" = "true" ] && command -v ip6tables >/dev/null 2>&1; then
    log "=== diagnose: DOCKER-USER (ipv6) ==="
    ip6tables -L DOCKER-USER -v -n 2>&1 | while IFS= read -r line; do log "  $line"; done
  fi
}

log "starting Forward Fix"
while true; do
  load_options
  detect_interfaces
  if iptables -L DOCKER-USER >/dev/null 2>&1; then
    if [ "$DIAGNOSE" = "true" ] && [ "$FIRST_RUN" = "true" ]; then
      diagnose
    fi
    ensure_all
    SIG="$LAN|$VPN|$CFG_LAN_SUB|$CFG_VPN_SUB|$ENABLE_IPV6"
    if [ "$ADDED" -gt 0 ] || [ "$ADDED6" -gt 0 ] || [ "$SIG" != "$LAST_SIG" ]; then
      log "enforced (added v4=$ADDED v6=$ADDED6) lan=[$LAN] vpn=[$VPN]"
      LAST_SIG="$SIG"
    fi
    write_status $((ADDED+ADDED6))
  else
    log "DOCKER-USER not ready, retrying..."
  fi
  FIRST_RUN=false
  sleep "$INTERVAL"
done
