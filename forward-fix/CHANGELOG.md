# Changelog

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
