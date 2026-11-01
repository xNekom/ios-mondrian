#!/usr/bin/env bash
# System packages for the Linux XNU toolchain (Ubuntu 24.04 / WSL2).
#
#   sudo tools/wsl/apt-deps.sh
#
# Only the toolchain needs these; the kernel build itself runs as your user.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
	build-essential clang lld llvm cmake ninja-build git python3 python3-venv \
	flex bison autoconf automake libtool pkg-config tcsh unifdef \
	7zip unzip curl ca-certificates xz-utils file ruby \
	uuid-dev libssl-dev zlib1g-dev libblocksruntime-dev libbsd-dev \
	libncurses-dev libedit-dev libxml2-dev
echo "== installed: $(clang --version | head -1)"
