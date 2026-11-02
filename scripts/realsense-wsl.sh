#!/usr/bin/env bash
# Attach the Intel RealSense D455 to WSL2 on LEGION_A.
#
# The D455 is a USB 3.0 device. WSL2 has no direct USB access, so it is
# forwarded with usbipd-win:
#
#   Windows  usbipd-win  ->  USB/IP  ->  WSL2 vhci-hcd  ->  /dev/videoN
#
# One-time prerequisite (elevated PowerShell, run once):
#   usbipd bind --busid 1-6
#
# After that, re-attaching after a reboot / unplug does NOT need admin:
#   bash scripts/realsense-wsl.sh
#
# Usage:
#   bash scripts/realsense-wsl.sh [busid]     # default 1-6
#
# Run this from INSIDE WSL. Nothing on the robot is touched.
set -uo pipefail

BUSID="${1:-1-6}"
USBIPD="/mnt/c/Program Files/usbipd-win/usbipd.exe"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ ! -x "$USBIPD" ]; then
  echo "[realsense] usbipd-win is not installed on the Windows host."
  echo "            winget install --id dorssel.usbipd-win -e"
  exit 1
fi

# librealsense talks to /dev/bus/usb directly, so the node has to be readable
# by the login user. Intel's own rules use MODE 0666 for their PIDs; without a
# rule the node is root-owned and pyrealsense2 fails with "permission denied".
install_udev() {
  local rules=/etc/udev/rules.d/99-realsense-libusb.rules
  [ -f "$rules" ] && return 0
  echo "[realsense] installing udev rule $rules"
  sudo tee "$rules" >/dev/null <<'EOF'
# Intel RealSense -- librealsense needs raw USB access.
SUBSYSTEM=="usb", ATTRS{idVendor}=="8086", MODE:="0666", GROUP:="plugdev"
EOF
  sudo udevadm control --reload-rules 2>/dev/null || true
  sudo udevadm trigger --subsystem-match=usb 2>/dev/null || true
}
install_udev

echo "[realsense] usbipd-win: $("$USBIPD" --version 2>/dev/null | head -1)"

line="$("$USBIPD" list 2>/dev/null | grep -E "^[[:space:]]*${BUSID}[[:space:]]")"
if [ -z "$line" ]; then
  echo "[realsense] busid $BUSID not found. Current devices:"
  "$USBIPD" list
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

# The node list is not proof: librealsense talks to /dev/bus/usb through its own
# backend and a depth camera exposes several /dev/videoN nodes of which video0
# is a depth node. Only pyrealsense2 can say whether a camera is really there.
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
PY
else
  echo "[realsense] $PY not built yet; run scripts/setup-vision.sh to verify"
fi
