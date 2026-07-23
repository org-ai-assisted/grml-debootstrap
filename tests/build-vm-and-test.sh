#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Install an already built grml-debootstrap.deb in docker and use it to
# build a test VM image. Then run this VM image in qemu and check if it
# boots.

set -eu -o pipefail

usage() {
  echo "Usage: $0 setup"
  echo " then: $0 run"
  echo " then: $0 test"
  echo "WARNING: $0 is potentially dangerous and may destroy the host system and/or any data."
  exit 0
}

if [ "${1:-}" == "--help" ] || [ "${1:-}" == "help" ]; then
  usage
fi

if [ -z "${1:-}" ]; then
  echo "$0: unknown parameters, see --help" >&2
  exit 1
fi

set -x

if [ ! -d ./tests ]; then
  echo "$0: Started from incorrect working directory" >&2
  exit 1
fi

if [ "$1" == "setup" ]; then
  sudo apt-get update
  sudo apt-get -qq -y install curl kpartx python3-serial
  DPKG_ARCHITECTURE=$(dpkg --print-architecture)
  if [ "${DPKG_ARCHITECTURE}" = "amd64" ]; then
    sudo apt-get -qq -y install qemu-system qemu-system-gui ovmf seabios
  elif [ "${DPKG_ARCHITECTURE}" = "arm64" ]; then
    sudo apt-get -qq -y install qemu-system qemu-system-gui qemu-efi-aarch64
  fi
  # vncsnapshot might not be available, though we don't want to abort execution then
  sudo apt-get -qq -y install vncsnapshot || true
  # Fetch goss directly from its GitHub release. The goss.rocks/install script
  # builds a non-existent 'goss_<ver>_linux_x86_64.tar.gz' URL (goss ships bare
  # 'goss-linux-<arch>' binaries), so it 404s and tar aborts. Pin the version,
  # pick the runner's architecture, and verify the published sha256.
  if [ ! -x ./tests/goss ]; then
    goss_ver='v0.4.9'
    goss_arch="$(dpkg --print-architecture)"
    goss_url="https://github.com/goss-org/goss/releases/download/${goss_ver}/goss-linux-${goss_arch}"
    curl -fsSL -o ./tests/goss "${goss_url}"
    goss_sha="$(curl -fsSL "${goss_url}.sha256" | awk '{print $1}')"
    echo "${goss_sha}  ./tests/goss" | sha256sum -c -
    chmod +x ./tests/goss
  fi
  # TODO: docker.io
  exit 0
fi

# Debian version to install using grml-debootstrap
RELEASE="${RELEASE:-trixie}"

TARGET="${TARGET:-no}"

QEMU_IMG="${QEMU_IMG:-qemu.img}"

if [ "$1" == "run" ]; then
  # Debian version on which grml-debootstrap will *run*
  HOST_RELEASE="${HOST_RELEASE:-trixie}"

  DEB_NAME=$(ls ./grml-debootstrap*.deb || true)
  if [ -z "$DEB_NAME" ]; then
    echo "$0: No grml-debootstrap*.deb found, aborting" >&2
    exit 1
  fi

  # we need to run in privileged mode to be able to use loop devices
  # SOURCE_DATE_EPOCH and FIXED_DISK_IDENTIFIERS are passed through so a reproducibility build
  # (tests/reproducible-build.sh) can request deterministic timestamps and disk/fs identifiers;
  # both are unset in a normal test-build, leaving behaviour unchanged.
  exec docker run --privileged --rm -i \
    -v "$(pwd)":/code \
    -e TERM="$TERM" \
    -e SOURCE_DATE_EPOCH \
    -e FIXED_DISK_IDENTIFIERS \
    -w /code \
    debian:"$HOST_RELEASE" \
    bash -c './tests/docker-install-deb.sh '"$DEB_NAME"' && ./tests/docker-build-vm.sh '"$(id -u)"' '"/code/$QEMU_IMG"' '"$RELEASE"' '"$TARGET"

elif [ "$1" == "test" ]; then
  # run tests from inside Debian system
  exec ./tests/test-vm.sh "$PWD/$QEMU_IMG" "$RELEASE" "$TARGET"

else
  echo "$0: unknown parameters, see --help" >&2
  exit 1
fi

# EOF
