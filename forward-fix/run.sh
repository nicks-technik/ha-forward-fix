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
# Pure helpers live in lib.sh (unit-tested); source them relatively so both
# the container (/run.sh + /lib.sh) and tests work.
# shellcheck disable=SC1091
. "$(dirname "$0")/lib.sh"

OPTIONS_FILE="/data/options.json"
STATUS_FILE="/data/status.json"
MQTT_FLAG="/data/.mqtt_published"
MQTT_DISC_PREFIX="homeassistant"
MQTT_STATE_TOPIC="forward-fix/stats"
DEFAULT_LAN="end0 eth0 wlan0"
DEFAULT_VPN="wt0 tailscale0 wg0"
INTERVAL=30
AUTO_DETECT=true
ENABLE_IPV6=false
DIAGNOSE=false
PRUNE=false
DESIRED4="/tmp/forward_fix_desired4"
DESIRED6="/tmp/forward_fix_desired6"
MQTT_HOST=""
MQTT_PORT=1883
MQTT_USER=""
MQTT_PASS=""
FIRST_RUN=true
LAST_SIG=""

log() { echo "[forward-fix] $1"; }

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
    PR="$(jq -r '.prune_stale // empty' "$OPTIONS_FILE" 2>/dev/null)"
    INT="$(jq -r '.enforce_interval_seconds // empty' "$OPTIONS_FILE" 2>/dev/null)"
    MH="$(jq -r '.mqtt_host // empty' "$OPTIONS_FILE" 2>/dev/null)"
    MP="$(jq -r '.mqtt_port // empty' "$OPTIONS_FILE" 2>/dev/null)"
    MU="$(jq -r '.mqtt_username // empty' "$OPTIONS_FILE" 2>/dev/null)"
    MW="$(jq -r '.mqtt_password // empty' "$OPTIONS_FILE" 2>/dev/null)"
    [ "$AD" = "true" ] && AUTO_DETECT=true
    [ "$AD" = "false" ] && AUTO_DETECT=false
    [ "$IP6" = "true" ] && ENABLE_IPV6=true
    [ "$IP6" = "false" ] && ENABLE_IPV6=false
    [ "$DG" = "true" ] && DIAGNOSE=true
    [ "$DG" = "false" ] && DIAGNOSE=false
    [ "$PR" = "true" ] && PRUNE=true
    [ "$PR" = "false" ] && PRUNE=false
    MQTT_HOST="$MH"; MQTT_USER="$MU"; MQTT_PASS="$MW"
    case "$MP" in
      ''|*[!0-9]* ) MQTT_PORT=1883 ;;
      *) if [ "$MP" -ge 1 ] && [ "$MP" -le 65535 ]; then MQTT_PORT="$MP"; else MQTT_PORT=1883; fi ;;
    esac
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

# v4/v6 subnet splitters and dedup live in lib.sh (unit-tested).

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
  printf '%s|%s|%s|%s\n' "$IN" "$OUT" "$SRC" "$DST" >> "$DESIRED4"
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
  printf '%s|%s|%s|%s\n' "$IN" "$OUT" "$SRC" "$DST" >> "$DESIRED6"
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

ensure_all() {
  ADDED=0
  ADDED6=0
  : > "$DESIRED4"
  : > "$DESIRED6"
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

prune_chain() {
  # $1 = iptables|ip6tables, $2 = desired-signatures file (IN|OUT|SRC|DST per line)
  # Deletes ACCEPT rules whose both interfaces are in our managed universe but
  # which are no longer desired. Never touches foreign rules; never prunes
  # against an empty desired set.
  [ -s "$2" ] || return 0
  UNIVERSE=" $LAN $VPN "
  while IFS= read -r line; do
    case "$line" in *"-j ACCEPT"*) ;; *) continue ;; esac
    IN="$(printf '%s' "$line" | sed -n 's/.* -i \([^ ]*\).*/\1/p')"
    OUT="$(printf '%s' "$line" | sed -n 's/.* -o \([^ ]*\).*/\1/p')"
    SRC="$(printf '%s' "$line" | sed -n 's/.* -s \([^ ]*\).*/\1/p')"
    DST="$(printf '%s' "$line" | sed -n 's/.* -d \([^ ]*\).*/\1/p')"
    [ -n "$IN" ] && [ -n "$OUT" ] || continue
    case "$UNIVERSE" in *" $IN "*) ;; *) continue ;; esac
    case "$UNIVERSE" in *" $OUT "*) ;; *) continue ;; esac
    if ! grep -Fxq "$IN|$OUT|$SRC|$DST" "$2"; then
      # shellcheck disable=SC2086
      if $1 -D DOCKER-USER -i "$IN" -o "$OUT" ${SRC:+-s "$SRC"} ${DST:+-d "$DST"} -j ACCEPT 2>/dev/null; then
        log "pruned stale DOCKER-USER $IN -> $OUT${SRC:+ src $SRC}${DST:+ dst $DST}"
        PRUNED=$((PRUNED+1))
      fi
    fi
  done <<EOF
