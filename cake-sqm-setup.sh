#!/usr/bin/env bash
# CAKE SQM interactive installer
# Author: github.com/galpt
# Sources used for syntax/options/examples:
#  - tc-cake manual: https://man7.org/linux/man-pages/man8/tc-cake.8.html
#  - CAKE / IFB examples: https://www.bufferbloat.net/projects/codel/wiki/Cake
#  - OpenWrt SQM (IFB usage): https://openwrt.org/docs/guide-user/network/traffic-shaping/sqm

set -euo pipefail
IFS=$'\n\t'

# Ensure we run under bash (some desktop/file-manager runners invoke /bin/sh)
if [ -z "${BASH_VERSION-}" ]; then
  if command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
  else
    echo "ERROR: this script requires bash. Install bash and re-run." >&2
    exit 1
  fi
fi

PROG_NAME=$(basename "$0")

# Recommended CAKE option strings (user-specified preference) — use arrays so words remain separate
EGRESS_OPTS=(internet diffserv4 dual-srchost nat split-gso conservative)
INGRESS_OPTS=(internet diffserv4 dual-dsthost nat split-gso conservative)

# Colors (print newline automatically for nicer output)
_green() { printf "\033[1;32m%s\033[0m\n" "$*"; }
_yellow() { printf "\033[1;33m%s\033[0m\n" "$*"; }
_red() { printf "\033[1;31m%s\033[0m\n" "$*"; }

# Print header / intro
print_header() {
  cat <<'HEADER'

┌─────────────────────────────────────────────────────────┐
│               CAKE Config Script — interactive          │
│                    Author: github.com/galpt            │
└─────────────────────────────────────────────────────────┘

This script applies CAKE (Smart Queue Management) to an interface.
It can create an IFB device and redirect ingress so downloads are shaped.

Hints:
 - Prefer the physical WAN/egress interface (not a bridge/veth).
 - For Wi‑Fi: set bandwidth to ~85–90% of your stable Wi‑Fi rate.

HEADER
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "$( _red "ERROR" ): required command '$1' not found."; exit 1; }
}

ensure_prereqs() {
  require_cmd ip
  require_cmd tc
  require_cmd modprobe
}

check_root_or_sudo() {
  if [ "$EUID" -ne 0 ]; then
    echo
    echo "This script needs root — trying to re-run with sudo..."
    exec sudo bash "$0" "$@"
  fi
}

detect_interfaces() {
  mapfile -t ALL_IFS < <(ls /sys/class/net | grep -v '^lo$')

  # Prefer kernel-reported link type to detect IFB devices (robust even if interface
  # name doesn't include "ifb"). Fall back to name-prefix check for very old iproute2.
  IFB_DEVS=()
  if ip -o link show type ifb >/dev/null 2>&1; then
    mapfile -t IFB_DEVS < <(ip -o link show type ifb 2>/dev/null | awk -F': ' '{print $2}' | awk '{print $1}')
  fi

  INTERFACES=()
  for ifc in "${ALL_IFS[@]}"; do
    # Skip IFB devices detected by kernel type OR by legacy name prefix
    skip_ifb=0
    for d in "${IFB_DEVS[@]}"; do
      if [ "$d" = "$ifc" ]; then
        skip_ifb=1
        break
      fi
    done
    if [ "$skip_ifb" -eq 1 ] || [[ "$ifc" =~ ^ifb ]]; then
      continue
    fi

    type="virtual"
    if [ -d "/sys/class/net/$ifc/wireless" ]; then
      type="wireless"
    elif [ -L "/sys/class/net/$ifc/device" ]; then
      type="ethernet"
    fi
    ipaddr=$(ip -4 -o addr show dev "$ifc" 2>/dev/null | awk '{print $4}' | paste -s -d',' -)
    [ -z "$ipaddr" ] && ipaddr="(no addr)"
    INTERFACES+=("$ifc|$type|$ipaddr")
  done
}

