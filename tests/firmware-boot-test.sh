#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Prove a grml-debootstrap VM image boots under all three amd64 firmware modes:
#   - BIOS (SeaBIOS)
#   - UEFI (OVMF)
#   - UEFI + Secure Boot (OVMF, Microsoft keys pre-enrolled)
#
# Builds ONE EFI-capable image (GPT + ESP + bios_grub, grub-cloud + signed
# shim/grub via VMEFI=1) and boots it once per firmware, reusing the serial-login +
# goss check of tests/test-vm.sh. Fails if any firmware fails to reach a working
# login. amd64 only (arm64 is UEFI-only and already covered by the normal VM test).
#
# Usage: tests/firmware-boot-test.sh
# Env:
#   RELEASE    Debian release to install (default: trixie)
#   QEMU_IMG   image filename          (default: firmware.img)

set -eu -o pipefail

RELEASE="${RELEASE:-trixie}"
QEMU_IMG="${QEMU_IMG:-firmware.img}"
export RELEASE QEMU_IMG

arch="$(dpkg --print-architecture)"
if [ "$arch" != 'amd64' ]; then
  echo "firmware-boot-test: only amd64 is multi-firmware; arch is '$arch', nothing to do."
  exit 0
fi

# UEFI Secure Boot under TCG (no KVM: SMM + signature verification) reaches the login
# prompt well past the 180s default; give every firmware leg a generous boot budget.
export SERIAL_TIMEOUT="${SERIAL_TIMEOUT:-600}"

here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"

echo "== firmware-boot-test: building EFI-capable image (${RELEASE}, ${QEMU_IMG}) =="
VMEFI=1 TARGET=VM ./tests/build-vm-and-test.sh run

firmwares=(bios efi efi-secureboot)
declare -A result
overall=0

for fw in "${firmwares[@]}"; do
  echo "== firmware-boot-test: booting under '${fw}' =="
  rc=0
  FIRMWARE="$fw" ./tests/test-vm.sh "$PWD/$QEMU_IMG" "$RELEASE" VM || rc=$?
  if [ "$rc" -eq 0 ]; then
    result[$fw]='PASS'
  else
    result[$fw]="FAIL (rc=$rc)"
    overall=1
  fi
  # Preserve this firmware's goss report before the next run overwrites it.
  if [ -f tests/results/goss.tap ]; then
    cp tests/results/goss.tap "tests/results/goss-${fw}.tap" || true
  fi
done

echo "== firmware-boot-test summary (${RELEASE}, amd64) =="
for fw in "${firmwares[@]}"; do
  printf '  %-16s %s\n' "$fw" "${result[$fw]}"
done

if [ "$overall" -ne 0 ]; then
  echo "firmware-boot-test: at least one firmware failed to boot." >&2
fi
exit "$overall"

# EOF
