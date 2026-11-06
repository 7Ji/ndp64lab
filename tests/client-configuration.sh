#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo/lab"
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
generated=$fixture
prepare_clients
expected='client1 1 10 networkd
client2 2 10 networkmanager
client3 3 10 alpine
client4 4 10 fw3
client5 5 10 fw4
client6 6 10 networkd
client7 7 10 networkmanager
client8 8 10 alpine
client1b 1 11 fw3'
[[ $(clients) == "$expected" && $(tail -n +2 "$generated/client-manifest") == "$expected"$'\nroaming 1 dhcp networkd' ]]
# Check distinct LAN addresses and manager policies, including the extra LAN1 peer.
grep -q 'Address=192.168.6.10/24' "$generated/clients/client6/network"
grep -q 'IPv6AcceptRA=yes' "$generated/clients/client1/network"
grep -q 'Token=eui64' "$generated/clients/client1/network"
grep -q 'address1=192.168.7.10/24,192.168.7.1' "$generated/clients/client7/network"
grep -q 'ip6-privacy=0' "$generated/clients/client2/network"
grep -q 'gateway 192.168.8.1' "$generated/clients/client8/network"
grep -q "option ipaddr '192.168.1.11'" "$generated/clients/client1b/network"
for name in client4 client5 client1b; do
  grep -q "option reqaddress 'none'" "$generated/clients/$name/network"
  grep -q "option reqprefix 'no'" "$generated/clients/$name/network"
  ! grep -Eq "config interface 'wan|masq" "$generated/clients/$name/network" "$generated/clients/$name/firewall"
done
printf 'client mix and native manager configuration checks passed\n'
grep -q '^DHCP=ipv4$' "$generated/clients/roaming/network"
! grep -q '^Address=' "$generated/clients/roaming/network"