$($1 -S DOCKER-USER 2>/dev/null | grep '^-A ')
EOF
}

write_status() {
  # $1 = rules_added_this_cycle (saved first: set -- below would clobber $1)
  ADDED_N="$1"
  NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  if [ $((ADDED_N + ${PRUNED:-0})) -gt 0 ]; then
    LAST_CHANGE="$NOW"
  elif [ -z "${LAST_CHANGE:-}" ] && [ -f "$STATUS_FILE" ] && command -v jq >/dev/null 2>&1; then
    LAST_CHANGE="$(jq -r '.last_change // empty' "$STATUS_FILE" 2>/dev/null)"
    [ -n "$LAST_CHANGE" ] || LAST_CHANGE="$NOW"
  elif [ -z "${LAST_CHANGE:-}" ]; then
    LAST_CHANGE="$NOW"
  fi
  if [ -w "/data" ]; then
    COUNT="$(iptables -L DOCKER-USER 2>/dev/null | grep -c ACCEPT)"
    if [ "$COUNT" -gt 0 ]; then HEALTHY="ON"; else HEALTHY="OFF"; fi
    TOTALS="$(chain_totals iptables)"; PKTS="${TOTALS%% *}"; BYTES="${TOTALS##* }"
    COUNT6="null"; PKTS6="null"; BYTES6="null"
    if [ "$ENABLE_IPV6" = "true" ] && command -v ip6tables >/dev/null 2>&1; then
      COUNT6="$(ip6tables -L DOCKER-USER 2>/dev/null | grep -c ACCEPT)"
      TOTALS6="$(chain_totals ip6tables)"; PKTS6="${TOTALS6%% *}"; BYTES6="${TOTALS6##* }"
    fi
    cat > "$STATUS_FILE" <<EOF
{"timestamp":"$NOW","lan_interfaces":"$LAN","vpn_interfaces":"$VPN","docker_user_accept_rules":$COUNT,"healthy":"$HEALTHY","packets_total":$PKTS,"bytes_total":$BYTES,"docker_user_accept_rules_v6":$COUNT6,"packets_total_v6":$PKTS6,"bytes_total_v6":$BYTES6,"ipv6_enabled":$([ "$ENABLE_IPV6" = "true" ] && echo true || echo false),"added_this_cycle":$ADDED_N,"pruned_this_cycle":${PRUNED:-0},"last_change":"$LAST_CHANGE"}
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

mqtt_pub() {
  # $1=topic $2=payload $3=retain(1/0)
  [ -n "$MQTT_HOST" ] || return 1
  command -v mosquitto_pub >/dev/null 2>&1 || return 1
  # shellcheck disable=SC2086
  if [ -n "$MQTT_USER" ]; then
    if [ "$3" = "1" ]; then
      mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$1" -m "$2" -r -q 1 >/dev/null 2>&1
    else
      mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$1" -m "$2" -q 0 >/dev/null 2>&1
    fi
  else
    if [ "$3" = "1" ]; then
      mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -t "$1" -m "$2" -r -q 1 >/dev/null 2>&1
    else
      mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -t "$1" -m "$2" -q 0 >/dev/null 2>&1
    fi
  fi
}

mqtt_device() {
  printf '{"identifiers":["forward_fix"],"name":"Forward Fix","model":"Forward Fix","manufacturer":"ha-forward-fix"}'
}

mqtt_discovery() {
  # $1=sensor_key $2=name $3=unit $4=value_template $5=extra_json (device_class/state_class)
  printf '{"name":"%s","unique_id":"forward_fix_%s","state_topic":"%s","value_template":"%s","device":%s%s}' \
    "$2" "$1" "$MQTT_STATE_TOPIC" "$4" "$(mqtt_device)" "$5"
}

mqtt_cycle() {
  # UI counter entities exist only while diagnose mode is on.
  if [ "$DIAGNOSE" = "true" ] && [ -n "$MQTT_HOST" ] && [ -f "$STATUS_FILE" ] \
      && command -v mosquitto_pub >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    STATE="$(jq -c '{timestamp,packets_total,bytes_total,docker_user_accept_rules,healthy,last_change}' "$STATUS_FILE" 2>/dev/null)"
    [ -n "$STATE" ] || return 0
    mqtt_pub "$MQTT_DISC_PREFIX/sensor/forward_fix_packets/config" \
      "$(mqtt_discovery packets_total "Forward Fix packets" packets '{{ value_json.packets_total }}' ',"state_class":"total_increasing"')" 1
    mqtt_pub "$MQTT_DISC_PREFIX/sensor/forward_fix_bytes/config" \
      "$(mqtt_discovery bytes_total "Forward Fix bytes" B '{{ value_json.bytes_total }}' ',"device_class":"data_size","state_class":"total_increasing"')" 1
    mqtt_pub "$MQTT_DISC_PREFIX/sensor/forward_fix_rules/config" \
      "$(mqtt_discovery docker_user_accept_rules "Forward Fix rules" rules '{{ value_json.docker_user_accept_rules }}' '')" 1
    printf '{"name":"Forward Fix healthy","unique_id":"forward_fix_healthy","device_class":"connectivity","payload_on":"ON","payload_off":"OFF","state_topic":"%s","value_template":"{{ value_json.healthy }}","device":%s}' \
      "$MQTT_STATE_TOPIC" "$(mqtt_device)" > /tmp/forward_fix_health_disc 2>/dev/null
    mqtt_pub "$MQTT_DISC_PREFIX/binary_sensor/forward_fix_healthy/config" "$(cat /tmp/forward_fix_health_disc 2>/dev/null)" 1
    if mqtt_pub "$MQTT_STATE_TOPIC" "$STATE" 1; then
      touch "$MQTT_FLAG" 2>/dev/null
    else
      log "MQTT publish failed ($MQTT_HOST:$MQTT_PORT), will retry"
    fi
  else
    # diagnose off (or broker unconfigured): remove entities if we created them
    if [ -f "$MQTT_FLAG" ] && [ -n "$MQTT_HOST" ] && command -v mosquitto_pub >/dev/null 2>&1; then
      for s in packets bytes rules; do
        mqtt_pub "$MQTT_DISC_PREFIX/sensor/forward_fix_${s}/config" "" 1
      done
      mqtt_pub "$MQTT_DISC_PREFIX/binary_sensor/forward_fix_healthy/config" "" 1
      rm -f "$MQTT_FLAG" 2>/dev/null
      log "diagnose off: removed MQTT entities"
    fi
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
    PRUNED=0
    if [ "$PRUNE" = "true" ]; then
      prune_chain iptables "$DESIRED4"
      if [ "$ENABLE_IPV6" = "true" ] && command -v ip6tables >/dev/null 2>&1; then
        prune_chain ip6tables "$DESIRED6"
      fi
    fi
    SIG="$LAN|$VPN|$CFG_LAN_SUB|$CFG_VPN_SUB|$ENABLE_IPV6|$PRUNE"
    if [ "$ADDED" -gt 0 ] || [ "$ADDED6" -gt 0 ] || [ "$PRUNED" -gt 0 ] || [ "$SIG" != "$LAST_SIG" ]; then
      log "enforced (added v4=$ADDED v6=$ADDED6 pruned=$PRUNED) lan=[$LAN] vpn=[$VPN]"
      LAST_SIG="$SIG"
    fi
    write_status $((ADDED+ADDED6))
    mqtt_cycle
  else
    log "DOCKER-USER not ready, retrying..."
  fi
  FIRST_RUN=false
  sleep "$INTERVAL"
done
