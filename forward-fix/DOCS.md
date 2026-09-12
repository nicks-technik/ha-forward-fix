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
2. For each `lan × vpn` pair (both directions), runs:
   `iptables -C DOCKER-USER -i <lan> -o <vpn> -j ACCEPT`
   and inserts the rule if missing.
3. Skips names that fail validation; logs every change.

`DOCKER-USER` is Docker's documented hook for custom forwarding: it is
evaluated before the restrictive `DOCKER-FORWARD` chain, and Docker recreates
it on daemon restarts — hence the loop instead of a one-shot script.

## Configuration reference

| Option | Type | Default | Notes |
|---|---|---|---|
| `lan_interfaces` | list(str) | `[end0, eth0, wlan0]` | Physical LAN interfaces on your board (RPi4 uses `end0` + `wlan0`; x86 often `eth0`). |
| `vpn_interfaces` | list(str) | `[wt0, tailscale0, wg0]` | Tunnel interfaces (`wt0` = NetBird). |
| `enforce_interval_seconds` | int 5–3600 | `30` | Re-apply cadence. Lower = faster repair, more wakeups. |

Invalid interface names are skipped and logged, never passed to iptables.

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
- After interface rename (new board): adjust `lan_interfaces`, restart add-on.

## Uninstall

Stop/uninstall the add-on, then on host SSH remove leftovers once:

```sh
iptables -D DOCKER-USER -i end0 -o wt0 -j ACCEPT 2>/dev/null
# repeat for your pairs, or flush only rules you added (never flush the chain blindly)
```
