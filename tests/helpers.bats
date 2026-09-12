#!/usr/bin/env bats
# Unit tests for forward-fix pure helpers (forward-fix/lib.sh).
# Run: bats tests/   (or via the lint CI workflow)

setup() {
  # shellcheck disable=SC1091
  . "$BATS_TEST_DIRNAME/../forward-fix/lib.sh"
}

@test "valid_iface accepts normal interface names" {
  valid_iface end0
  valid_iface eth0
  valid_iface wlan0
  valid_iface wt0
  valid_iface tailscale0
  valid_iface "br-abc123"
  valid_iface "veth1a2b3c"
}

@test "valid_iface rejects empty and hostile names" {
  ! valid_iface ""
  ! valid_iface "eth0;reboot"
  ! valid_iface "eth0 && id"
  ! valid_iface "eth0|wt0"
  ! valid_iface "../etc"
  ! valid_iface "eth 0"
  ! valid_iface 'eth0$(id)'
}

@test "valid_cidr accepts v4 and v6 CIDRs" {
  valid_cidr "192.168.178.0/24"
  valid_cidr "10.53.164.0/24"
  valid_cidr "fd00::/64"
  valid_cidr "2001:db8::/32"
}

@test "valid_cidr rejects hosts without prefix and injections" {
  ! valid_cidr ""
  ! valid_cidr "192.168.178.1"
  ! valid_cidr "anywhere"
  ! valid_cidr "10.0.0.0/8; reboot"
  ! valid_cidr "10.0.0.0/8 && id"
  ! valid_cidr "10.0.0.0/8|tee"
}

@test "is_v6 distinguishes address families" {
  is_v6 "fd00::/64"
  is_v6 "2001:db8::1"
  ! is_v6 "192.168.178.0/24"
  ! is_v6 "wt0"
}

@test "add_word deduplicates while preserving order" {
  [ "$(add_word "" "end0")" = "end0" ]
  [ "$(add_word "end0" "end0")" = "end0" ]
  [ "$(add_word "end0 eth0" "wlan0")" = "end0 eth0 wlan0" ]
  [ "$(add_word "end0 eth0" "end0")" = "end0 eth0" ]
}

@test "v4_words and v6_words split mixed subnet lists" {
  [ "$(v4_words "192.168.178.0/24 fd00::/64 10.0.0.0/8")" = " 192.168.178.0/24 10.0.0.0/8" ]
  [ "$(v6_words "192.168.178.0/24 fd00::/64 10.0.0.0/8")" = " fd00::/64" ]
  [ -z "$(v6_words "192.168.0.0/16")" ]
  [ -z "$(v4_words "fd00::/64")" ]
}
