# Unitree Robotics — Local Development Project

Local workspace for Unitree robot SDKs, cloned from <https://github.com/unitreerobotics>.
All upstream code lives in git submodules; this repo tracks the pinned commits plus the
setup/build tooling for this machine.

## Contents

| Path | Upstream | Purpose |
|---|---|---|
| `unitree_sdk2/` | [unitree_sdk2](https://github.com/unitreerobotics/unitree_sdk2) | C++ SDK v2 (DDS / CycloneDDS) — current gen: Go2, B2, G1, H1, H2, R1 |
| `unitree_sdk2_python/` | [unitree_sdk2_python](https://github.com/unitreerobotics/unitree_sdk2_python) | Python bindings for SDK2 |
| `unitree_sdk2_rs/` | [unitree_sdk2_rs](https://github.com/unitreerobotics/unitree_sdk2_rs) | Rust bindings (cxx bridge over SDK2) |
| `unitree_legged_sdk/` | [unitree_legged_sdk](https://github.com/unitreerobotics/unitree_legged_sdk) | Legacy SDK (branch `go1`), UDP based |
| `unitree_ros/` | [unitree_ros](https://github.com/unitreerobotics/unitree_ros) | ROS 1 models, Gazebo sim, controllers |
| `unitree_ros2/` | [unitree_ros2](https://github.com/unitreerobotics/unitree_ros2) | ROS 2 (`unitree_go`, `unitree_api`, `unitree_hg`) + examples |
| `Astro_dog/` | [Astro_dog](https://github.com/mr2urboclaude-ops/Astro_dog) | Robot application stack: voice commander, LiDAR follow, vision/face ID, dock services |

## Environment

Everything runs inside **WSL2 → Ubuntu 22.04** (the SDKs are Linux-only).

| Component | Version | Location |
|---|---|---|
| Ubuntu | 22.04.5 LTS (WSL 3.0.3, kernel 6.18) | `wsl -d Ubuntu-22.04` |
| GCC / G++ | 11.4.0 | system |
| CMake | 3.22.1 | system |
| Python | 3.10.12 | system |
| CycloneDDS | 0.10.5 (`releases/0.10.x`) | `/opt/cyclonedds` |
| unitree_sdk2 (C++) | 2.0.0 | `/opt/unitree_robotics` |
| ROS 2 | Humble + `rmw_cyclonedds_cpp` | `/opt/ros/humble` |
| Rust | 1.99.1 | `~/.cargo` |

WSL user `aidyn` (password `unitree`), passwordless sudo. Repos are reachable from WSL at
`/mnt/c/Robotics`.

Environment variables are set globally by `/etc/profile.d/unitree-env.sh` and
`/etc/profile.d/ros2-env.sh`:

```bash
CYCLONEDDS_HOME=/opt/cyclonedds
CMAKE_PREFIX_PATH=/opt/cyclonedds:/opt/unitree_robotics
LD_LIBRARY_PATH=/opt/cyclonedds/lib:/opt/unitree_robotics/lib
RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
```

## This laptop — LEGION_A

| | |
|---|---|
| Machine | Lenovo Legion 5 16IAX10 (83NX) |
| CPU / RAM | Intel Core Ultra 9 275HX (24C/24T) / 32 GB |
| GPU | NVIDIA RTX 5060 Laptop 8 GB (Blackwell, sm_120) + Intel iGPU |
| Disk | WD SN7100S 1 TB |
| OS | Windows 11 Home 26200 + WSL2 Ubuntu 22.04.5 |
| Camera | **Intel RealSense D455** (`8086:0b5c`), USB 3.0 root hub port 6 |

### Camera — D455 into WSL2

WSL2 cannot see USB devices directly, so the D455 is forwarded with
**usbipd-win** (`C:\Program Files\usbipd-win`). One-time, in an **elevated**
PowerShell:

```powershell
& "C:\Program Files\usbipd-win\usbipd.exe" bind --busid 1-6
```

After every reboot or re-plug (no admin needed), from WSL:

```bash
bash scripts/realsense-wsl.sh      # attaches busid 1-6 and loads vhci-hcd
```

The busid is not stable across USB ports. If `1-6` stops resolving, run
`usbipd list` on Windows and match on `8086:0b5c`.

### Vision default camera

`Astro_dog/vision/laptops.json` maps hostname → camera. `LEGION_A` resolves to:

```
RealSense first device 1280x720@30fps HFOV 87deg
```

so the vision tools need no arguments:

```bash
cd /mnt/c/Robotics/Astro_dog/vision
.venv/bin/python cam_record.py realsense --probe
.venv/bin/python identity_live.py                 # http://localhost:8099/
```

Build that venv from scratch (idempotent, ~6.7 GB) with:

```bash
bash scripts/setup-vision.sh
```

It ends by creating a real CUDA `InferenceSession` and failing loudly if the
RTX 5060 is not actually used — the provider list alone is not proof.

`--camera` still accepts `realsense[:serial]`, `usb:/dev/videoN`, or a device
index, and `$ASTRO_VISION_CAMERA` overrides the profile for one shell.

## Build

From a WSL shell:

```bash
wsl -d Ubuntu-22.04            # or: wsl -d Ubuntu-22.04 -u aidyn
cd /mnt/c/Robotics
bash scripts/build-all.sh       # rebuild everything
# (use `bash` — the exec bit is not preserved on /mnt/c DrvFs)
```

Individual targets:

```bash
# C++ SDK v2  -> installs to /opt/unitree_robotics
cd unitree_sdk2 && cmake -B build -DCMAKE_INSTALL_PREFIX=/opt/unitree_robotics \
  && cmake --build build -j"$(nproc)" && sudo cmake --install build

# Legacy Go1 SDK  (prebuilt static lib is non-PIE -> -no-pie is required)
cd unitree_legged_sdk && cmake -B build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_EXE_LINKER_FLAGS=-no-pie && cmake --build build -j"$(nproc)"

# Python bindings
cd unitree_sdk2_python && CYCLONEDDS_HOME=/opt/cyclonedds python3 -m pip install -e .

# Rust (uses the local C++ SDK instead of re-cloning it)
cd unitree_sdk2_rs && UNITREE_SDK2_PATH=/mnt/c/Robotics/unitree_sdk2 \
  ~/.cargo/bin/cargo build --release --examples

# ROS 2 messages + examples
source /opt/ros/humble/setup.bash
cd unitree_ros2/cyclonedds_ws && colcon build --symlink-install
source install/setup.bash
cd ../example && colcon build --symlink-install
```

## Run / verify

```bash
# Python smoke test
python3 -c "from unitree_sdk2py.core.channel import ChannelFactoryInitialize; print('ok')"

# DDS loopback (no robot needed) — two terminals
cd unitree_sdk2_python && python3 ./example/helloworld/publisher.py
cd unitree_sdk2_python && python3 ./example/helloworld/subscriber.py

# ROS 2 with a real robot
source ~/unitree_ros2/setup.sh   # edit the interface name first
ros2 topic list
```

## Connecting to a robot

1. Wired Ethernet between PC and robot; set that NIC to `192.168.123.99 / 255.255.255.0`.
2. Find the interface name (`ip a`), e.g. `eth0` / `enp3s0`.
3. Pass it to the SDK (`ChannelFactoryInitialize(0, "eth0")`) or set `CYCLONEDDS_URI`
   with `<NetworkInterface name="eth0" .../>`. Use `lo` for simulation/loopback.

## Known issues

- **`unitree_legged_sdk` link error** (`relocation R_X86_64_PC32 ... making a PIE object`):
  the shipped `lib/cpp/amd64/libunitree_legged_sdk.a` is non-PIE. Configure with
  `-DCMAKE_EXE_LINKER_FLAGS=-no-pie` (already handled in `scripts/build-all.sh`).
- **`unitree_ros` (ROS 1)** needs ROS Noetic/Melodic + Gazebo Classic, which are not
  available on Ubuntu 22.04. Not built here — requires Ubuntu 20.04 WSL, Docker, or
  RoboStack. Models/URDFs are still usable from this checkout.
- **ROS 2 examples** must be built *after* sourcing
  `unitree_ros2/cyclonedds_ws/install/setup.bash`, otherwise `find_package(unitree_go)` fails.
- Builds happen on `/mnt/c` (DrvFs) — functional but slower than the Linux filesystem.
- `unitree_sdk2_rs/build.rs` regenerates `gen/gen_topics.inc` on every build, which shows
  the submodule as dirty; `git -C unitree_sdk2_rs checkout -- gen/gen_topics.inc` resets it.
- WSL user password is `unitree`; change it with `passwd` inside WSL.

## Updating upstream code

```bash
git submodule update --remote --merge    # pull latest for all SDKs
bash scripts/build-all.sh
```

## Provisioning

`scripts/provision-wsl.sh` reproduces the full toolchain install (apt packages,
CycloneDDS, ROS 2 Humble, Rust) on a fresh Ubuntu 22.04 WSL distro.
