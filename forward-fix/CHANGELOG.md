# Changelog

## 1.0.0

- Initial public release.
- Enforces `DOCKER-USER ACCEPT` between configurable `lan_interfaces` and
  `vpn_interfaces` (defaults cover `end0/eth0/wlan0` × `wt0/tailscale0/wg0`).
- Strict interface-name validation, interval configurable (5–3600s).
- Docs: README + DOCS, MIT license.
