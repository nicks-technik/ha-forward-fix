# Forward Fix — extended documentation

## When do you need this?

You run Home Assistant OS and a site-to-site VPN client (as an add-on with
`host_network: true`, e.g. NetBird):

- From the HAOS host itself, `ping <remote-lan-ip>` works.
- From a LAN PC, `tracert <remote-lan-ip>` reaches HAOS and then stalls.

That split proves the tunnel is fine but forwarded LAN traffic is dropped by
Docker's `FORWARD policy DROP`.

## What it does

Every `enforce_interval_seconds` (default 30):

1. Reads `/data/options.json` (Supervisor add-on options).
2. Merges configured interfaces with auto-detected ones (unless `auto_detect`
   is false): the default-route interface (excluding tunnels/docker/bridges)
   plus existing tunnel devices (`wt*`, `tailscale*`, `wg*`, `tun*`, `zt*`).
   Survives board swaps (`end0` → `eth0`) with no config change.
3. For each `lan × vpn` pair (both directions), ensures `DOCKER-USER ACCEPT`
   rules — interface-wide, or scoped with `-s`/`-d` when `lan_subnets` /
   `vpn_subnets` are set (cartesian per direction). Optionally mirrored to
   `ip6tables` when `enable_ipv6` is true.
4. Skips names/CIDRs that fail validation; logs every added rule, quiet otherwise.
5. Writes `/data/status.json` (timestamp, interfaces, rule counts).

`DOCKER-USER` is Docker's documented hook for custom forwarding: it is
evaluated before the restrictive `DOCKER-FORWARD` chain, and Docker recreates
it on daemon restarts — hence the loop instead of a one-shot script.

## Configuration reference

| Option | Type | Default | Notes |
|---|---|---|---|
| `lan_interfaces` | list(str) | `[end0, eth0, wlan0]` | Physical LAN interfaces (RPi4: `end0` + `wlan0`; x86: `eth0`). Merged with auto-detected default-route interface. |
| `vpn_interfaces` | list(str) | `[wt0, tailscale0, wg0]` | Tunnel interfaces (`wt0` = NetBird). Merged with detected tunnel devices. |
| `lan_subnets` | list(str) | `[]` | Optional CIDR scoping, e.g. `192.168.178.0/24`. Empty = interface-wide. IPv6 entries (with `:`) apply to ip6tables when `enable_ipv6` is on. |
| `vpn_subnets` | list(str) | `[]` | Optional remote CIDRs, e.g. `10.53.164.0/24`. Empty = interface-wide. |
| `auto_detect` | bool | `true` | Add default-route interface + existing tunnels automatically. |
| `enable_ipv6` | bool | `false` | Mirror rules to `ip6tables`. Opt-in. |
| `diagnose` | bool | `false` | Log addresses, routes, chain state once at startup. Turn on for troubleshooting, off after. |
| `enforce_interval_seconds` | int 5–3600 | `30` | Re-apply cadence. Lower = faster repair, more wakeups. |

Invalid interface names/CIDRs are skipped and logged, never passed to iptables.
Stale rules (e.g. after removing an interface from config) are intentionally
left alone — add-only is the safe default; restart/rebuild or delete them
manually, see Uninstall.

## Health monitoring

`/data/status.json` example:
```json
{"timestamp":"2026-09-12T06:00:00Z","lan_interfaces":"end0 eth0 wlan0","vpn_interfaces":"wt0","docker_user_accept_rules":4,"docker_user_accept_rules_v6":null,"ipv6_enabled":false,"added_this_cycle":0}
```
A quiet log means steady state; `added_this_cycle > 0` after Docker/VPN
restarts is normal (chain was recreated). For one-shot forensics use
`diagnose: true` and read the add-on log.

## Monthly maintenance

Dependabot watches Actions + Dockerfile; a monthly workflow opens a
`maintenance` reminder issue to check `ghcr.io/home-assistant/*-base` tags
against `build.yaml`, bump pins + `version`, add a CHANGELOG entry, rebuild
(`ha apps rebuild local_forward_fix` on test HAOS) and cut a release tag.
Auto-bumps are deliberately off — every base change on a firewall tool gets a
human look.

## Typical NetBird setup (example)

1. NetBird dashboard → Networks:
   - `192.168.178.0/24`, routing peer = HAOS peer, masquerade as desired.
   - `<remote-subnet>`, routing peer = remote router.
2. Approve/enable both routes; ensure HAOS peer is in the remote route's
   distribution group and vice versa; Policies allow the traffic.
3. FritzBox (or LAN router): static route `<remote-subnet> via <haos-ip>`
   unless the VPN router masquerades.
4. Install + start Forward Fix; verify as in README.

## Troubleshooting

- `iptables -L DOCKER-USER -v -n` empty → add-on not running; check add-on logs
  for `[forward-fix]` lines.
- Rules present but no packets → LAN router static route missing; test with a
  temporary host route on the PC pointing at HAOS.
- `wt0` missing → VPN add-on not connected; fix VPN first.
- New board / renamed interface: auto-detect covers it; check the log line
  `enforced ... lan=[...] vpn=[...]` to confirm. Set `auto_detect: false` only
  if you want strictly manual control.

## Uninstall

Stop/uninstall the add-on, then on host SSH remove leftovers once:

```sh
iptables -D DOCKER-USER -i end0 -o wt0 -j ACCEPT 2>/dev/null
# repeat for your pairs, or flush only rules you added (never flush the chain blindly)
```
