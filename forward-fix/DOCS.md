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
Add-only is the default: with `prune_stale: false` (recommended to start),
rules are only ever inserted. Enable `prune_stale: true` to also delete
`DOCKER-USER` ACCEPT rules whose *both* interfaces belong to the managed
LAN/VPN sets but which are no longer desired (e.g. after narrowing subnets).
Pruning never runs against an empty desired set and never touches foreign
rules (Docker's own, other tools'). Deletions are logged with `pruned ...`.

## Health monitoring

`/data/status.json` example:
```json
{"timestamp":"2026-09-12T06:00:00Z","lan_interfaces":"end0 eth0 wlan0","vpn_interfaces":"wt0","docker_user_accept_rules":4,"healthy":"ON","packets_total":12345,"bytes_total":987654,"docker_user_accept_rules_v6":null,"packets_total_v6":null,"bytes_total_v6":null,"ipv6_enabled":false,"added_this_cycle":0,"pruned_this_cycle":0}
```
`packets_total` / `bytes_total` sum the live `DOCKER-USER` counters, so you can
watch throughput without parsing logs. A quiet log means steady state;
`added_this_cycle > 0` after Docker/VPN restarts is normal (chain was recreated).
`binary_sensor.forward_fix_healthy` mirrors rule presence for automations
(connectivity device class, diagnose-gated like the other entities).

Live per-rule counters via host SSH (port 22222), refreshing every 2 seconds:

```sh
watch -n 2 iptables -L DOCKER-USER -v -n
```

Append `-x` for exact (unrounded) numbers. If `watch` is unavailable:

```sh
while true; do clear; date; iptables -L DOCKER-USER -v -n; sleep 2; done
``` For one-shot forensics use
`diagnose: true` and read the add-on log.

## Viewing the increasing counters (defined)

`status.json` is rewritten every cycle with cumulative totals. Field reference:

| Field | Meaning |
|---|---|
| `timestamp` | UTC time of this snapshot — advances every cycle; if it stops advancing, the loop is stuck |
| `last_change` | UTC time the ruleset was last modified — frozen means stable (good); moves only when rules are added/pruned |
| `lan_interfaces` / `vpn_interfaces` | effective interface sets this cycle (config + auto-detect) |
| `docker_user_accept_rules` | current ACCEPT rule count in `DOCKER-USER` (18 = 3 LAN × 3 VPN × 2 directions) |
| `packets_total` / `bytes_total` | cumulative packets/bytes matched by **all** `DOCKER-USER` rules — these only ever increase while traffic flows |
| `*_v6` variants | same for `ip6tables` (`null` unless `enable_ipv6` is on) |
| `added_this_cycle` | rules inserted this cycle — `0` in steady state; `> 0` right after Docker/VPN restarts recreated the chain |

Watch it grow (host SSH, port 22222 — replace `<slug>` with your add-on slug,
e.g. `e2f7ca3e_forward_fix`):

```sh
watch -n 5 cat /mnt/data/supervisor/apps/data/<slug>/status.json
```

Pretty-printed, packets/bytes only:

```sh
cat /mnt/data/supervisor/apps/data/<slug>/status.json | python3 -m json.tool | grep -E 'timestamp|packets|bytes'
```

Rate over 60 seconds (delta ÷ time):

```sh
a=$(cat /mnt/data/supervisor/apps/data/<slug>/status.json); sleep 60; b=$(cat /mnt/data/supervisor/apps/data/<slug>/status.json); echo "$a" | grep -o '"packets_total":[0-9]*'; echo "$b" | grep -o '"packets_total":[0-9]*'
```

If `packets_total` never increases while you use the VPN, the traffic is not
passing this host — check the LAN router's static route first.

## UI counter entities (MQTT)

Home Assistant entities for the counters, shown only in diagnose mode:

1. Add-on **Configuration**: set `diagnose: true`, set `mqtt_host` to your
   broker (e.g. `core-mosquitto` if you run the Mosquitto add-on), adjust
   port/login if needed, Save (add-on restarts).
2. Entities appear automatically via MQTT discovery under device
   **Forward Fix**: `sensor.forward_fix_packets`, `sensor.forward_fix_bytes`
   (both `total_increasing`, so Lovelace graphs the increase),
   `sensor.forward_fix_rules`.
3. State updates every enforcement cycle to retained topic `forward-fix/stats`.
4. Set `diagnose: false` when done — the entities are removed automatically
   (retained discovery cleared). The password uses the `password` schema type
   (masked in UI); like all add-on options it is stored in Supervisor config.

No broker or empty `mqtt_host` = no entities; enforcement is unaffected.

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
- Pruned a rule you still need → it reappears next cycle as long as it matches
  the desired set; turn `prune_stale` off if anything looks wrong, then inspect.

## FAQ

**The UI still offers an update right after I updated via CLI / the Update
button fails with "No update available".**
Known Supervisor quirk, seen repeatedly: the backend is already correct
(`ha apps info` shows new version, `ha supervisor available-updates` is empty),
only the frontend badge is stale. Clear sequence: `ha store reload` →
`ha supervisor restart` (add-ons keep running) → browser hard-refresh
(`Ctrl + Shift + R`). Verify server-side first before assuming a real problem.

**Do pings started on HAOS itself move the counters?**
No — host-originated traffic uses `OUTPUT`, never `FORWARD`. Only traffic
forwarded *through* the host (LAN → VPN) is counted, outbound leg only
(replies take the established path). By design.
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
