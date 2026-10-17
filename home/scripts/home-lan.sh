#!/usr/bin/env bash
# home-lan: start/stop home-lan.target depending on whether the peer machine is on the same LAN.
# Config comes from the environment (set by home/handoff.nix):
#   HOME_LAN_PEER       tailscale hostname of the peer
#   HOME_LAN_PEER_MAC   peer NIC MAC, empty to skip the MAC check
#   HOME_LAN_PEER_ADDR  fixed LAN address, empty to discover it
#   HOME_LAN_KDECONNECT kdeconnect device name of the peer
set -euo pipefail

PEER="${HOME_LAN_PEER:?}"
PEER_MAC="${HOME_LAN_PEER_MAC:-}"
PEER_ADDR="${HOME_LAN_PEER_ADDR:-}"
KDC_DEVICE="${HOME_LAN_KDECONNECT:-$PEER}"
RUN="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/home-lan"
FAIL_LIMIT=3
mkdir -p "$RUN"

lan_dev() {
  ip -j route show default | jq -r '[.[] | select(.dev != "tailscale0")][0].dev // empty'
}

candidates() {
  local dev=$1
  [ -n "$PEER_ADDR" ] && echo "$PEER_ADDR"
  if [ -n "$PEER_MAC" ]; then
    ip -j neigh show dev "$dev" | jq -r --arg m "${PEER_MAC,,}" '.[] | select((.lladdr // "") | ascii_downcase == $m) | .dst'
  fi
  # tailscale knows the peer's LAN endpoints; anything private is worth a direct probe
  tailscale status --json 2>/dev/null \
    | jq -r --arg h "$PEER" '(.Peer // {})[] | select(.HostName == $h or (.DNSName | startswith($h + "."))) | ((.Addrs // [])[], (.CurAddr // empty))' \
    | sed -E 's/:[0-9]+$//' \
    | grep -E '^(192\.168|10)\.|^172\.(1[6-9]|2[0-9]|3[01])\.' || true
}

# binding to the physical dev skips tailscale's subnet route, and a neighbour entry proves we are on the same L2
on_lan() {
  local ip=$1 dev=$2 lladdr
  ping -c1 -W1 -I "$dev" "$ip" >/dev/null 2>&1 || return 1
  lladdr=$(ip -j neigh show "$ip" dev "$dev" | jq -r '.[0].lladdr // empty')
  [ -n "$lladdr" ] || return 1
  [ -z "$PEER_MAC" ] || [ "${lladdr,,}" = "${PEER_MAC,,}" ]
}

find_peer() {
  local dev ip
  dev=$(lan_dev)
  [ -n "$dev" ] || return 1
  for ip in $(candidates "$dev" | awk '!seen[$0]++'); do
    if on_lan "$ip" "$dev"; then
      echo "$ip"
      return 0
    fi
  done
  return 1
}

active() { systemctl --user is-active --quiet home-lan.target; }

check() {
  if [ -f "$RUN/suspended" ]; then
    active && systemctl --user stop home-lan.target
    return 0
  fi
  local ip
  if ip=$(find_peer); then
    echo 0 > "$RUN/fails"
    echo "$ip" > "$RUN/peer-ip"
    if ! active; then
      systemctl --user start home-lan.target
      lab publish handoff.arrived --source home-lan --payload "$(jq -nc --arg p "$PEER" --arg ip "$ip" '{peer: $p, ip: $ip}')" 2>/dev/null || true
    fi
  else
    local fails
    fails=$(( $(cat "$RUN/fails" 2>/dev/null || echo 0) + 1 ))
    echo "$fails" > "$RUN/fails"
    # wifi drops for a few seconds all the time; only leave after several misses in a row
    if [ "$fails" -ge "$FAIL_LIMIT" ] && active; then
      rm -f "$RUN/peer-ip"
      systemctl --user stop home-lan.target
      lab publish handoff.left --source home-lan --payload "$(jq -nc --arg p "$PEER" '{peer: $p}')" 2>/dev/null || true
    fi
  fi
}

toggle() {
  if [ -f "$RUN/suspended" ]; then
    rm -f "$RUN/suspended"
    echo "$FAIL_LIMIT" > "$RUN/fails"
    check
  else
    touch "$RUN/suspended"
    systemctl --user stop home-lan.target
  fi
}

waybar() {
  local ip
  ip=$(cat "$RUN/peer-ip" 2>/dev/null || true)
  if [ -f "$RUN/suspended" ]; then
    jq -nc --arg p "$PEER" '{text: "󰍺", class: "suspended", tooltip: "Handoff suspended\nClick to resume (\($p))"}'
  elif active; then
    jq -nc --arg p "$PEER" --arg ip "$ip" '{text: "󰍹", class: "connected", tooltip: "Handoff active with \($p) (\($ip))\nClick to suspend"}'
  else
    jq -nc --arg p "$PEER" '{text: "󰶐", class: "idle", tooltip: "\($p) not on the LAN"}'
  fi
}

kdc_device_id() {
  kdeconnect-cli --refresh >/dev/null 2>&1 || true
  sleep 2
  kdeconnect-cli -a --id-name-only 2>/dev/null | awk -v n="$KDC_DEVICE" '{id=$1; $1=""; sub(/^ /, ""); if ($0 == n) {print id; exit}}'
}

kdeconnect_sync() {
  local state=false id plugin
  [ "$1" = on ] && state=true
  id=$(kdc_device_id)
  if [ -z "$id" ]; then
    echo "kdeconnect device '$KDC_DEVICE' not available" >&2
    return 0
  fi
  for plugin in kdeconnect_clipboard kdeconnect_sendnotifications kdeconnect_notifications; do
    busctl --user call org.kde.kdeconnect "/modules/kdeconnect/devices/$id" \
      org.kde.kdeconnect.device setPluginEnabled sb "$plugin" "$state" || true
  done
}

audio() {
  local role=$1 action=$2 ip id_file="$RUN/audio-module"
  if [ "$action" = stop ]; then
    [ -f "$id_file" ] && pactl unload-module "$(cat "$id_file")" || true
    rm -f "$id_file"
    return 0
  fi
  ip=$(cat "$RUN/peer-ip")
  if [ "$role" = sender ]; then
    pactl load-module module-tunnel-sink "server=tcp:$ip:4713" sink_name=home-lan-peer \
      "sink_properties=device.description=Peer\\ speakers" > "$id_file"
  else
    pactl load-module module-native-protocol-tcp port=4713 "auth-ip-acl=$ip" > "$id_file"
  fi
}

case "${1:-}" in
  check) check ;;
  toggle) toggle ;;
  waybar) waybar ;;
  peer) find_peer ;;
  kdeconnect) kdeconnect_sync "${2:?on|off}" ;;
  audio) audio "${2:?sender|receiver}" "${3:?start|stop}" ;;
  *) echo "usage: home-lan {check|toggle|waybar|peer|kdeconnect on|off|audio sender|receiver start|stop}" >&2; exit 1 ;;
esac
