# ndp64lab

An isolated fourteen-container OpenWrt 24.10.4 lab for one shared IPv6 /64
across eight separate LANs. The containers use eleven Docker bridge links:
ISP-to-WAN, ISP-to-public-website, ISP-to-DMZ, and one link per LAN. LAN1 has
two static clients; LAN2 through LAN8 have one each. A DHCPv4 roaming client
starts on LAN1. Docker's bridge-assigned addresses are replaced with the lab's
generated IPv4 fixtures. No host interface addresses are read.

## Requirements

Linux x86_64, Docker Engine and CLI 28 or newer with buildx, Bash, Git, and
permission to create privileged containers and bridge networks. The router image builds on the
digest-pinned OpenWrt x86/64 24.10.4 container image and installs `ip-full`
and the ucode socket module from OpenWrt's 24.10.4
package feed. Client builds also need the Debian, Alpine, and OpenWrt package
feeds, so the first build needs Internet access. The host kernel must provide the legacy `iptable_filter` and `ip6table_filter`
modules for firewall3; startup loads them when necessary using the privileged
Debian image and the host’s `/lib/modules`. Docker 28 or newer is
required for explicit interface naming with `com.docker.network.endpoint.ifname`.

## Lifecycle

From the repository root:

```sh
./lab up       # build and start
./lab test     # run acceptance checks against the live lab
./lab reset    # purge, rebuild, start, and test
./lab purge    # remove only ndp64lab resources and generated files
./lab exec router          # open an interactive /bin/sh in OpenWrt
./lab exec isp ip addr     # run a command with its arguments in the ISP
```

`exec` takes a container suffix (`router`, `isp`, `dmz`, `website`,
`client1` through `client8`, `client1b`, or `roaming`) followed by an optional command
and its arguments. Without a command, it opens an interactive shell, which
requires a terminal. Command arguments are passed directly to the container.
The lifecycle applets take no extra arguments. `up` reports an existing lab; use `reset`
to start over. The project name is fixed as `ndp64lab`, so moving or renaming
the checkout does not change Docker resource names. `purge` selects containers,
networks, and images by the `org.ndp64lab.owner=ndp64lab` label. The dedicated
`ndp64labbuilder` buildx instance is removed only when its ownership marker is
present under `.generated`. The generated directory is ignored by Git.

Set `BUILD_MIRROR` to an HTTP(S) mirror base URL when running `./lab up` or
`./lab reset` to select package mirrors under `/alpine`, `/debian`,
`/debian-security`, or `/openwrt`, according to each image's existing feeds.
The host checks repository metadata with curl using HTTP HEAD before changing a feed;
unavailable feeds retain their upstream URL. When unset, builds use upstream
repositories. Curl is required on the host when setting `BUILD_MIRROR`.
Container image pulls use Docker's registry configuration.

## Topology

The ISP connects OpenWrt, a public website, and a separate DMZ client.
The following naming table is the source of truth for generated addresses.
`./lab up` and `./lab test` extract only `address-seed:` rows within this
Topology section; the keys identify the customer/DMZ and public address pools.
Each value must be three ASCII letters, and the two values must differ.

| Address naming key | ASCII name | Used for |
| --- | --- | --- |
| `address-seed:customer` | `lab` | ISP identity, customer link, shared LAN IPv6 prefix, and DMZ |
| `address-seed:public` | `LAB` | Public website link |

_The `ASCII name`s are parsed as decimal ASCII codes, `lab` as 108, 97, 98, and
`LAB` as 76, 65, 66; they are used to compose the IPv4 or IPv6 prefixes; the
IPv6 prefix first part addtionally has `2` prepended to zero-padded, 3-digit
code so `108 -> 2108`, `76 -> 2076`_

The ISP has three separate links, and OpenWrt serves eight separate LANs.
With the names above, their addresses are:

| Link | Endpoint | IPv4 | IPv6 |
| --- | --- | --- | --- |
| Public | ISP | `76.65.66.1/30` | `2076:65:66::1/64` |
| Public | Website | `76.65.66.2/30` | `2076:65:66::2/64` |
| Customer | ISP | `108.97.98.100/31` | `2108:97:98:100::1/128` |
| Customer | OpenWrt WAN | `108.97.98.101/31` | `2108:97:98:100::2/128` |
| DMZ | ISP | `108.97.98.200/31` | `2108:97:98:200::1/128` |
| DMZ | DMZ client | `108.97.98.201/31` | `2108:97:98:200::2/64` |
| LAN1–LAN8 | OpenWrt LAN gateways | `192.168.n.1/24` | `2108:97:98:100::ff:n/64` plus link-local RA gateway |
| LAN1–LAN8 | Clients | `192.168.n.10/24`; LAN1 also has `192.168.1.11/24` | SLAAC addresses in `2108:97:98:100::/64`, shared with the customer link |

