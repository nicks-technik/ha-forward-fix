#!/bin/sh
# Forward Fix shared pure helpers (no side effects).
# Sourced by run.sh and unit-tested with BATS. Keep POSIX sh.

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

# add_word LIST WORD -> LIST without duplicates
add_word() {
  case " $1 " in
    *" $2 "*) printf '%s' "$1" ;;
    *) if [ -z "$1" ]; then printf '%s' "$2"; else printf '%s %s' "$1" "$2"; fi ;;
  esac
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
