# Tunnel Manager

A single interactive panel for running reverse tunnels between two Linux servers — commonly an "IRAN" server (the side users actually connect to) and a "KHAREJ" server (where the real backend lives, reached through the tunnel). One `curl | bash` install gets you a menu-driven tool that can install, configure, diagnose, benchmark, back up, watch over, and remove tunnels across six different tunnel engines, without needing to hand-edit a single config file.

This isn't a wrapper around one tool. Each engine is a self-contained module (`core/<name>/core.sh`) that speaks that engine's real config format and follows that engine's own design — see [`core/README.md`](core/README.md) if you're extending it.

## Contents

- [Supported tunnel engines](#supported-tunnel-engines)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Menu reference](#menu-reference)
- [Choosing an engine](#choosing-an-engine)
- [Advanced usage](#advanced-usage)
- [Security](#security)
- [Backups](#backups)
- [Health monitoring](#health-monitoring)
- [Tunnel Health engine](#tunnel-health-engine)
- [Smart Auto-MTU for TUN/IPX](#smart-auto-mtu-for-tunipx)
- [Network optimization](#network-optimization)
- [Migrating to a new VPS](#migrating-to-a-new-vps)
- [Troubleshooting](#troubleshooting)
- [FAQ](#faq)
- [Developing / adding a new engine](#developing--adding-a-new-engine)
- [Roadmap](#roadmap)

## Supported tunnel engines

| Engine | Protocol | Best for | Guide |
|---|---|---|---|
| **Backhaul** | TCP (+ TUN/IPX helper modes) | The default choice — highest raw throughput, most mature in this panel, most configuration depth (port ranges, IPX encapsulation, kernel tuning, forwarder engines) | [docs/backhaul.md](docs/backhaul.md) |
| **Rathole** | TCP | A simpler, Rust-based alternative to Backhaul — smaller surface area, fast to reason about | [docs/rathole.md](docs/rathole.md) |
| **GOST** | TCP/UDP, chainable | Not a simple A↔B tunnel — a general proxy/forwarding toolkit with protocol chaining, useful when you need something Backhaul/Rathole can't express | [docs/gost.md](docs/gost.md) |
| **Hysteria2** | QUIC (UDP) | Links with active DPI, throttling, or heavy packet loss — congestion control tuned for exactly that | [docs/hysteria2.md](docs/hysteria2.md) |
| **FRP** | TCP | The most widely deployed reverse-proxy tunnel in the ecosystem — huge community, very stable | [docs/frp.md](docs/frp.md) |
| **TUIC** | QUIC (UDP) | Same niche as Hysteria2, lighter weight — worth trying if Hysteria2 underperforms on a specific link | [docs/tuic.md](docs/tuic.md) |

If you're not sure which to pick: start with **Backhaul** (the default, most-featured path). Move to **Hysteria2** or **TUIC** specifically if your link is filtered/throttled and TCP-based tunnels get degraded. See [Choosing an engine](#choosing-an-engine) below for the full comparison.

## Installation

Run as root on **both** servers (the one users connect to, and the one with the real backend):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dr-hoseyn/tunnel-manager/main/install.sh)
```

This installs to `/opt/tunnel-manager`, downloads the Backhaul core binary with SHA256 verification, and creates two equivalent launcher commands: `backhaul` and `tunnel-manager`. Either one opens the panel:

```bash
backhaul
# or
tunnel-manager
```

Other engines (Rathole, GOST, Hysteria2, FRP, TUIC) download their own binaries on first use, from their own upstream GitHub releases, the first time you open that engine's menu.

## Quick start

The most common setup: expose a service that lives on your KHAREJ server, through your IRAN server, using Backhaul.

**On IRAN (the server end users connect to):**
1. Run `backhaul`, choose **1) Configure a new tunnel**, then **1) Configure IRAN (Server)**.
2. Accept the suggested transport, bind port, and token (or set your own) — every prompt shows a smart default; press Enter to accept it.
3. Enter the ports you want forwarded (e.g. `443` or `443,8080=9090`).

**On KHAREJ (where the real backend runs):**
1. Run `backhaul`, choose **1) Configure a new tunnel**, then **2) Configure KHAREJ (Client)**.
2. Enter IRAN's address (`IP:Port`) — matches what you set as the bind port above.
3. Use the same token you set on IRAN.

The panel runs diagnostics automatically right after each side is configured, and both sides register a systemd service (`backhaul-iranPORT.service` / `backhaul-kharejPORT.service`) with a watchdog timer that restarts it if it ever goes down.

## Menu reference

```
1. Configure a new tunnel        \
2. Tunnel management              } Backhaul — the default engine, wired
3. Check tunnel status            / directly at the top level (no submenu)
──────────────────────────────────
4. Rathole
5. GOST Manager
6. Hysteria2 (QUIC, DPI/throttling resistant)
7. FRP
8. TUIC (QUIC, lightweight alternative)
──────────────────────────────────
9. Dashboard (live CPU/RAM/network + tunnel status)
10. Security & Maintenance (TLS cert, Fail2Ban)
11. Optimize Network (BBR, buffers, conntrack, port reservation)
──────────────────────────────────
12. Update Backhaul Core
13. Update script
14. Remove Backhaul Core
15. Uninstall everything
0. Exit
```

Every other engine (4–8) opens its own submenu with the same shape: **Configure a new tunnel**, **Tunnel management** (edit/diagnose/benchmark/logs/restart/remove any existing tunnel), **Check tunnel status**, plus an **Update core** action.

## Choosing an engine

| | Backhaul | Rathole | GOST | Hysteria2 | FRP | TUIC |
|---|---|---|---|---|---|---|
| Transport | TCP / TUN+IPX | TCP | TCP/UDP | QUIC | TCP | QUIC |
| Obfuscation against DPI | Partial (anytls/wss) | No | Via chaining | Yes (Salamander) | No | QUIC profile only |
| Config depth in this panel | Highest | Low | Highest (chains) | Medium | Medium | Medium |
| Maturity / ecosystem size | High | Medium | High | High | Very high | Medium |
| Good on lossy/throttled links | Depends on transport | No | Depends on chain | Yes | No | Yes |
| Raw throughput ceiling | Highest | High | High | Good | High | Good |

Rules of thumb:
- **Clean, unfiltered link, want the most control** → Backhaul.
- **Want the simplest possible TCP tunnel** → Rathole.
- **Need to chain multiple protocols/hops, or do something Backhaul/Rathole's models don't fit** → GOST.
- **Link is actively throttled or DPI'd, TCP tunnels keep degrading** → Hysteria2, then TUIC if Hysteria2 underperforms.
- **Want the tool with the largest community/most third-party tooling around it** → FRP.

Each engine's guide (linked in the table above) covers protocol tradeoffs, security model, and concrete recommended configurations in depth.

## Advanced usage

**Editing a tunnel** (any engine, via that engine's *Tunnel management*): every field is prefilled with its current value, not a generic default — pressing Enter keeps it unchanged. Backhaul edits and every GOST fragment change are transactional and roll back when the service fails its health check; every engine refuses to report success unless its service is actually active.

**Diagnostics**: checks the local service, pings the peer (if its IP is set), checks the peer's SSH port, and does a final end-to-end reachability check on the first forwarded port.

**Benchmark**: TCP and ICMP probes against the peer, with a real-throughput number if `iperf3 -s` happens to be running there.

**Smart defaults**: every prompt that has a sensible default shows it — last-used values (transport, remote address, peer IP), detected values (public IPv4/IPv6, network interface, free ports), or computed recommendations (a free port that doesn't collide with another tunnel *or* an already-listening process on the system). IPX uses the IPv4 source selected by the kernel's default route, verifies that it is actually assigned to the chosen interface, and therefore does not silently select a slow secondary address on multi-IP servers.

## Security

- Every engine download is fail-closed on SHA-256 verification. TUIC uses GitHub's release-asset digest when an upstream checksum file is absent; Backhaul and panel updates are pinned to one immutable repository commit.
- TLS: the shared self-signed certificate (`/root/backhaul-core/cert_files/`) has a DNS SAN and a long lifetime to avoid needless trust rotation. Hysteria2 clients require its exact SHA-256 pin; TUIC clients require a securely copied certificate and keep `skip_cert_verify = false`. Manual renewal warns that peer trust must be updated.
- **Security & Maintenance → Enable Fail2Ban SSH protection** sets up a standard sshd jail (5 failed attempts in 10 minutes → 1 hour ban). Off by default — it changes system-wide SSH ban behavior, so it's an explicit action, not something the installer does silently.
- Firewall rules are tagged and tracked per tunnel for UFW/iptables, updated on edits, and removed only when their owning tunnel is removed.

## Backups

Backhaul editing snapshots the config + systemd unit under `/root/backhaul-core/.backups/`. GOST snapshots `services.d`, `chains.d`, metadata, and the combined config as one transaction. Network Optimize keeps its own exact runtime/file baseline for rollback. These are safety nets, not portable exports.

## Health monitoring

A systemd timer (`backhaul-watchdog.timer`) runs every 30 seconds and restarts an inactive tunnel only when its unit is enabled. For TUN/IPX it restarts a live-looking but unusable service only after three consecutive full path failures, avoiding reconnect loops caused by one delayed probe. The heavier Tunnel Health/Smart Auto-MTU sample remains limited to once every five minutes. A deliberately disabled tunnel stays disabled. It also checks the shared TLS certificate and restarts only enabled dependents when replacement is genuinely required.

## Tunnel Health engine

Every enabled Backhaul TUN/IPX tunnel receives a bounded health sample during the five-minute watchdog cycle. The engine correlates small and near-MTU control probes with TUN/physical-interface counters, qdisc drops, service traffic/CPU/memory/restarts, normalized system load, and conntrack utilization. Linux exposes the interface counters through `ip`/sysfs and driver statistics through `ethtool`; see the [kernel interface-statistics guide](https://docs.kernel.org/networking/statistics.html).

The classifier reports one conservative cause with a confidence score: `healthy`, `mtu-suspected`, `network-congestion`, `physical-interface-drops`, `tunnel-interface-drops`, `cpu-saturation`, `memory-pressure`, `conntrack-pressure`, `service-restarting`, `service-failure`, `tunnel-interface-down`, `tunnel-path-failure`, or `peer-or-underlay-unreachable`. Missing underlay ICMP is never treated as definitive proof that the peer is down.

Open **Tunnel management > Tunnel Health** to collect a fresh sample, inspect all current metrics, or view recent history. Per-tunnel state lives under `/root/backhaul-core/.health/`; history is capped at 288 samples (24 hours at the default interval). Smart Auto-MTU requires a sample no older than two minutes, fails closed on stale telemetry, and proceeds only when the current classification is `healthy` or `mtu-suspected`, preventing CPU, congestion, conntrack, service, and interface faults from being misdiagnosed as MTU problems.

## Smart Auto-MTU for TUN/IPX

Backhaul TUN/IPX tunnels can opt into a bounded adaptive MTU controller. New IPX configurations are prompted for an initial MTU, minimum, maximum, and step; existing tunnels stay disabled until enabled from **Tunnel management > Smart Auto-MTU** or a full edit.

The controller follows a conservative probe/confirm/rollback state machine inspired by [RFC 8899 DPLPMTUD](https://www.rfc-editor.org/rfc/rfc8899.html):

- A small control probe must first show that the tunnel and general network are healthy. If small packets also fail, MTU is not blamed and nothing is changed.
- Lowering requires two consecutive size-specific failure samples; raising requires three consecutive healthy samples.
- A candidate is tested against the current MTU as an A/B probe. It is accepted only when delivery score improves and the small control path remains healthy; otherwise the exact config is restored and the service restarted on its previous MTU.
- Smart Auto-MTU is disabled by default. In watchdog mode, high traffic clears accumulated evidence and pauses automatic changes; a deliberate manual one-shot evaluation can still run during high traffic. Missing traffic accounting, high system load, a service uptime below ten minutes, or cooldown also pauses changes.
- Defaults are `1200-1420` with a `20` byte step. Hard safety limits are `1000-1500`. An accepted or rejected candidate changes at most one step per evaluation; a rejected upward probe closes upward exploration until learning is manually reset.

State is stored per tunnel under `/root/backhaul-core/.auto-mtu/`. The tunnel detail page shows the latest baseline, skip reason, accepted/rejected decision, and provides a safe one-shot evaluation, enable/disable control, bound editing, and learning reset.

## Network optimization

**Optimize Network** (menu item 11) tunes the underlying OS/kernel network stack — this is independent of, and complementary to, each engine's own tuning options (e.g. Backhaul's `so_rcvbuf`/`so_sndbuf`/`mss`/mux settings). It applies:

- Socket buffers, backlog, and conntrack capacity sized in three RAM profiles for sustained 800 Mbps-1 Gbps paths (including roughly 100 ms international RTT); an administrator's already-higher values are never reduced.
- BBR + `fq` as the default qdisc when supported. Existing `fq` queues receive a persisted high-throughput profile: single-queue NICs use the tested large aggregate limits, while multi-queue NICs receive smaller per-queue limits. Custom and non-`fq` qdiscs are never replaced.
- Existing `ip_local_reserved_ports` are merged with every detected TCP/UDP listener instead of overwritten.
- A safer ephemeral range and conservative keepalive/MTU-probing settings. Riskier global `tcp_fastopen`, conntrack timeout/hashsize, PAM limits, and systemd-wide limits are left alone.

Optimization is synchronized automatically before and after every successful tunnel create/edit. The pre-start pass makes new sockets inherit the selected congestion control; the post-start pass adds the newly listening ports to the reservation list. Menu item 11 remains available for status, a manual retry/re-apply, and rollback.

The first apply records every touched sysctl value, the active `fq` queue parameters, and the exact prior contents/existence of managed files in `/root/backhaul-core/.network-tune-state/`. Re-applying never overwrites that baseline and rebuilds reserved ports from the baseline plus current listeners, so removed tunnel ports do not accumulate. **Roll back** restores those values, queue parameters, and manager-owned files, but refuses to overwrite a file that an administrator changed after optimization; shared `limits.conf` is never replaced wholesale. A partial rollback keeps its state for a safe retry. Successful rollback archives the snapshot under `.backups`; uninstall also invokes rollback.

## Migrating to a new VPS

There's no one-click export yet (see [Roadmap](#roadmap)). Today, moving a working tunnel to a new server means copying the relevant files by hand:

- Config: the engine's own file under `/root/backhaul-core/` (Backhaul: `iranPORT.toml` at the root; other engines: `<engine>/iranPORT.toml` or `.yaml`).
- The engine's own binary, if you'd rather not re-download it.
- `/root/backhaul-core/cert_files/` if the tunnel uses TLS.
- `/root/backhaul-core/.meta/<config_name>.meta` for the peer IP/SSH port diagnostics remember.
- `/root/backhaul-core/.auto-mtu/` if you want to preserve learned TUN/IPX MTU bounds/history (optional; settings can be recreated from Edit).
- `/root/backhaul-core/.health/` if you want to preserve the latest TUN/IPX diagnosis and its bounded 24-hour history (optional).

Then re-run that engine's **Edit** flow once on the new server so the systemd service gets (re)created correctly, rather than hand-writing the unit file.

## Troubleshooting

**A tunnel won't connect after configuring it.**
1. Check the service is actually active: that engine's *Tunnel management* → pick the tunnel → **View service status** / **View service logs**.
2. Re-run **Retest (Diagnostics)** on the tunnel — it'll tell you specifically which side isn't ready (local service down, peer unreachable, or forwarded port not answering yet).
3. Confirm both sides used the *same* shared secret (token/password/UUID depending on engine) and the same port.
4. For QUIC-based engines (Hysteria2, TUIC): confirm the port is actually open for **UDP**, not just TCP — a firewall or provider that only opens TCP will silently break these.

**"Remove Backhaul Core" or "Update Backhaul Core" seems to affect the wrong thing.** These only ever touch the `backhaul_premium` binary — they don't remove your tunnels or any other engine's data. If you're removing everything, use **Uninstall everything** instead.

**A cert-related error after certificate renewal.** Update the Hysteria2 SHA-256 pin on IRAN, or copy the new KHAREJ certificate to the path trusted by TUIC on IRAN, then restart both tunnel services. The panel warns before manual rotation because remote trust cannot be updated automatically.

## FAQ

**Do I need to run the installer on both servers?**
Yes — each server runs its own independent copy of the panel and manages its own tunnels. There's no central coordinator (see [Roadmap](#roadmap) for multi-server management).

**Can I run multiple engines at once?**
Yes. Each engine uses its own port range/config directory/systemd service naming, so a Backhaul tunnel and a Hysteria2 tunnel can run side by side without conflicting — the panel checks for port collisions across the whole system (not just its own configs) when suggesting a port.

**What happens if I lose SSH access after enabling Fail2Ban?**
The default jail is 5 failed attempts in 10 minutes before an hour-long ban, scoped to failed SSH logins — a legitimate session with the right key/password is never affected. If you do get banned from your own IP, wait it out or access the server through your provider's console and run `fail2ban-client unban <your-ip>`.

**Where does everything live on disk?**
`/root/backhaul-core/` for all config/certs/backups/metadata, `/opt/tunnel-manager/` for the panel code itself. `/root/backhaul-core` is a legacy name from before the panel supported multiple engines — it's shared by all of them now.

## Developing / adding a new engine

See [`core/README.md`](core/README.md) for the plugin interface every engine implements, the common internal shape to follow, and a step-by-step checklist. In short: one new `core/<name>/core.sh`, four wiring points in `tunnel-manager.sh` (source it, watchdog loop, uninstall, menu entry) — `install.sh` needs no changes since it copies `core/` recursively.

When changing shared code (`lib/common.sh`, or anything in `core/backhaul/core.sh` that other engines depend on), run the full test pass before pushing: `bash -n` and `shellcheck -s bash` on every changed file, plus re-running each engine's own test coverage if one exists for the area you touched.

## Roadmap

Not yet implemented, in rough priority order:
- One-click config export/import for VPS migration (today this is a manual file-copy, see above)
- Multi-server management from a single interface (each install is currently fully independent)
- Searchable audit log (who changed what, when, old value → new value)
- Rate limiting on forwarded ports