show_interface_menu() {
  echo
  echo "Detected network interfaces:"
  printf "%3s %-12s %-10s %s\n" "#" "interface" "type" "addr(s)"
  echo "---------------------------------------------------------"
  i=1
  for entry in "${INTERFACES[@]}"; do
    IFS='|' read -r name type addr <<< "$entry"
    printf "%3s %-12s %-10s %s\n" "$i" "$name" "$type" "$addr"
    ((i++))
  done
  echo
  echo "Tip: SQM belongs on the physical WAN/egress interface (not a bridge or docker veth)."
}

prompt_select_interface() {
  while true; do
    read -rp "Select interface number to configure (or 'q' to quit): " sel
    [[ "$sel" =~ ^[Qq]$ ]] && echo "Aborted." && exit 0
    if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#INTERFACES[@]}" ]; then
      idx=$((sel-1))
      IFS='|' read -r SELECTED_IF TYPE SELECTED_ADDR <<< "${INTERFACES[$idx]}"
      echo
      echo "Selected: $SELECTED_IF ($TYPE) — $SELECTED_ADDR"
      # WiFi reminder
      if [ "$TYPE" = "wireless" ]; then
        echo
        _yellow "WARNING: Wi‑Fi throughput is variable — when shaping WLAN set bandwidth to ~85-90% of your stable Wi‑Fi rate (see docs).";
      fi
      break
    fi
    echo "Invalid selection — try again."
  done
}

tc_has_cake() {
  tc -s qdisc show dev "$1" 2>/dev/null | grep -qw cake || return 1
}

ask_yes_no() {
  local prompt="$1" default_answer="Y"
  read -rp "$prompt [Y/n]: " answer
  answer=${answer:-$default_answer}
  [[ "$answer" =~ ^([yY][eE][sS]|[yY])$ ]]
}

parse_bw() {
  # Accept: 10M 10Mbit 500k 500kbit unlimited auto (returns UNLIMITED or normalized 'XYZkbit/Mbit')
  local raw=${1,,}
  raw=${raw// /}
  if [[ -z "$raw" || "$raw" == "unlimited" || "$raw" == "u" ]]; then
    echo UNLIMITED
    return 0
  fi
  if [[ "$raw" == "auto" ]]; then
    echo AUTO
    return 0
  fi
  if [[ "$raw" =~ ^([0-9]+)([kKmMgG]?)$ ]]; then
    local val=${BASH_REMATCH[1]}
    local unit=${BASH_REMATCH[2]}
    if [ -z "$unit" ]; then
      # default to Mbit when user supplies plain number
      unit=M
    fi
    case "$unit" in
      k|K) echo "${val}kbit" ;;
      m|M) echo "${val}Mbit" ;;
      g|G) echo "${val}Gbit" ;;
      *) echo "" ; return 1 ;;
    esac
    return 0
  fi
  echo ""; return 1
}

autodetect_speed() {
  # Try ethtool for ethernet, iw for wireless. Returns e.g. 100Mbit or empty.
  local ifc=$1
  # ethtool
  if command -v ethtool >/dev/null 2>&1; then
    speed=$(ethtool "$ifc" 2>/dev/null | awk -F": " '/Speed:/ {print $2}' | tr -d '\\n') || true
    if [[ "$speed" =~ ^([0-9]+)Mb/s$ ]]; then
      echo "${BASH_REMATCH[1]}Mbit" && return 0
    fi
  fi
  # iw (wireless)
  if command -v iw >/dev/null 2>&1; then
    b=$(iw dev "$ifc" link 2>/dev/null | awk -F": " '/tx bitrate/ {print $2}') || true
    if [[ "$b" =~ ^([0-9]+)\.?[0-9]*\s*Mb/s ]]; then
      echo "${BASH_REMATCH[1]}Mbit" && return 0
    fi
  fi
  echo ""
}

create_ifb() {
  local ifc=$1
  IFBDEV="ifb-$ifc"
  if ! ip link show dev "$IFBDEV" >/dev/null 2>&1; then
    modprobe ifb || true
    ip link add dev "$IFBDEV" type ifb || true
  fi
  ip link set dev "$IFBDEV" up
}

