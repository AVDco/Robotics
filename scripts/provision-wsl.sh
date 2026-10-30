#!/usr/bin/env bash
# Reproduce the toolchain for this workspace on a fresh Ubuntu 22.04 (WSL) distro.
# Run as root:  sudo ./scripts/provision-wsl.sh
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }

echo "==> base packages"
apt-get update -y
apt-get install -y --no-install-recommends \
  build-essential cmake git curl wget ca-certificates unzip tar pkg-config \
  lsb-release software-properties-common gnupg locales sudo vim less \
  python3-pip python3-dev python3-venv python3-numpy python3-yaml \
  libyaml-cpp-dev libeigen3-dev libboost-all-dev libfmt-dev \
  libmsgpack-dev pybind11-dev iproute2 net-tools iputils-ping can-utils

echo "==> CycloneDDS 0.10.x -> /opt/cyclonedds"
if [ ! -d /opt/cyclonedds ]; then
  git clone -b releases/0.10.x --depth 1 https://github.com/eclipse-cyclonedds/cyclonedds.git /opt/cyclonedds-src
  cmake -S /opt/cyclonedds-src -B /opt/cyclonedds-src/build \
        -DCMAKE_INSTALL_PREFIX=/opt/cyclonedds -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF
  cmake --build /opt/cyclonedds-src/build --target install -j"$(nproc)"
fi

echo "==> ROS 2 Humble"
curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key -o /usr/share/keyrings/ros-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2/ubuntu $(. /etc/os-release && echo "$UBUNTU_CODENAME") main" \
  > /etc/apt/sources.list.d/ros2.list
apt-get update -y
apt-get install -y --no-install-recommends \
  ros-humble-desktop ros-humble-rmw-cyclonedds-cpp ros-humble-rosidl-generator-dds-idl \
  python3-colcon-common-extensions python3-rosdep python3-argcomplete

echo "==> environment"
cat > /etc/profile.d/unitree-env.sh <<'EOF'
export CYCLONEDDS_HOME=/opt/cyclonedds
export CMAKE_PREFIX_PATH="/opt/cyclonedds:/opt/unitree_robotics:${CMAKE_PREFIX_PATH:-}"
export LD_LIBRARY_PATH="/opt/cyclonedds/lib:/opt/unitree_robotics/lib:${LD_LIBRARY_PATH:-}"
EOF
cat > /etc/profile.d/ros2-env.sh <<'EOF'
if [ -f /opt/ros/humble/setup.bash ]; then source /opt/ros/humble/setup.bash; fi
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
EOF

echo "==> Rust (for the current non-root user)"
sudo -u "${SUDO_USER:-aidyn}" bash -lc \
  "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable"

echo "==> done. Open a new shell (or 'source /etc/profile.d/*.sh')."
