#!/usr/bin/env bash
# Rebuild every Unitree SDK in this workspace. Run inside WSL (Ubuntu 22.04).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export CYCLONEDDS_HOME=/opt/cyclonedds
export CMAKE_PREFIX_PATH="/opt/cyclonedds:/opt/unitree_robotics:${CMAKE_PREFIX_PATH:-}"
export LD_LIBRARY_PATH="/opt/cyclonedds/lib:/opt/unitree_robotics/lib:${LD_LIBRARY_PATH:-}"
JOBS="$(nproc)"

step () { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

step "unitree_sdk2 (C++)"
cmake -S "$ROOT/unitree_sdk2" -B "$ROOT/unitree_sdk2/build" \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt/unitree_robotics
cmake --build "$ROOT/unitree_sdk2/build" -j"$JOBS"
sudo cmake --install "$ROOT/unitree_sdk2/build"

step "unitree_legged_sdk (legacy, non-PIE static lib)"
cmake -S "$ROOT/unitree_legged_sdk" -B "$ROOT/unitree_legged_sdk/build" \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXE_LINKER_FLAGS=-no-pie
cmake --build "$ROOT/unitree_legged_sdk/build" -j"$JOBS"

step "unitree_sdk2_python"
(cd "$ROOT/unitree_sdk2_python" && CYCLONEDDS_HOME=/opt/cyclonedds python3 -m pip install -e .)

step "unitree_sdk2_rs"
(cd "$ROOT/unitree_sdk2_rs" \
  && UNITREE_SDK2_PATH="$ROOT/unitree_sdk2" "$HOME/.cargo/bin/cargo" build --release --examples)

step "unitree_ros2 (messages)"
# shellcheck disable=SC1091
source /opt/ros/humble/setup.bash
(cd "$ROOT/unitree_ros2/cyclonedds_ws" && colcon build --symlink-install)

step "unitree_ros2 (examples)"
# shellcheck disable=SC1091
source "$ROOT/unitree_ros2/cyclonedds_ws/install/setup.bash"
(cd "$ROOT/unitree_ros2/example" && colcon build --symlink-install)

printf '\n\033[1;32mAll builds finished.\033[0m\n'