setup_ingress_redirect() {
  local ifc=$1
  local ifb=$2
  # remove existing ingress qdisc filters (safe)
  tc qdisc del dev "$ifc" ingress >/dev/null 2>&1 || true
  tc qdisc add dev "$ifc" handle ffff: ingress || true
  # redirect *all* ingress to IFB
  tc filter add dev "$ifc" parent ffff: protocol ip u32 match u32 0 0 action mirred egress redirect dev "$ifb" || true
}

apply_cake_egress() {
  local ifc=$1
  local bw=$2
  shift 2
  # remaining args ($@) are the CAKE option tokens (array-safe)
  if [ "$bw" = "UNLIMITED" ]; then
    # explicitly pass the 'unlimited' token so CAKE receives it directly
    tc qdisc replace dev "$ifc" root cake unlimited "$@"
  else
    tc qdisc replace dev "$ifc" root cake bandwidth "$bw" "$@"
  fi
}

apply_cake_ingress() {
  local ifb=$1
  local bw=$2
  shift 2
  # remaining args ($@) are the CAKE option tokens (array-safe)
  if [ "$bw" = "UNLIMITED" ]; then
    # explicitly pass the 'unlimited' token to ensure IFB qdisc becomes unlimited
    tc qdisc replace dev "$ifb" root cake unlimited "$@"
  else
    tc qdisc replace dev "$ifb" root cake bandwidth "$bw" "$@"
  fi
}

remove_cake() {
  local ifc=$1
  local ifb="ifb-$ifc"
  tc qdisc del dev "$ifc" root >/dev/null 2>&1 || true
  tc qdisc del dev "$ifc" ingress >/dev/null 2>&1 || true
  tc qdisc del dev "$ifb" root >/dev/null 2>&1 || true
  ip link set dev "$ifb" down >/dev/null 2>&1 || true
  ip link del dev "$ifb" >/dev/null 2>&1 || true
  echo "Removed CAKE (if present) from $ifc and cleaned up $ifb"
}

show_qdiscs() {
  echo
  echo "Current qdisc state for $SELECTED_IF and its IFB (if present):"
  tc -s qdisc show dev "$SELECTED_IF" || true
  echo
  IFBDEV="ifb-$SELECTED_IF"
  if ip link show dev "$IFBDEV" >/dev/null 2>&1; then
    tc -s qdisc show dev "$IFBDEV" || true
  fi
}