For the LAN rows, `n` is the LAN number, 1 through 8; each LAN has its own
`192.168.n.0/24` IPv4 subnet. Configuration and tests calculate the ISP link
addresses and shared IPv6 prefix from the naming table; the address table
shows examples for the current names.

Every Ethernet interface uses `02:42` followed by its four intended IPv4
octets in hexadecimal, independent of Docker's temporary address allocations.
For example, the router WAN `108.97.98.101` uses `02:42:6c:61:62:65`,
LAN1 gateway `192.168.1.1` uses `02:42:c0:a8:01:01`, and its client
`192.168.1.10` uses `02:42:c0:a8:01:0a`. This reproduces Docker's historical
IPv4-based formula explicitly and most importantly make both the MAC address
and IPv6 SLAAC addresses predictable; Docker >=28 otherwise generate random
MACs. The `02` byte marks a locally administered unicast address. Each ISP
link uses its own IPv4 address; the ISP loopback identity supplies no MAC.
All networks are attached at container creation with explicit MACs and
interface names: ISP WAN/public/DMZ are `eth0`/`eth1`/`eth2`, router WAN is
`eth0` and LAN1–LAN8 are `eth1`–`eth8`, and each peer uses `eth0`.

The website uses the ISP's `76.65.66.1` and `2076:65:66::1` as its return
gateways. OpenWrt uses `108.97.98.100` as its direct IPv4 gateway, and the DMZ
client uses `108.97.98.200`. The ISP keeps `108.97.98.1/32` as a separate
identity address; it is not a direct link gateway. No IPv4 proxy ARP is needed.

The eight LANs share `2108:97:98:100::/64` with the customer link, using the
current model of client `/128` routes and NDP proxying across WAN and LANs.
The customer and DMZ address pools, `108.97.98.0/24` and
`2108:97:98::/48`, are routed aggregates, not connected link masks; the links
use the masks shown in the address table.

### Client mix

Clients repeat this five-slot group in order. Debian boots systemd; Alpine uses
its default ifupdown-ng networking; the OpenWrt clients boot procd/netifd and
have only a LAN interface, with no WAN, DHCP server, NAT, or prefix delegation.

| Slot | Client OS | Network manager | Current containers |
| --- | --- | --- | --- |
| 1 | Debian Trixie | systemd-networkd | `client1`, `client6` |
| 2 | Debian Trixie | NetworkManager | `client2`, `client7` |
| 3 | Alpine 3.20 | ifupdown-ng | `client3`, `client8` |
| 4 | OpenWrt 21.02.7, firewall3 | netifd / odhcp6c | `client4`, `client1b` |
| 5 | OpenWrt 25.12.6, firewall4 | netifd / odhcp6c | `client5` |

25.12.6 is the latest stable OpenWrt image available when this mix was added;
there is no published OpenWrt 26 release. Both OpenWrt client images are pinned
by digest. Debian uses `debian:trixie-slim` and the Trixie package feeds.
The ISP, website, and DMZ retain the Alpine peer image. The nine existing client managers
configure static IPv4 fixtures, accept SLAAC and RA default routes,
and disable temporary IPv6 addresses. Debian explicitly uses EUI-64 addresses.
OpenWrt's `lan6` is an IPv6 protocol interface on the same LAN Ethernet device;
it requests neither DHCPv6 addresses nor delegated prefixes. Its LAN firewall
accepts local traffic while rejecting forwarding.

Generated manager configuration is under `.generated/clients/`. Tests verify
the assigned manager and OpenWrt firewall in addition to connectivity. Existing
deployments need `./lab reset`; `./lab test` rejects an old client mix.

The additional `roaming` client uses Debian Trixie and systemd-networkd with
DHCPv4 and EUI-64 SLAAC. Its fixed MAC is derived from the seed `192.168.0.12`
(`02:42:c0:a8:00:0c`); this seed is not an assigned IPv4 address. Each router
LAN runs dnsmasq DHCPv4 with a `.100`–`.199` pool and five-minute leases,
outside the static clients' `.10` and `.11` addresses. DHCPv6 stays disabled.

### Routing Behavior

