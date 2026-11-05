#!/bin/sh
set -eu

mirror=${1%/}
root=$2
architecture=${3:-x86_64}
[ -n "$mirror" ] || exit 0
case "$mirror" in
    http://*|https://*) ;;
    *) echo 'BUILD_MIRROR must be an HTTP(S) base URL' >&2; exit 1 ;;
esac

# Emit only repositories configured for this image, with their metadata paths.
repositories() {
    case "$2" in
        opkg)
            awk '$1 == "src/gz" {print $3, "Packages.gz"} $1 == "src" {print $3, "Packages"}' "$1"
            ;;
        apk)
            awk -v arch="$architecture" '$1 !~ /^#/ {for (i=1; i<=NF; i++) if ($i ~ /^https?:\/\//) {
                if ($i ~ /\.adb$/) print $i, ".";
                else print $i, arch "/APKINDEX.tar.gz";
            }}' "$1"
            ;;
        apt-list)
            sed 's/\[[^]]*\]//' "$1" | awk '$1 == "deb" || $1 == "deb-src" {print $2, "dists/" $3 "/InRelease"}'
            ;;
        apt-sources)
            awk 'BEGIN {RS=""; FS="\n"}
            {
                delete fields; key="";
                for (i=1; i<=NF; i++) {
                    line=$i;
                    if (line ~ /^[ \t]*#/) continue;
                    if (line ~ /^[ \t]/) fields[key]=fields[key] " " line;
                    else {
                        colon=index(line, ":");
                        key=substr(line, 1, colon-1);
                        fields[key]=substr(line, colon+1);
                    }
                }
                if (fields["Enabled"] ~ /^[ \t]*no[ \t]*$/) next;
                n=split(fields["URIs"], urls, /[ \t]+/);
                m=split(fields["Suites"], suites, /[ \t]+/);
                for (i=1; i<=n; i++) if (urls[i] != "")
                    for (j=1; j<=m; j++) if (suites[j] != "")
                        print urls[i], "dists/" suites[j] "/InRelease";
            }' "$1"
            ;;
    esac
}
configure_file() {
    [ -f "$1" ] || return 0
    # A URI shared by multiple suites is changed only when all suites exist.
    repositories "$1" "$2" | awk '{
        if (!($1 in paths)) order[++n]=$1;
        paths[$1]=paths[$1] " " $2;
    } END {for (i=1; i<=n; i++) print order[i], paths[order[i]]}' |
    while read -r source anchors; do
        case "$source" in
            http://dl-cdn.alpinelinux.org/alpine/*|https://dl-cdn.alpinelinux.org/alpine/*)
                candidate=$mirror/alpine/${source#*/alpine/} ;;
            http://deb.debian.org/*|https://deb.debian.org/*|http://security.debian.org/*|https://security.debian.org/*)
                candidate=$mirror/${source#*://*/} ;;
            http://downloads.openwrt.org/*|https://downloads.openwrt.org/*)
                candidate=$mirror/openwrt/${source#*://*/} ;;
            *) continue ;;
        esac
        available=true
        for anchor in $anchors; do
            if [ "$anchor" = . ]; then metadata=$candidate
            else metadata=${candidate%/}/$anchor; fi
            if ! curl --fail --silent --show-error --head --location --max-time 10 \
                --output /dev/null "$metadata"; then available=false; break; fi
        done
        if [ "$available" = false ]; then
            echo "mirror unavailable for $source; retaining upstream" >&2
            continue
        fi
        pattern=$(printf '%s' "$source" | sed 's/[][\\.^$*|]/\\&/g')
        replacement=$(printf '%s' "$candidate" | sed 's/[&|\\]/\\&/g')
        sed -i -e "s|$pattern$|$replacement|" \
            -e "s|$pattern\\([[:space:]]\\)|$replacement\\1|g" "$1"
    done
}

if [ -f "$root/etc/opkg/distfeeds.conf" ]; then
    configure_file "$root/etc/opkg/distfeeds.conf" opkg
elif [ -f "$root/etc/apk/repositories" ] || [ -d "$root/etc/apk/repositories.d" ]; then
    configure_file "$root/etc/apk/repositories" apk
    for file in "$root"/etc/apk/repositories.d/*.list; do configure_file "$file" apk; done
elif [ -d "$root/etc/apt" ]; then
    configure_file "$root/etc/apt/sources.list" apt-list
    for file in "$root"/etc/apt/sources.list.d/*.list; do configure_file "$file" apt-list; done
    for file in "$root"/etc/apt/sources.list.d/*.sources; do configure_file "$file" apt-sources; done
fi