main() {
  check_root_or_sudo
  ensure_prereqs
  print_header

  detect_interfaces
  if [ "${#INTERFACES[@]}" -eq 0 ]; then
    echo "No network interfaces found. Exiting."; exit 1
  fi

  show_interface_menu
  prompt_select_interface

  # Detect if an IFB device already exists for the selected interface
  IFBDEV="ifb-$SELECTED_IF"
  IFB_PRESENT=0
  IFB_HAS_CAKE=0
  PRESET_DOWNLOAD_BW=0
  if ip link show dev "$IFBDEV" >/dev/null 2>&1; then
    IFB_PRESENT=1
    if tc_has_cake "$IFBDEV"; then
      IFB_HAS_CAKE=1
    fi
  fi

  if [ "$IFB_PRESENT" -eq 1 ]; then
    echo
    _yellow "Detected existing IFB device: $IFBDEV"
    if [ "$IFB_HAS_CAKE" -eq 1 ]; then
      _yellow "CAKE already present on $IFBDEV."
      # allow user to reply 'y/n' OR supply a bandwidth directly (e.g. 'unlimited')
      read -rp "Replace existing CAKE on $IFBDEV with new settings? [Y/n or enter bandwidth directly]: " __resp_ifb
      __resp_ifb=${__resp_ifb:-Y}
      case "${__resp_ifb,,}" in
        y|yes)
          echo "Will replace existing CAKE on $IFBDEV." ;;
        n|no)
          echo "Leaving existing ingress CAKE in place; ingress will be skipped.";
          DOWNLOAD_BW="SKIP"; SKIP_INGRESS=1 ;;
        *)
          # user supplied a bandwidth at this prompt
          dnnorm=$(parse_bw "${__resp_ifb}") || true
          if [ "$dnnorm" = "UNLIMITED" ] || [ "$dnnorm" = "AUTO" ] || [[ "$dnnorm" =~ ^[0-9]+(kbit|Mbit|Gbit)$ ]]; then
            DOWNLOAD_BW="$dnnorm"
            PRESET_DOWNLOAD_BW=1
            echo "Will replace existing CAKE on $IFBDEV with bandwidth: $DOWNLOAD_BW"
          else
            echo "Unrecognized input; leaving existing CAKE in place.";
            DOWNLOAD_BW="SKIP"; SKIP_INGRESS=1
          fi
          ;;
      esac
    else
      # existing IFB without CAKE — automatically reused when user enables ingress (no prompt)
      :
    fi
  fi

  # detect existing CAKE on the selected interface (egress)
  if tc_has_cake "$SELECTED_IF"; then
    echo
    _yellow "Note: CAKE already present on $SELECTED_IF.";
    if ask_yes_no "Replace existing CAKE on $SELECTED_IF with new settings?"; then
      echo "Will replace existing CAKE on $SELECTED_IF."
    else
      echo "No changes made. Exiting."; exit 0
    fi
  fi

  # Ask whether to configure egress/upload (default yes).
  # Allow user to enter a bandwidth directly at the prompt (e.g. "unlimited" or "10M").
  read -rp "Configure upload (egress) on $SELECTED_IF? [Y/n or enter bandwidth directly]: " _resp
  _resp=${_resp:-Y}
  case "${_resp,,}" in
    y|yes)
      # ask for a rate
      while true; do
        read -rp "Enter upload rate (e.g. 10M, 800k, 'auto', or 'unlimited'): " upraw
        upnorm=$(parse_bw "$upraw") || true
        if [ "$upnorm" = "AUTO" ]; then
          autod=$(autodetect_speed "$SELECTED_IF")
          if [ -n "$autod" ]; then
            echo "Autodetected link speed: $autod — using as upload limit."
            upnorm="$autod"
          else
            echo "Autodetect failed — please enter a rate or 'unlimited'."; continue
          fi
        fi
        if [ "$upnorm" = "UNLIMITED" ] || [[ "$upnorm" =~ ^[0-9]+(kbit|Mbit|Gbit)$ ]]; then
          UPLOAD_BW="$upnorm"
          break
        fi
        echo "Invalid input — try again."
      done
      ;;
    n|no)
      UPLOAD_BW="SKIP" ;;
    # user entered a bandwidth directly at the prompt
    *)
      upnorm=$(parse_bw "$_resp") || true
      if [ "$upnorm" = "UNLIMITED" ] || [ "$upnorm" = "AUTO" ] || [[ "$upnorm" =~ ^[0-9]+(kbit|Mbit|Gbit)$ ]]; then
        UPLOAD_BW="$upnorm"
      else
        echo "Unrecognized input '$_resp' — treating as 'no'."; UPLOAD_BW="SKIP"
      fi
      ;;
  esac


  # Ask whether to configure ingress/download (supports entering bandwidth directly)
  if [ "${SKIP_INGRESS-}" = "1" ] || [ "${PRESET_DOWNLOAD_BW-}" = "1" ]; then
    # user chose to keep existing CAKE on IFB earlier or we already have a preset value — skip prompting
    :
  else
    read -rp "Configure download (ingress) shaping for $SELECTED_IF (requires IFB)? [Y/n or enter bandwidth directly]: " _resp_in
    _resp_in=${_resp_in:-Y}
    case "${_resp_in,,}" in
      y|yes)
        while true; do
          read -rp "Enter download rate (e.g. 50M, 5000k, 'auto', or 'unlimited'): " dnraw
          dnnorm=$(parse_bw "$dnraw") || true
          if [ "$dnnorm" = "AUTO" ]; then
            autod=$(autodetect_speed "$SELECTED_IF")
            if [ -n "$autod" ]; then
              echo "Autodetected link speed: $autod — using as download limit."
              dnnorm="$autod"
            else
              echo "Autodetect failed — please enter a rate or 'unlimited'."; continue
            fi
          fi
          if [ "$dnnorm" = "UNLIMITED" ] || [[ "$dnnorm" =~ ^[0-9]+(kbit|Mbit|Gbit)$ ]]; then
            DOWNLOAD_BW="$dnnorm"
            break
          fi
          echo "Invalid input — try again."
        done
        ;;
      n|no)
        DOWNLOAD_BW="SKIP" ;;
      *)
        # user supplied bandwidth directly at the Y/n prompt
        dnnorm=$(parse_bw "$_resp_in") || true
        if [ "$dnnorm" = "UNLIMITED" ] || [ "$dnnorm" = "AUTO" ] || [[ "$dnnorm" =~ ^[0-9]+(kbit|Mbit|Gbit)$ ]]; then
          DOWNLOAD_BW="$dnnorm"
        else
          echo "Unrecognized input '$_resp_in' — treating as 'no'."; DOWNLOAD_BW="SKIP"
        fi
        ;;
    esac
  fi

  echo
  echo
  echo "Summary of choices for $SELECTED_IF:"
  echo "  Upload limit (egress): ${UPLOAD_BW:-(skipped)}"
  if [ "${DOWNLOAD_BW:-}" = "SKIP" ] && [ "${IFB_PRESENT:-0}" -eq 1 ] && [ "${IFB_HAS_CAKE:-0}" -eq 1 ]; then
    echo "  Download limit (ingress): (existing CAKE on $IFBDEV)"
  else
    echo "  Download limit (ingress): ${DOWNLOAD_BW:-(skipped)}"
  fi

  # Nicely print option lists (comma-separated)
  join_by() { local sep="$1"; shift; local out=""; for a in "$@"; do
      out+="${out:+$sep}$a"; done; printf "%s" "$out"; }

  echo "  Egress options : $(join_by ", " "${EGRESS_OPTS[@]}")"
  echo "  Ingress options: $(join_by ", " "${INGRESS_OPTS[@]}")"

  if ! ask_yes_no "Proceed to apply these settings now?"; then
    echo "Aborted by user."; exit 0
  fi

  # Apply changes
  echo
  echo "Applying CAKE... (this will replace/overwrite existing qdiscs if present)"

  # Cleanup previous qdiscs if present
  tc qdisc del dev "$SELECTED_IF" root >/dev/null 2>&1 || true

  if [ "$UPLOAD_BW" != "SKIP" ]; then
    echo "- Setting egress CAKE on $SELECTED_IF"
    if [ "$UPLOAD_BW" = "UNLIMITED" ]; then
      _yellow "Applying: tc qdisc replace dev $SELECTED_IF root cake unlimited ${EGRESS_OPTS[*]}"
    else
      _yellow "Applying: tc qdisc replace dev $SELECTED_IF root cake bandwidth $UPLOAD_BW ${EGRESS_OPTS[*]}"
    fi
    apply_cake_egress "$SELECTED_IF" "$UPLOAD_BW" "${EGRESS_OPTS[@]}"
  fi

  if [ "$DOWNLOAD_BW" != "SKIP" ]; then
    echo "- Preparing IFB and ingress redirect"
    create_ifb "$SELECTED_IF"
    IFBDEV="ifb-$SELECTED_IF"
    setup_ingress_redirect "$SELECTED_IF" "$IFBDEV"
    if [ "$DOWNLOAD_BW" = "UNLIMITED" ]; then
      _yellow "Applying: tc qdisc replace dev $IFBDEV root cake unlimited ${INGRESS_OPTS[*]}"
    else
      _yellow "Applying: tc qdisc replace dev $IFBDEV root cake bandwidth $DOWNLOAD_BW ${INGRESS_OPTS[*]}"
    fi
    echo "- Setting ingress CAKE on $IFBDEV"
    apply_cake_ingress "$IFBDEV" "$DOWNLOAD_BW" "${INGRESS_OPTS[@]}"
  fi

  echo
  _green "Done."; echo
  show_qdiscs
  echo
  echo "To remove CAKE and cleanup the IFB for $SELECTED_IF, re-run this script with option '--remove $SELECTED_IF' or use the interactive menu next time."
}

# Support a quick non-interactive removal: --remove IFACE
if [ "${1-}" = "--remove" ]; then
  check_root_or_sudo
  if [ -z "${2-}" ]; then echo "Usage: $PROG_NAME --remove <iface>"; exit 1; fi
  remove_cake "$2"; exit 0
fi

main "$@"
