#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Install an already built grml-debootstrap.deb in docker and use it to
# build a test VM image. Then run this VM image in qemu and check if it
# boots.
GOSS_VER="0.4.9"

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

# A SOURCE_DATE_EPOCH exported as an EMPTY string breaks tools that read it:
# dosfstools' mkfs.fat rejects "" ("SOURCE_DATE_EPOCH is too big or contains
# non-digits") and aborts ESP creation, so every EFI/arm64 VM and RPI leg fails,
# while mke2fs treats "" as unset and masks the problem on amd64 BIOS VMs. The
# reproducible-builds convention is unset-or-valid-integer, never empty, so a
# non-reproducible leg must UNSET it rather than pass an empty value through.
if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
  unset SOURCE_DATE_EPOCH
fi

if [ "$1" == "setup" ]; then
  # DPkg::Lock::Timeout: a CI runner's own unattended-upgrades/apt-daily timer
  # can hold /var/lib/dpkg/lock-frontend, and apt waits for it forever by
  # default. That wedged this step twice, for over an hour once, against a
  # normal runtime of well under a minute. Bounded, it fails loudly instead.
  apt_get=(sudo apt-get -o DPkg::Lock::Timeout=180)
  "${apt_get[@]}" update
  "${apt_get[@]}" -qq -y install curl kpartx python3-serial
  DPKG_ARCHITECTURE=$(dpkg --print-architecture)
  if [ "${DPKG_ARCHITECTURE}" = "amd64" ]; then
    "${apt_get[@]}" -qq -y install qemu-system qemu-system-gui ovmf seabios
  elif [ "${DPKG_ARCHITECTURE}" = "arm64" ]; then
    "${apt_get[@]}" -qq -y install qemu-system qemu-system-gui qemu-efi-aarch64
  fi
  # vncsnapshot might not be available, though we don't want to abort execution then
  "${apt_get[@]}" -qq -y install vncsnapshot || true
  # Fetch goss directly from its GitHub release. The goss.rocks/install script
  # builds a non-existent 'goss_<ver>_linux_x86_64.tar.gz' URL (goss ships bare
  # 'goss-linux-<arch>' binaries), so it 404s and tar aborts. Pin the version,
  # pick the runner's architecture, and verify the published sha256.
  if [ ! -x ./tests/goss ]; then
    goss_ver="v${GOSS_VER}"
    goss_arch="$(dpkg --print-architecture)"
    # Pinned, reviewed sha256 per architecture. Do NOT fetch the checksum from the
    # same release -- a tampered release could replace both the binary and its
    # published .sha256 and still pass the check.
    case "$goss_arch" in
      amd64) goss_sha='87dd36cfa1b8b50554e6e2ca29168272e26755b19ba5438341f7c66b36decc19' ;;
      arm64) goss_sha='14fd24ac08236559f4809e6a627792d1b947ed98654bba1662ef1d6122d77e18' ;;
      *) echo "$0: no pinned goss checksum for architecture '$goss_arch'" >&2 ; exit 1 ;;
    esac
    # --max-time: a stalled connection would otherwise hang the setup step
    # indefinitely, and nothing else in it carries a network timeout either.
    curl -fsSL --max-time 300 -o ./tests/goss \
      "https://github.com/goss-org/goss/releases/download/${goss_ver}/goss-linux-${goss_arch}"
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
  # SOURCE_DATE_EPOCH is passed through so a reproducibility build
  # (tests/reproducible-build.sh) can request a deterministic build; it is the sole
  # reproducible-build switch and is unset in a normal test-build, leaving behaviour
  # unchanged.
  # Opt-in local apt cache: set APT_CACHE_MIRROR to a caching mirror (e.g. an approx or
  # apt-cacher-ng URL) to speed up repeated local builds. It is passed through as MIRROR
  # and the container joins the host network so it can reach a cache on the host. Unset
  # (CI, normal runs) -> default bridge network + the built-in mirror, behaviour unchanged.
  # A reproducible build deliberately ignores MIRROR and installs from
  # SNAPSHOT_ARCHIVE instead, so APT_CACHE_MIRROR alone does nothing for the
  # reproducible legs. Two further opt-in knobs keep a local cache usable there:
  #   APT_CACHE_SNAPSHOT_ARCHIVE  a caching mirror or caching reverse proxy for
  #                               the snapshot archive, used as SNAPSHOT_ARCHIVE
  #   APT_PROXY                   a caching HTTP proxy (apt-cacher-ng, squid).
  #                               Needs an http:// SNAPSHOT_ARCHIVE to be able to
  #                               cache: https is tunnelled, not cached.
  # All are unset in CI, leaving those runs on the public archives as before.
  docker_extra=()
  if [ -n "${APT_CACHE_MIRROR:-}" ] || [ -n "${APT_CACHE_SNAPSHOT_ARCHIVE:-}" ] \
    || [ -n "${APT_PROXY:-}" ]; then
    docker_extra+=(--network host)
  fi
  if [ -n "${APT_CACHE_SNAPSHOT_ARCHIVE:-}" ]; then
    docker_extra+=(-e SNAPSHOT_ARCHIVE="$APT_CACHE_SNAPSHOT_ARCHIVE")
  fi
  if [ -n "${APT_PROXY:-}" ]; then
    # grml-debootstrap forwards these into the chroot for the in-chroot apt runs,
    # and mmdebstrap picks them up from this environment on the host side.
    docker_extra+=(-e http_proxy="$APT_PROXY" -e https_proxy="$APT_PROXY")
  fi
  exec docker run --privileged --rm -i \
    "${docker_extra[@]}" \
    -v "$(pwd)":/code \
    -e TERM="$TERM" \
    -e SOURCE_DATE_EPOCH \
    -e VMEFI \
    -e MIRROR="${APT_CACHE_MIRROR:-}" \
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
