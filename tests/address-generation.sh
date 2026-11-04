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

# The examples remain unchanged; only changing the naming table must change config.
sed -e 's/| `lab` |/| `abc` |/' -e 's/| `LAB` |/| `ABC` |/' "$fixture/baseline" > "$here/README.md"
load_addresses
[[ $isp_identity4 == 97.98.99.1 && $router4 == 97.98.99.101 && $dmz4 == 97.98.99.201 ]]
[[ $shared6 == 2097:98:99:100:: && $website6 == 2065:66:67::2 ]]
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
printf 'address generation and deployment payload checks passed\n'
