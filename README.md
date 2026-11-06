# ndp64lab

Two simultaneous OpenWrt subscribers, **25.12.6** and **21.02.7**, each share
one IPv6 /64 across three isolated LANs. Seventeen containers use ten Docker
bridge networks: four ISP links and three LAN links per subscriber. Each
subscriber has five static clients and a DHCPv4 roaming client. The ISP,
public website and DMZ are shared. All links are internal Docker bridges;
no host interface addresses are read.

## Requirements

Linux x86_64, Docker Engine and CLI 28 or newer with buildx, Bash, Python 3,
Git, and permission to create privileged containers and bridge networks.
Docker's explicit endpoint interface naming requires version 28 or newer.
The host kernel must supply xtables routing, filtering, connection tracking
and NAT modules for firewall3. Startup loads these through the privileged
Debian image using the host's `/lib/modules`.

OpenWrt bases are pinned by digest. Packages come from each release's official
feeds: apk on 25 and opkg on 21. Each release installs Bash, socat, tcpdump,
ip-full, ping and curl once in its router image. The thin LAN-only client
stage derives from that router stage, sharing every downloaded and installed
package layer. BuildKit caches package downloads. Debian and Alpine clients
also use their distribution feeds. Initial builds require Internet access.

## Lifecycle

```sh
./lab up       # build and start
./lab test     # acceptance checks against the running lab
./lab reset    # purge, rebuild, start, and test
./lab purge    # remove lab resources and generated files
./lab exec router25
./lab exec router21 ip -6 route
./lab exec client25-networkd ip addr
./lab exec roaming21 networkctl status eth0
./lab exec isp ip -6 route
```

`exec` accepts `isp`, `website`, `dmz`, `router25`, `router21`, `roaming25`,
`roaming21`, and `client{25,21}-{networkd,nm,alpine,fw4,fw3}`. With no command,
it opens an interactive `/bin/sh` and requires a terminal. Arguments are
passed directly to the container. Lifecycle applets accept no arguments.

The fixed resource prefix is `ndp64lab`. Ownership is recorded with the
`org.ndp64lab.owner=ndp64lab` label; purge selects only owned resources.
The dedicated `ndp64labbuilder` builder is removed only when its ownership
marker is present in `.generated`. Reset preserves that builder and its cache
to reuse downloads; purge removes it. That directory is ignored by Git.
An existing deployment with the old topology or changed address seeds is
rejected with instructions to run `./lab reset`.

Set `BUILD_MIRROR` to an HTTP(S) mirror base URL for `up` or `reset` to select
package feeds under `/alpine`, `/debian`, `/debian-security` and `/openwrt`.
The host checks repository metadata with curl before rewriting each feed.
Unavailable mirror feeds retain their upstream URL. Unset means upstream;
image pulls use Docker's registry configuration. Curl is required on the host
when selecting a mirror.

## Topology

This naming table is the source of truth for generated addresses. Only
`address-seed:` rows inside this section are parsed. Values must be distinct
three-letter ASCII names.

| Address naming key | ASCII name | Used for |
| --- | --- | --- |
| `address-seed:customer` | `lab` | ISP identity, subscriber links, shared IPv6 prefixes and DMZ |
| `address-seed:public` | `LAB` | Public website link |

Letters become decimal ASCII codes: `lab` gives 108, 97, 98; `LAB` gives
76, 65, 66. IPv4 uses those three octets. IPv6 prepends `2` to the first
zero-padded three-digit code, giving `2108:97:98` and `2076:65:66`.
The ISP also owns loopback IPv4 identity `108.97.98.1/32`.

| ISP interface | Link / Docker suffix | ISP IPv4 | Peer IPv4 | IPv6 prefix |
| --- | --- | --- | --- | --- |
| `eth0` | Website / `public` | `76.65.66.1/30` | `76.65.66.2/30` | `2076:65:66::/64` |
| `eth1` | OpenWrt 25 / `wan25` | `108.97.98.100/31` | `108.97.98.101/31` | `2108:97:98:100::/64` |
| `eth2` | OpenWrt 21 / `wan21` | `108.97.98.150/31` | `108.97.98.151/31` | `2108:97:98:150::/64` |
| `eth3` | DMZ / `dmz` | `108.97.98.200/31` | `108.97.98.201/31` | `2108:97:98:200::/64` |

On subscriber links the ISP has `::1/128` and the router has `::2/128`.
The DMZ ISP endpoint also has `::1/128`; the DMZ client has `::2/64`.
The public endpoints use `::1/64` and `::2/64` respectively.
The ISP runs one independent NS learner per subscriber and one for the DMZ.
Learner logs are `/tmp/isp-learning-eth{1,2,3}.log` in the ISP container.

Each subscriber uses the following identical layout. Docker LAN suffixes
are `25-1` through `25-3` and `21-1` through `21-3`.

| LAN | Router interface | IPv4 subnet and gateway | Static clients |
| --- | --- | --- | --- |
| LAN1 | `eth1` | `192.168.1.0/24`, `.1` | Debian systemd-networkd `.10`; Debian NetworkManager `.11` |
| LAN2 | `eth2` | `192.168.2.0/24`, `.1` | Alpine ifupdown-ng `.10` |
| LAN3 | `eth3` | `192.168.3.0/24`, `.1` | OpenWrt 25 firewall4 `.10`; OpenWrt 21 firewall3 `.11` |

