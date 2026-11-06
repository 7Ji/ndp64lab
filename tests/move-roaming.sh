#!/bin/sh
# Runs in a temporary privileged container sharing only the host network.
set -eu
peer_index=$1
target_bridge=$2
port=$(ip -o link show | awk -v idx="$peer_index:" '$1 == idx {sub(/@.*/, "", $2); sub(/:$/, "", $2); print $2}')
[ -n "$port" ]
current=$(basename "$(readlink "/sys/class/net/$port/master")")
[ "$current" != "$target_bridge" ] || exit 0
trap 'ip link set dev "$port" up' EXIT
ip link set dev "$port" down
ip link set dev "$port" master "$target_bridge"
sleep 0.3
ip link set dev "$port" up
