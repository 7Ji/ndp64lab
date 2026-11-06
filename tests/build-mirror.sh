#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin"
export PATH="$fixture/bin:$PATH"
export MIRROR_PROBES="$fixture/probes"
cat > "$fixture/bin/curl" <<'MOCK'
#!/bin/sh
[ "$#" = 10 ] || exit 1
url=${10}
[ "$*" = "--fail --silent --show-error --head --location --max-time 10 --output /dev/null $url" ] || exit 1
printf '%s\n' "$url" >> "$MIRROR_PROBES"
case "$url" in
    */21.02.7/*|*/trixie-updates/*) exit 22 ;;
    https://mirror.example/*/APKINDEX.tar.gz|https://mirror.example/*/packages.adb|https://mirror.example/*/Packages.gz|https://mirror.example/*/InRelease) exit 0 ;;
    *) echo "unexpected metadata URL: $url" >&2; exit 1 ;;
esac
MOCK
chmod +x "$fixture/bin/curl"
new_root() {
    root=$fixture/$1
    mkdir -p "$root"
}
configure() { sh "$repo/build/configure-mirror.sh" 'https://mirror.example/' "$root"; }
new_root alpine
mkdir -p "$root/etc/apk" "$root/etc/apt"
printf '%s\n' 'https://dl-cdn.alpinelinux.org/alpine/v3.20/main' > "$root/etc/apk/repositories"
printf '%s\n' 'deb http://deb.debian.org/debian trixie main' > "$root/etc/apt/sources.list"
sh "$repo/build/configure-mirror.sh" '' "$root"
[[ ! -e $MIRROR_PROBES ]]
configure
grep -Fxq 'https://mirror.example/alpine/v3.20/main' "$root/etc/apk/repositories"
# Even with another distro file present, configure only this image's manager.
grep -Fxq 'deb http://deb.debian.org/debian trixie main' "$root/etc/apt/sources.list"
grep -Fxq 'https://mirror.example/alpine/v3.20/main/x86_64/APKINDEX.tar.gz' "$MIRROR_PROBES"
new_root openwrt-apk
mkdir -p "$root/etc/apk/repositories.d"
printf '%s\n' 'https://downloads.openwrt.org/releases/25.12.6/packages/x86_64/base/packages.adb' > "$root/etc/apk/repositories.d/distfeeds.list"
configure
grep -Fxq 'https://mirror.example/openwrt/releases/25.12.6/packages/x86_64/base/packages.adb' "$root/etc/apk/repositories.d/distfeeds.list"
[[ ! -e $root/etc/apk/repositories ]]
new_root openwrt-opkg
mkdir -p "$root/etc/opkg"
cat > "$root/etc/opkg/distfeeds.conf" <<'FEEDS'
src/gz current https://downloads.openwrt.org/releases/23.05.6/targets/x86/64/packages
src/gz legacy https://downloads.openwrt.org/releases/21.02.7/targets/x86/64/packages
FEEDS
configure
grep -Fxq 'src/gz current https://mirror.example/openwrt/releases/23.05.6/targets/x86/64/packages' "$root/etc/opkg/distfeeds.conf"
grep -Fxq 'src/gz legacy https://downloads.openwrt.org/releases/21.02.7/targets/x86/64/packages' "$root/etc/opkg/distfeeds.conf"
new_root debian
mkdir -p "$root/etc/apt/sources.list.d"
cat > "$root/etc/apt/sources.list.d/debian.sources" <<'FEEDS'
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie
 trixie-updates
Components: main

Types: deb
URIs: https://deb.debian.org/debian-security
Suites: trixie-security
Components: main

Enabled: no
Types: deb
URIs: https://deb.debian.org/disabled
Suites: testing
Components: main
FEEDS
printf '%s\n' 'deb [arch=amd64] http://security.debian.org/debian-security trixie-security main' > "$root/etc/apt/sources.list"
configure
grep -Fxq 'URIs: http://deb.debian.org/debian' "$root/etc/apt/sources.list.d/debian.sources"
grep -Fxq 'URIs: https://mirror.example/debian-security' "$root/etc/apt/sources.list.d/debian.sources"
grep -Fxq 'deb [arch=amd64] https://mirror.example/debian-security trixie-security main' "$root/etc/apt/sources.list"
! grep -q '/disabled/' "$MIRROR_PROBES"
new_root empty
configure
[[ ! -e $root/etc ]]
printf 'package mirror detection and metadata fallback checks passed\n'