Router WAN is `eth0`. Router LAN IPv6 addresses are the branch's shared
prefix plus `ff:1`, `ff:2`, `ff:3`, each `/64`. Clients use EUI-64 SLAAC
with privacy addressing disabled and no DHCPv6 address or prefix requests.
The two subscriber branches can reuse IPv4 subnets because they have separate
bridges and routers. Within a branch, LANs forward IPv4 and IPv6 to each other.
IPv4 uses WAN masquerading; IPv6 uses routing and NDP relay without NAT.

Every Ethernet MAC is `02:42` followed by the four intended IPv4 octets in
hexadecimal. For example `192.168.1.10` gives `02:42:c0:a8:01:0a`.
Both roamers use the MAC derived from `192.168.0.12`; their actual IPv4
addresses come from DHCP. MACs are unique within each bridge; reuse between
isolated branches is intentional. All interfaces and MACs are assigned when
containers are created, independent of Docker's bootstrap IP allocations.

## Native networking and registration

OpenWrt runs packaged procd, netifd, dnsmasq, odhcpd and firewall4/nftables
or firewall3/iptables. The package binaries and scripts are preserved.
Configuration is installed before PID 1 starts. LAN-only OpenWrt clients
start `/sbin/init` directly and let netifd configure their Ethernet device;
they have no WAN, NAT, DHCP server, prefix delegation or registration service.
Debian clients use their named native manager and Alpine uses ifupdown-ng.

Dnsmasq serves five-minute DHCPv4 leases from `.100` through `.199` on all
six LANs. Odhcpd advertises a 60-second preferred and 300-second valid SLAAC
lifetime, with periodic RAs every 5–10 seconds and a 30-second router lifetime.
On 25 these caps use `max_preferred_lifetime` and `max_valid_lifetime`.
On 21 native `ra_useleasetime=1`, `preferred_lifetime=60s` and `leasetime=5m`
provide the same caps. Odhcpd handles LAN NDP relay, learned client `/128`
routes, and proxies on the other interfaces. Same-LAN clients communicate
directly. An unreachable shared-prefix route rejects unknown destinations
instead of sending them back to the WAN.

`router/register` is a Bash service supervised by procd. It discovers relay
interfaces from UCI and their devices from netifd. Packaged tcpdump observes
incoming IPv6 sources and DAD candidates. It probes candidates on their
observed LAN with packaged ping/ip-full, reconciles existing neighbors and
router-owned addresses at startup, and retires stale neighbors on a MAC move.
Odhcpd remains responsible for all route and proxy changes.

For confirmed shared-prefix neighbors and router addresses, packaged socat
sends raw ICMPv6 Neighbor Solicitations for the ISP's `::1`. It binds the
registered address as a nonlocal IPv6 source, uses the WAN MAC in the source
link-layer option and sets hop limit 255. The kernel computes the ICMPv6
checksum. Registrations refresh every five seconds; failed sends and candidate
probes retry after three seconds. Procd reload triggers cover network, DHCP
configuration and interface events. Stopping the service terminates its
capture and probe children.

The ISP learner validates the source prefix, NS target, code, hop limit,
checksum, and source link-layer option matching the Ethernet source. A valid
NS installs a `/128` route and neighbor on that subscriber link. Ordinary
traffic and NAs do not register or extend deadlines. Registrations expire
after 15 seconds; restarting registration restores upstream connectivity
without changing client addresses. The DMZ uses its native gateway NS/NUD
behavior. No broad subscriber-prefix route is installed at the ISP.

WAN firewalls allow essential ICMPv6 and established traffic, and reject
unsolicited inbound TCP. LAN forwarding and IPv4 masquerading use native
firewall rules on each release.

## Validation

```sh
bash tests/address-generation.sh
bash tests/client-configuration.sh
bash tests/build-mirror.sh
./lab test
```

Configuration checks cover address seeds, interface ordering, inventories,
bridge membership, MAC uniqueness scoped to each bridge, client policies,
manifest generation, both package managers and release-specific lifetimes.
Go tests in `isp/ndp-learn_test.go` check NS validation and expiry behavior.

Live acceptance checks cover both subscribers' native managers and firewalls,
IPv4 and IPv6 connectivity, exact 4096-byte HTTP payload integrity, DMZ,
learned routes and proxies, unknown-destination rejection, direct LAN1/LAN3
peer routes and neighbor MACs, and blocked unsolicited inbound TCP. Captured
registration packets from each release are checked independently for source,
target, checksum, hop limit and source MAC by `tests/ns-packet.py`.

Each subscriber is stopped and restarted independently to verify registration
expiry and recovery while the other subscriber remains usable. Each roamer
follows exactly **LAN1 → LAN2 → LAN3 → LAN1**, moving the existing host veth
between bridges. Its interface index, MAC, SLAAC address and one persistent
IPv6 TCP connection must survive; DHCPv4 must follow the current LAN.
The traffic program never reconnects and checks bidirectional payloads.
Cleanup traps restore registration, test listeners and roaming placement
even when an acceptance check fails.
