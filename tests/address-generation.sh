#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo/lab"
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
# Check the real documentation parses, then use explicit inputs for known vectors.
load_addresses
here=$fixture
sed -e 's/^| `address-seed:customer`.*/| `address-seed:customer` | `lab` | customer |/' \
    -e 's/^| `address-seed:public`.*/| `address-seed:public` | `LAB` | public |/' \
    "$repo/README.md" > "$fixture/baseline"
cp "$fixture/baseline" "$here/README.md"
load_addresses
[[ $isp_identity4 == 108.97.98.1 && $router4 == 108.97.98.101 && $dmz4 == 108.97.98.201 ]]
[[ $shared6 == 2108:97:98:100:: && $website6 == 2076:65:66::2 ]]

# Known vectors cover every endpoint role and decimal octets with leading zeroes.
while read -r address expected; do
  [[ $(mac_from_ipv4 "$address") == "$expected" ]]
done <<'VECTORS'
108.97.98.100 02:42:6c:61:62:64
108.97.98.101 02:42:6c:61:62:65
76.65.66.1 02:42:4c:41:42:01
76.65.66.2 02:42:4c:41:42:02
108.97.98.200 02:42:6c:61:62:c8
108.97.98.201 02:42:6c:61:62:c9
192.168.1.1 02:42:c0:a8:01:01
192.168.8.10 02:42:c0:a8:08:0a
192.168.1.11 02:42:c0:a8:01:0b
000.008.016.255 02:42:00:08:10:ff
VECTORS
for bad in '' 1.2.3 1.2.3.4.5 256.2.3.4 1.-2.3.4 1.2.3.x 0000.2.3.4; do
  if (mac_from_ipv4 "$bad") > "$fixture/error" 2>&1; then
    printf 'accepted invalid IPv4: %s\n' "$bad" >&2; exit 1
  fi
done
check_endpoint_macs() {
  local name interface address mac count=0 first
  local -A seen=()
  while read -r name interface address; do
    mac=$(mac_from_ipv4 "$address")
    [[ ! -v seen[$mac] ]]
    seen[$mac]=1
    first=${mac%%:*}
    (( (16#$first & 3) == 2 )) # Locally administered and unicast.
    count=$((count + 1))
  done < <(interface_addresses)
  [[ $count == 24 && ${#seen[@]} == 24 ]]
}
check_endpoint_macs

# The examples remain unchanged; only changing the naming table must change config.
sed -e 's/| `lab` |/| `abc` |/' -e 's/| `LAB` |/| `ABC` |/' "$fixture/baseline" > "$here/README.md"
load_addresses
[[ $isp_identity4 == 97.98.99.1 && $router4 == 97.98.99.101 && $dmz4 == 97.98.99.201 ]]
[[ $shared6 == 2097:98:99:100:: && $website6 == 2065:66:67::2 ]]
[[ $(mac_from_ipv4 "$isp_customer4") == 02:42:61:62:63:64 ]]
[[ $(mac_from_ipv4 "$router4") == 02:42:61:62:63:65 ]]
[[ $(mac_from_ipv4 "$isp_dmz4") == 02:42:61:62:63:c8 ]]
[[ $(mac_from_ipv4 "$dmz4") == 02:42:61:62:63:c9 ]]
[[ $(mac_from_ipv4 "$isp_public4") == 02:42:41:42:43:01 ]]
[[ $(mac_from_ipv4 "$website4") == 02:42:41:42:43:02 ]]
check_endpoint_macs
mkdir "$here/router"
cp "$repo/router/network" "$here/router/network"
generated=$here/generated
prepare_configuration
[[ $(cat "$generated/addresses") == $'shared6=2097:98:99:100::\nisp_customer6=2097:98:99:100::1\nwebsite4=65.66.67.2\nwebsite6=2065:66:67::2' ]]
grep -q "option ipaddr '97.98.99.101'" "$generated/network"
grep -q "option gateway '97.98.99.100'" "$generated/network"
grep -q "option ip6addr '2097:98:99:100::2/128'" "$generated/network"
[[ $(wc -c < "$generated/www/index.html") == 4096 ]]
LC_ALL=C tr -d ' -~' < "$generated/www/index.html" | cmp -s - /dev/null
cp "$generated/www/index.html" "$fixture/first-payload"
prepare_configuration
if cmp -s "$fixture/first-payload" "$generated/www/index.html"; then
  printf 'deployment payload was reused\n' >&2; exit 1
fi

# Use the ISP's reported address, skipping addresses still undergoing DAD.
dc() {
  [[ $* == 'isp ip -o -6 addr show dev eth0 scope link' ]] || return 1
  cat <<'ADDRESSES'
2: eth0    inet6 fe80::dead/64 scope link tentative
2: eth0    inet6 fe80::bad/64 scope link dadfailed
2: eth0    inet6 fe80::42:6162:6364/64 scope link
ADDRESSES
}
configure_router_gateway
grep -q "option ip6gw 'fe80::42:6162:6364'" "$generated/network"
! grep -q '@GATEWAY6@' "$generated/network"

# A stale deployment must fail early with the endpoint and reset instruction.
fixture_bad_mac=0
dc() {
  local name interface address
  while read -r name interface address; do
    if [[ $name == "$1" && /sys/class/net/$interface/address == "$3" ]]; then
      if (( fixture_bad_mac == 1 )); then printf '%s\n' '02:42:00:00:00:00'
      else mac_from_ipv4 "$address"; fi
      return
    fi
  done < <(interface_addresses)
  return 1
}
check_interface_macs
fixture_bad_mac=1
if (check_interface_macs) > "$fixture/error" 2>&1; then
  printf 'accepted a stale interface MAC\n' >&2; exit 1
fi
grep -q 'isp eth0 MAC is .*; expected 02:42:61:62:63:64 .*run ./lab reset' "$fixture/error"

# HTTP success alone must not pass: the complete response must match the file.
response_fixture=$fixture/response
cp "$generated/www/index.html" "$response_fixture"
fixture_http_failure=0
dc() {
  (( fixture_http_failure == 0 )) || return 22
  cat "$response_fixture"
}
check_website fixture
printf '\n' >> "$response_fixture"
if (check_website fixture) > "$fixture/error" 2>&1; then
  printf 'accepted a response with an extra newline\n' >&2; exit 1
fi
cp "$generated/www/index.html" "$response_fixture"
fixture_http_failure=1
if (check_website fixture) > "$fixture/error" 2>&1; then
  printf 'accepted an HTTP failure\n' >&2; exit 1
fi

for bad in missing duplicate malformed identical; do
  cp "$fixture/baseline" "$here/README.md"
  case $bad in
    missing) sed -i '/^| `address-seed:public`/d' "$here/README.md" ;;
    duplicate) sed -i '/^| `address-seed:public`/p' "$here/README.md" ;;
    malformed) sed -i 's/| `LAB` |/| `LÄB` |/' "$here/README.md" ;;
    identical) sed -i 's/| `LAB` |/| `lab` |/' "$here/README.md" ;;
  esac
  if (load_addresses) > "$fixture/error" 2>&1; then
    printf 'unexpectedly accepted %s seeds\n' "$bad" >&2; exit 1
  fi
done
# Rows outside Topology must not supply missing seeds.
sed '/^| `address-seed:public`/d' "$fixture/baseline" > "$here/README.md"
printf '\n## Other\n| `address-seed:public` | `ABC` | ignored |\n' >> "$here/README.md"
if (load_addresses) > "$fixture/error" 2>&1; then
  printf 'accepted a seed outside Topology\n' >&2; exit 1
fi
printf 'address generation, interface MAC and deployment payload checks passed\n'