The WAN and ISP links use the generated addresses shown above. OpenWrt's
IPv6 default route uses the actual link-local address read from the ISP's
customer-facing `eth0` during setup. No extra link-local address is assigned. Its
`eth1` through `eth8` have `192.168.1.1/24` through `192.168.8.1/24`.
Clients use `.10` on their LAN; the second LAN1 client uses `192.168.1.11/24`.
Each client uses its LAN router address as the IPv4 default gateway. OpenWrt
masquerades outbound IPv4 traffic. All clients receive the generated shared
customer `/64` as an on-link, autonomous prefix via Router Advertisements
from odhcpd. DHCPv6 is disabled on each LAN, and clients do not generate
temporary IPv6 addresses. The ISP forwards between its three links; the DMZ
and website use it as their default gateway.

The customer and DMZ links model **bad ISP behaviour**: the ISP is
"providing" a `/64` yet takes `::1/128` for itself, and therefore expects
Neighbor Solicitations (NS) from the client to add that client to its route
and neighbor tables. It starts with no connected route for either offered
`/64` and no client routes or neighbors. An NS addressed to the ISP's `::1`,
with a source in that link's `/64` and a source link-layer address option,
registers an on-link `/128` route and the client's MAC in the neighbor table.
Ordinary IPv6 traffic, Neighbor Advertisements, and DAD probes do not register
clients. Addresses that have not registered remain unreachable from the ISP.
The public website link keeps normal connected `/64` routing.

The DMZ client registers through normal gateway NS. OpenWrt explicitly sends
an NS from each learned LAN client's IPv6 address to the ISP's customer `::1`,
using its WAN MAC, because forwarding a client's traffic does not generate
an NS with that client's source address. It also registers its own WAN address.
Return traffic uses the learned neighbor entry and OpenWrt's client `/128`
routes; subsequent NDP is answered by OpenWrt's proxy. The ISP learners log to
`/tmp/isp-learning-eth0.log` and `/tmp/isp-learning-eth2.log` inside the ISP
container. Existing deployments need `./lab reset` to apply this behavior.

OpenWrt's firewall keeps the normal LAN-to-WAN forwarding, WAN rejection, and
ICMPv6 forwarding behavior. odhcpd sends RAs, learns client `/128` routes
from confirmed kernel neighbors,
and handles NDP relay across WAN and all LANs. LAN sections use `ra=server`,
`ndp=relay`, and route learning; WAN is the relay master with RA and route
learning disabled. Same-LAN client addresses are never proxied on their own
LAN, so peer traffic stays on the Docker bridge.

Each LAN has a distinct shared-prefix `::ff:1/64` through `::ff:8/64` address,
provided to odhcpd through netifd. The router uses the official odhcpd binary
packaged in the pinned OpenWrt image, without local patches or rebuilding.
Its minimum supported PIO caps are 60 seconds, so preferred and valid lifetimes
are both capped at 60 seconds. RAs repeat every 5–10 seconds with a 30-second
router lifetime. All ten LAN clients retain their SLAAC addresses through
continued RAs; the DMZ keeps its static address.

UCI specifies the link-local default gateway, a direct `/128` route to the
ISP's global address, and an unreachable shared `/64` route with metric 1.
Unknown shared-prefix destinations are rejected. The router has no Go binary.
Its procd service runs `router/register.uc`, which discovers participating
LANs from DHCP UCI and devices from netifd. IPv6 sources and DAD targets are
candidates for interface-bound kernel probes. Confirmed kernel neighbors and
the router's own shared-prefix addresses are registered using raw ICMPv6 NS
sockets, nonlocal binding, the WAN MAC, and kernel-generated checksums.
Startup reconciles existing neighbors, new addresses register immediately,
successful sends refresh every five seconds, and failures retry after three.
Removed addresses stop refreshing; network and DHCP changes reload the service.
When a confirmed neighbor's MAC appears on another LAN, the helper immediately
retires its old kernel neighbor entry. odhcpd then removes stale proxies before
they can falsely answer the moving client's DAD. Interface-bound probes confirm
the new location; odhcpd continues to own routes and proxies. Failed and
incomplete relay probes are not previous client locations. The helper leaves
them alone. Stock odhcpd reconciles routes and proxies after neighbor removal;
connectivity checks allow up to ten seconds for NDP and reconciliation.
Acceptance checks explicitly remove failed relay probes and require recovery
of client2-to-client5 traffic without restarting services.

