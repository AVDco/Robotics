#!/usr/bin/env bash
# Attach the Intel RealSense D455 to WSL2 on LEGION_A.
#
# The D455 is a USB 3.0 device. WSL2 has no direct USB access, so it is
# forwarded with usbipd-win:
#
#   Windows  usbipd-win  ->  USB/IP  ->  WSL2 vhci-hcd  ->  /dev/videoN
#
# Prerequisite (elevated PowerShell; use the D455 busid from usbipd list):
#   usbipd bind --busid 1-18
# Rebinding may be required after moving the camera to a different port.
#
# After that, re-attaching after a reboot / unplug does NOT need admin:
#   bash scripts/realsense-wsl.sh
#
# Usage:
#   bash scripts/realsense-wsl.sh [busid]     # default: discover the single D455
#
# Run this from INSIDE WSL. Nothing on the robot is touched.
set -uo pipefail

BUSID="${1:-}"
USBIPD="/mnt/c/Program Files/usbipd-win/usbipd.exe"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ ! -x "$USBIPD" ]; then
  echo "[realsense] usbipd-win is not installed on the Windows host."
  echo "            winget install --id dorssel.usbipd-win -e"
  exit 1
fi

# The PyPI wheel uses V4L2 as well as raw USB. Grant access to this D455's
# video/HID nodes too; USB permissions alone leave enumeration silently empty.
# Match the product as well as vendor so unrelated Intel devices are untouched.
install_udev() {
  local rules=/etc/udev/rules.d/99-realsense-libusb.rules
  local desired
  desired="$(cat <<'EOF'
# Managed by Robotics/scripts/realsense-wsl.sh: D455 only.
SUBSYSTEM=="usb", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0b5c", MODE:="0666"
SUBSYSTEM=="video4linux", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0b5c", MODE:="0666"
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0b5c", MODE:="0666"
EOF
  )"
  if ! cmp -s "$rules" <(printf '%s\n' "$desired"); then
    echo "[realsense] updating udev rule $rules"
    if [ -f "$rules" ] && [ ! -e "$rules.before-vision-access" ]; then
      sudo cp -p "$rules" "$rules.before-vision-access" || return 1
    fi
    printf '%s\n' "$desired" | sudo tee "$rules" >/dev/null || return 1
  else
    return 0
  fi
  sudo udevadm control --reload-rules || return 1
  # Apply to already-attached nodes; a reconnect will use the same rules.
  local subsystem
  for subsystem in usb video4linux hidraw; do
    sudo udevadm trigger --action=add --subsystem-match="$subsystem" || return 1
  done
  sudo udevadm settle || return 1
}
install_udev || exit 1

echo "[realsense] usbipd-win: $("$USBIPD" --version 2>/dev/null | head -1)"

select_busid() {
  local listing="$1"
  local -a matches
  mapfile -t matches < <(printf '%s\n' "$listing" | tr -d '\r' |
    awk 'tolower($2) == "8086:0b5c" {print $1}')
  case "${#matches[@]}" in
    1) printf '%s\n' "${matches[0]}" ;;
    0) echo "[realsense] no D455 (8086:0b5c) connected on Windows." >&2; return 1 ;;
    *) echo "[realsense] multiple D455 devices; pass an explicit busid from usbipd list." >&2; return 1 ;;
  esac
}

listing="$("$USBIPD" list)" || exit 1
if [ -z "$BUSID" ]; then
  BUSID="$(select_busid "$listing")" || exit 1
fi
if [[ ! "$BUSID" =~ ^[0-9]+-[0-9]+$ ]]; then
  echo "[realsense] invalid busid: $BUSID" >&2
  exit 1
fi
line="$(printf '%s\n' "$listing" | awk -v busid="$BUSID" '$1 == busid {print}')"
if [ -z "$line" ]; then
  echo "[realsense] busid $BUSID not found. Current devices:"
  "$USBIPD" list
  exit 1
fi
if ! printf '%s\n' "$line" | awk 'tolower($2) == "8086:0b5c" {found=1} END {exit !found}'; then
  echo "[realsense] busid $BUSID is not a D455 (8086:0b5c); refusing to attach it." >&2
  exit 1
fi
echo "[realsense] device: $line"

# usbipd.exe is a Windows binary, so every line ends in CRLF and the state can
# be two words ("Not shared"). Stripping CR first and matching the whole state
# is the only form that gets both cases right: awk's last field is "shared",
# which would make a bound device look unbound forever.
state="$(echo "$line" | tr -d '\r' |
         sed -E 's/.*[[:space:]](Not shared|Shared|Attached)$/\1/')"
case "$state" in
  Attached)
    echo "[realsense] already attached to WSL."
    ;;
  Shared)
    echo "[realsense] loading vhci-hcd and attaching..."
    sudo modprobe vhci-hcd || { echo "[realsense] modprobe vhci-hcd failed"; exit 1; }
    "$USBIPD" attach --wsl --busid "$BUSID" || exit 1
    sleep 2
    ;;
  *)
    cat <<EOF
[realsense] device is "$state", not "Shared", so it cannot be attached.

Run this ONCE in an elevated PowerShell (Administrator):

    & "C:\\Program Files\\usbipd-win\\usbipd.exe" bind --busid $BUSID

then re-run this script. Binding persists across reboots.
EOF
    exit 2
    ;;
esac

echo
echo "[realsense] video nodes:"
ls -l /dev/video* 2>/dev/null || echo "  none yet (give it a second, then re-check)"
echo
echo "[realsense] by-id:"
ls -l /dev/v4l/by-id/ 2>/dev/null | grep -i realsense || echo "  no RealSense by-id entries"

# The node list is not proof: a camera exposes depth, colour and metadata nodes.
# Only SDK enumeration followed by a stream probe proves usable capture.
PY="$ROOT/Astro_dog/vision/.venv/bin/python"
echo
if [ -x "$PY" ]; then
  echo "[realsense] pyrealsense2 enumeration:"
  "$PY" - <<'PY'
import sys
try:
    import pyrealsense2 as rs
except Exception as exc:
    sys.exit(f"  pyrealsense2 unavailable: {exc}")
devs = list(rs.context().query_devices())
if not devs:
    sys.exit("  no devices (check the udev rule and that the attach above succeeded)")
for d in devs:
    name = d.get_info(rs.camera_info.name)
    serial = d.get_info(rs.camera_info.serial_number)
    fw = d.get_info(rs.camera_info.firmware_version)
    usb = d.get_info(rs.camera_info.usb_type_descriptor)
    print(f"  {name}  sn={serial}  fw={fw}  usb={usb}")
    if usb.startswith("2."):
        print("  WARNING: USB 2 link; the default 1280x720@30 colour mode needs USB 3.")
        print("  Use a SuperSpeed-capable cable and port, preferably directly on the laptop.")
print("  Enumeration passed; verify frames with cam_record.py realsense --probe.")
PY
else
  echo "[realsense] $PY not built yet; run scripts/setup-vision.sh to verify"
fi
