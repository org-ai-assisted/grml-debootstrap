#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Prove that grml-debootstrap builds a bit-for-bit reproducible VM image: build the SAME image
# twice, independently, with deterministic inputs (a fixed SOURCE_DATE_EPOCH and
# FIXED_DISK_IDENTIFIERS=yes), then compare the two raw images.
#
# Exit 0 if the two images are byte-identical (reproducible); 1 if they differ (a diffoscope
# report is written to reproducible-report.txt); 2 on a setup error.
#
# Usage: tests/reproducible-build.sh
# Env:
#   RELEASE            Debian release to install into the image   (default: trixie)
#   TARGET             VM or RPI                                   (default: VM)
#   HOST_RELEASE       Debian release grml-debootstrap runs on    (default: trixie)
#   SOURCE_DATE_EPOCH  fixed build timestamp, identical for both  (default: 1767225600)

set -eu -o pipefail

export RELEASE="${RELEASE:-trixie}"
export TARGET="${TARGET:-VM}"
export HOST_RELEASE="${HOST_RELEASE:-trixie}"
# A fixed epoch so both builds -- and re-runs on another day or host -- use identical timestamps.
# 2026-01-01T00:00:00Z; any constant works, it only has to be the same for both builds.
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1767225600}"
# Deterministic MBR/GPT/partition IDs and filesystem UUID (grml PR #380 mechanism).
export FIXED_DISK_IDENTIFIERS=yes

here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"

img_a='repro-image-a.img'
img_b='repro-image-b.img'

echo "== reproducible-build: image A (SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}, FIXED_DISK_IDENTIFIERS=yes, ${RELEASE}/${TARGET}) =="
QEMU_IMG="$img_a" ./tests/build-vm-and-test.sh run

echo "== reproducible-build: image B (independent rebuild, same inputs) =="
QEMU_IMG="$img_b" ./tests/build-vm-and-test.sh run

sha_a="$(sha256sum "$img_a" | awk '{print $1}')"
sha_b="$(sha256sum "$img_b" | awk '{print $1}')"
echo "A: ${sha_a}  ${img_a}"
echo "B: ${sha_b}  ${img_b}"

if [ "$sha_a" = "$sha_b" ]; then
  echo 'RESULT: identical -- grml-debootstrap VM image is bit-for-bit reproducible.'
  exit 0
fi

echo 'RESULT: images DIFFER -- not reproducible. Localizing the difference with diffoscope.' >&2
sudo apt-get -qq -y install diffoscope >/dev/null 2>&1 || true
if command -v diffoscope >/dev/null ; then
  diffoscope "$img_a" "$img_b" --text reproducible-report.txt || true
  echo 'diffoscope report written to reproducible-report.txt' >&2
fi
exit 1
