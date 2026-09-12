# Forward Fix

Home Assistant add-on for **Home Assistant OS** that makes site-to-site VPNs
usable for LAN clients.

## Problem it solves

On HAOS, Docker sets `FORWARD policy DROP`. The host itself can use a VPN
tunnel (e.g. NetBird `wt0`), but packets forwarded from LAN clients
(`end0`/`eth0`/`wlan0` → `wt0`) are dropped because `DOCKER-USER` is empty and
`DOCKER-FORWARD` only allows `hassio`/`docker0`.

Symptom: `tracert <remote-subnet>` from a LAN PC reaches `192.168.178.4`
(HAOS) and then times out (`* * *`).

This add-on persists the fix across reboots and updates by re-applying
`DOCKER-USER ACCEPT` rules on boot and every N seconds.

Works with NetBird (`wt0`), Tailscale (`tailscale0`), WireGuard (`wg0`) —
interface lists are configurable, zero-config defaults cover the common case.

> Tested working with Home Assistant Core 2026.9.2 (HAOS 18.2,
> Supervisor 2026.09.0, Raspberry Pi 4, NetBird add-on v0.78.1).

## Installation

1. In Home Assistant: **Settings → Add-ons → Add-on Store → ⋯ → Repositories**,
   add:
   ```
   https://github.com/nicks-technik/ha-forward-fix
   ```
2. Find **Forward Fix**, Install, Start.
3. Keep defaults, or configure under **Configuration**:
   - `lan_interfaces` / `vpn_interfaces` (auto-detected interfaces are added automatically)
   - `lan_subnets` / `vpn_subnets` (optional CIDR scoping, e.g. `192.168.178.0/24`)
   - `auto_detect`, `enable_ipv6`, `diagnose`, `enforce_interval_seconds`
4. Verify (host SSH port 22222):
   ```sh
   iptables -L DOCKER-USER -v -n
   ip route show table 7120   # NetBird example
   ping -c 3 <remote-ip>
   ```
   From a LAN PC: `tracert <remote-ip>` should pass through HAOS.

## Health

Each cycle writes `/data/status.json` (add-on data) with timestamp, active
interfaces and rule counts; rules are only logged when something changes, so a
quiet log means "steady state". For one-shot diagnostics, enable `diagnose`,
restart, and read the add-on log (addresses, routes, chain state).

## Security notes

- Requires `host_network: true` + `NET_ADMIN` (needed to manage host firewall).
  No `full_access`, no host D-Bus, no API access.
- Only manages `DOCKER-USER` ACCEPT rules between the configured interface
  names. Interface names are validated (`[a-zA-Z0-9._-]`); no custom commands.
- It does **not** read VPN keys, it does **not** open ports to the internet.
  VPN authentication, routes, distribution groups and ACLs stay in your VPN
  dashboard (e.g. NetBird Networks/Routes/Policies).
- You still need, per VPN docs: advertised routes + masquerade as desired,
  approved routes / distribution groups, and a static route on your LAN router
  (e.g. FritzBox: `<remote-subnet> via <haos-lan-ip>`) unless the VPN router
  masquerades.

## Files

```
forward-fix/
  config.yaml  metadata, defaults, schema
  build.yaml   base images
  Dockerfile   iptables + jq, runs run.sh
  run.sh       validated enforcement loop
  DOCS.md      extended docs
  CHANGELOG.md releases
```

## License

MIT — see `LICENSE`.
