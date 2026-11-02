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

# The Astro_dog projects were previously absent from this script, so a fresh
# clone built every upstream SDK and none of the code we actually run. Each one
# vendors ../unitree_sdk2 and has offline CTest suites; run them so "all builds
# finished" also means "the harnesses are green".
astro_build () {
  local name="$1" dir="$2"
  step "$name"
  # Astro_dog's projects add_subdirectory("../unitree_sdk2"), which is the robot
  # layout (~/AstroDog/{unitree_sdk2,...}). In this workspace the SDK is a
  # sibling of Astro_dog, so point them at it explicitly.
  cmake -S "$dir" -B "$dir/build" -DCMAKE_BUILD_TYPE=Release \
        -DASTRO_SDK_DIR="$ROOT/unitree_sdk2"
  cmake --build "$dir/build" -j"$JOBS"
  (cd "$dir/build" && ctest --output-on-failure)
}

astro_build "Astro_dog/voice_commander" "$ROOT/Astro_dog/voice_commander"
astro_build "Astro_dog/lidar_follow"    "$ROOT/Astro_dog/lidar_follow"
astro_build "Astro_dog/dance_project"   "$ROOT/Astro_dog/dance_project"

printf '\n\033[1;32mAll builds finished.\033[0m\n'
