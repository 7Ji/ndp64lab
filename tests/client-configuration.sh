#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo/lab"
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
generated=$fixture
load_addresses
prepare_configuration
[[ $(containers | wc -l) -eq 17 && $(segments | wc -l) -eq 10 ]]
[[ $(clients | wc -l) -eq 10 ]]
for id in 25 21; do
  select_subscriber "$id"
  [[ $(branch_clients | wc -l) -eq 5 ]]
  [[ $(branch_clients | awk '$2==1 {n++} END {print n}') -eq 2 ]]
  [[ $(branch_clients | awk '$2==3 {n++} END {print n}') -eq 2 ]]
  grep -q 'Address=192.168.1.10/24' "$generated/clients/client$id-networkd/network"
  grep -q 'Token=eui64' "$generated/clients/client$id-networkd/network"
  grep -q 'address1=192.168.1.11/24,192.168.1.1' "$generated/clients/client$id-nm/network"
  grep -q 'ip6-privacy=0' "$generated/clients/client$id-nm/network"
  grep -q 'gateway 192.168.2.1' "$generated/clients/client$id-alpine/network"
  for kind in fw4 fw3; do
    file=$generated/clients/client$id-$kind/network
    grep -q "option reqaddress 'none'" "$file"
    grep -q "option reqprefix 'no'" "$file"
    ! grep -Eq "config interface 'wan|masq|ip6assign" "$file" "$generated/clients/client$id-$kind/firewall"
  done
  grep -q "option ipaddr '192.168.3.10'" "$generated/clients/client$id-fw4/network"
  grep -q "option ipaddr '192.168.3.11'" "$generated/clients/client$id-fw3/network"
  grep -q '^DHCP=ipv4$' "$generated/clients/roaming$id/network"
  ! grep -q '^Address=' "$generated/clients/roaming$id/network"
  [[ $(grep -c "config dhcp 'lan" "$generated/router$id/dhcp") -eq 3 ]]
  if [[ $id == 25 ]]; then
  [[ $(grep -c "max_preferred_lifetime '60s'" "$generated/router$id/dhcp") -eq 3 ]]
  [[ $(grep -c "max_valid_lifetime '300s'" "$generated/router$id/dhcp") -eq 3 ]]
  else
    [[ $(grep -c "preferred_lifetime '60s'" "$generated/router$id/dhcp") -eq 3 ]]
    [[ $(grep -c "ra_useleasetime '1'" "$generated/router$id/dhcp") -eq 3 ]]
    ! grep -q max_valid_lifetime "$generated/router$id/dhcp"
  fi
  [[ $(grep -c "leasetime '5m'" "$generated/router$id/dhcp") -eq 3 ]]
  grep -q "option ip6addr '${shared6}ff:3/64'" "$generated/router$id/network"
done
[[ $(cat "$generated/client-manifest") == "$(client_manifest)" ]]
grep -q 'apk --cache-dir' "$repo/Dockerfile.router"
grep -q 'opkg --cache' "$repo/Dockerfile.router"
grep -q '^FROM router AS client$' "$repo/Dockerfile.router"
! grep -q 'lab-client' "$repo/Dockerfile.router"
printf 'subscriber inventories, native configurations, lifetimes and shared image layers passed\n'
prepare_peer_configs
for row in '0 76.65.66.1/30' '1 108.97.98.100/31' '2 108.97.98.150/31' '3 108.97.98.200/31'; do
  read -r port address <<< "$row"
  awk -v dev="eth$port" -v address="$address" '$1=="iface" {active=($2==dev && $3=="inet")} active && $1=="address" && $2==address {found=1} END {exit !found}' "$generated/peers/isp/interfaces"
done
[[ $(grep -c '^command=/usr/sbin/isp-ndp-learn' "$generated/peers/isp/supervisord.conf") -eq 3 ]]
grep -q '2108:97:98:100::/64 2108:97:98:100::1 eth1 15' "$generated/peers/isp/supervisord.conf"
grep -q '2108:97:98:150::/64 2108:97:98:150::1 eth2 15' "$generated/peers/isp/supervisord.conf"
grep -q '2108:97:98:200::/64 2108:97:98:200::1 eth3 15' "$generated/peers/isp/supervisord.conf"
printf 'ISP interface configuration and three learner inventories passed\n'
