# Changelog

## 1.3.1

- Add-on info page "Visit page" link now works (`url` field).
- `last_change` timestamp in `status.json` (and MQTT state): stable-since
  visibility for the enforced ruleset.

## 1.3.0
- BATS unit tests for the validation helpers, run in CI.

- Health binary sensor: `binary_sensor.forward_fix_healthy` (connectivity
  device class, diagnose-gated) for alert automations; `healthy` also in
  `status.json`.
- Opt-in `prune_stale`: deletes managed-but-undesired `DOCKER-USER` rules
  (guarded: managed interfaces only, never empty set, deletions logged).
  Default off (add-only).
- CI lint workflow: ShellCheck, yamllint, hadolint on PRs.
- `auto_update: true` so store updates apply without clicks.
- Docs: FAQ (phantom update badge, host-originated traffic invisibility).

## 1.2.0

- UI counter entities via MQTT discovery (`sensor.forward_fix_packets`,
  `sensor.forward_fix_bytes` with `total_increasing`, `sensor.forward_fix_rules`),
  published only while `diagnose` mode is on; removed automatically when off.
- New options: `mqtt_host` / `mqtt_port` / `mqtt_username` / `mqtt_password`.

## 1.1.2

- Fix `added_this_cycle` in `status.json` (showed the packet total due to a
  clobbered positional parameter).
- Docs: defined guide for viewing increasing counters (field reference, watch
  commands, 60-second rate check).

## 1.1.1

- `status.json` now includes live `packets_total` / `bytes_total` (and `_v6`
  variants), summed from the `DOCKER-USER` counters — throughput visible
  without SSH.

## 1.1.0

- Auto-detect interfaces: default-route interface + existing tunnel devices
  (`wt*`, `tailscale*`, `wg*`, `tun*`, `zt*`) merged with configured lists.
- CIDR scoping: optional `lan_subnets` / `vpn_subnets` (`-s`/`-d`), empty =
  interface-wide as before.
- Health: `/data/status.json` every cycle, change-only logging.
- IPv6: opt-in `enable_ipv6` mirrors rules to `ip6tables`.
- Diagnose mode: one-shot addresses/routes/chain dump at startup.
- Maintenance: Dependabot + monthly reminder issue workflow.
- Store assets: `icon.png`, `logo.png`; UI translations for all options.

## 1.0.0

- Initial public release.
- Enforces `DOCKER-USER ACCEPT` between configurable `lan_interfaces` and
  `vpn_interfaces` (defaults cover `end0/eth0/wlan0` × `wt0/tailscale0/wg0`).
- Strict interface-name validation, interval configurable (5–3600s).
- Docs: README + DOCS, MIT license.
- Tested with Home Assistant Core 2026.9.2 (HAOS 18.2, Supervisor 2026.09.0,
  Raspberry Pi 4, NetBird add-on v0.78.1).
