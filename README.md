# ndp64lab

An isolated eleven-container OpenWrt 24.10.4 lab for one shared IPv6 /64
across eight separate LANs. The containers use nine Docker bridge links: one
ISP-to-WAN link and one link per LAN. LAN1 has two clients; LAN2 through LAN8
have one each. Docker's bridge-assigned addresses are replaced with the lab's
fixed IPv4 fixtures. No host interface addresses are read.

## Requirements

Linux x86_64, Docker Engine with buildx, Bash, curl, and permission to create
privileged containers and bridge networks. The first `up` downloads the pinned
OpenWrt x86/64 rootfs, checks it against `rootfs.sha256`, and builds a static Go
helper inside Docker. The OpenWrt image installs `ip-full` from its 24.10.4
package feed, so the first build needs Internet access.

## Lifecycle

From the repository root:

```sh
./lab up       # build and start
./lab test     # run acceptance checks against the live lab
./lab reset    # purge, rebuild, start, and test
./lab purge    # remove only ndp64lab resources and generated files
```

Each applet takes no extra arguments. `up` reports an existing lab; use `reset`
to start over. The project name is fixed as `ndp64lab`, so moving or renaming
the checkout does not change Docker resource names. `purge` selects containers,
networks, and images by the `org.ndp64lab.owner=ndp64lab` label. The dedicated
`ndp64labbuilder` buildx instance is removed only when its ownership marker is
present under `.generated`. The generated directory is ignored by Git.

## Fixed Addressing

The ISP has `198.18.0.1/30`, `fd42:6e64:7000:1::1/64`, and `fe80::1` on WAN,
plus `fd42:6e64:7000:2::2/128` on loopback. OpenWrt has `198.18.0.2/30` and
`fd42:6e64:7000:1::2/128` on `eth0`, with its IPv6 default route via
`fe80::1`. `eth1` through `eth8` have `192.168.1.1/24` through
`192.168.8.1/24`. Clients use `.10` on their LAN; the second LAN1 client uses
`192.168.1.11/24`. All clients receive the on-link, autonomous
`fd42:6e64:7000:1::/64` prefix via Router Advertisements from the helper.
DHCPv6 is disabled on each LAN.

OpenWrt's firewall keeps the normal LAN-to-WAN forwarding, WAN rejection, and
ICMPv6 forwarding behavior. The in-router helper sends RAs, learns client
addresses from LAN packets, installs `/128` routes, and proxies NDP for each
client on WAN and the other seven LANs. It also proxies the ISP's on-link `::1`
address on every LAN so replies can reach the ISP. The helper does not proxy a
client address on that client's own LAN, leaving same-LAN traffic on the Docker
bridge rather than in OpenWrt's forwarding path.

`test` checks that DHCPv6 is disabled on each LAN, plus all LANs, cross-LAN
traffic, the loopback ISP endpoint, upstream NDP, explicit source selection,
temporary-address changes, inbound ICMPv6, blocked new inbound TCP, and direct
LAN1 peer routing and MAC resolution. A temporary nftables counter checks that
LAN1 peer traffic does not enter OpenWrt's forwarding path.

When diagnosing a failed run, `docker exec ndp64labrouter logread` shows
OpenWrt and helper logs. `./lab purge` also works after a partial `up`.