The separately built ISP-only `/usr/sbin/isp-ndp-learn` receives and validates
NS packets. Both subscriber learners are supervised inside the ISP container,
with prefixes, target addresses, interfaces, and a 15-second timeout in its own
supervisor configuration. Every source, including router `::2`, follows the
same registration rule. Only a qualifying NS refreshes the monotonic deadline;
data, NA, and DAD cannot extend it. A one-second sweep deletes expired routes
and neighbors. Protocol 99 marks learner-owned routes for restart cleanup.
Subscriber neighbor timers use 5-second reachability and stale GC intervals,
with 1-second delay and retransmission intervals. Deadline expiry actually
deletes registrations; a STALE neighbor alone remains usable. The DMZ uses
the same short timers. Its native configuration disables automatic link-local
address generation, retaining the selected static global address. Linux then
uses that address for unicast NUD gateway NS as well as initial resolution,
so active traffic can renew the registration naturally.

Native manager configuration is generated on the host and copied into stopped
containers before boot. Deployment manifests stay on the host for validation;
website content is mounted. OpenWrt containers mask `/proc/kmsg` with
`/dev/null` so competing readers of the shared host kernel log cannot block
logd and DHCP replies. There is no interface remapping or host-driven
peer address configuration. Existing source checkouts remain under `~/Building/ndp64lab-sources`; the
router build uses the official packaged daemon.

### Expected Traffic

Acceptance checks cover:

- Clients on different LANs can communicate over IPv4 and IPv6.
- Lab clients and the DMZ client can access the public website over both
  IPv4 and IPv6. Each deployment generates a fresh 4096-byte random printable
  ASCII file,
  served unchanged for the lifetime of that deployment. HTTP responses use
  `text/plain`; tests require successful responses with bodies identical to
  `.generated/www/index.html` over both protocols. Repeated requests and
  `./lab test` preserve the payload; `./lab reset` generates a new one.
- Lab clients and the DMZ client can ping each other over IPv6.
- New inbound TCP connections to lab clients remain blocked by OpenWrt's
  firewall. Inbound IPv4 access to lab clients is not promised.

The address generator, MAC vectors and uniqueness, and payload creation can
also be checked without Docker:

```sh
bash tests/address-generation.sh
bash tests/client-configuration.sh
GO111MODULE=off go test ./isp  # NS validation, deadline refresh/expiry and restart cleanup
```

After changing a naming seed, run `./lab reset` to deploy the new addresses;
`./lab test` rejects seeds that differ from the running deployment's manifest.

Existing deployments need `./lab reset` to apply the MAC formula; client SLAAC
addresses may change. `test` checks all 24 interface MACs against their
address seeds and reports mismatches with reset instructions.

`test` checks that each client has one global SLAAC address, IPv4 and IPv6
traffic between every pair of LANs, outbound IPv4 to the ISP, IPv6 in both
directions with the ISP and DMZ, HTTP payload integrity over both protocols
from every lab client and the DMZ, upstream NDP, blocked new inbound TCP, and
direct LAN1 peer routing and MAC resolution. It also checks that unknown addresses in the
shared prefix are unreachable from both OpenWrt and the ISP, that the ISP
customer and DMZ addresses use `/128`, and that each active client has a
learned ISP `/128` route and neighbor entry. Deployment checks that the ISP
starts without client routes on either link.
A temporary DMZ source verifies that ordinary traffic cannot register a client
and that a subsequent gateway NS installs both its route and neighbor entry.
A temporary nftables counter checks that LAN1
peer traffic does not enter OpenWrt's forwarding path.

When diagnosing a failed run, `./lab exec router logread` shows
OpenWrt and helper logs. `./lab purge` also works after a partial `up`.

The acceptance suite also stops only the router registration service while
odhcpd and native client managers continue. During ongoing client traffic, ISP
registrations expire naturally while the same valid SLAAC addresses and LAN
connectivity remain. Restarting registration must restore upstream connectivity
without restarting client networking. A trap restores the service on failure.

The roaming acceptance test visits LAN1 through LAN8 twice. It moves the same
host veth between the lab bridges with a brief carrier interruption, preserving
the client interface and MAC. Docker's endpoint metadata remains on LAN1; an
exit trap returns the veth there. At every visit the test requires a DHCPv4
lease and gateway for that LAN, the same SLAAC address, correct learned routing,
HTTP integrity over both protocols, and direct IPv6 access to the local static
client. One IPv6 TCP connection to the ISP exchanges checked bidirectional
payloads throughout both loops. Brief handoff stalls are allowed; the connection
must stay open and resume transferring, with no reconnect path. Existing static
clients are checked again afterward.
