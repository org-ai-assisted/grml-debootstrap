#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Prove that grml-debootstrap builds a bit-for-bit reproducible VM image: build the SAME image
# twice, independently, with a deterministic input (a fixed SOURCE_DATE_EPOCH, the sole
# reproducible-build switch), then compare the two raw images.
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

here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"

img_a='repro-image-a.img'
img_b='repro-image-b.img'

# Exit codes: 0 reproducible, 1 completed comparison that differs, 2 setup/build error.
# A failed build cannot be compared, so it is a setup error (2), not a mismatch (1).
build_image() {
  echo "== reproducible-build: building '$1' (SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}, ${RELEASE}/${TARGET}) =="
  if ! QEMU_IMG="$1" ./tests/build-vm-and-test.sh run; then
    echo "reproducible-build: building '$1' failed -- setup/build error, not a reproducibility result." >&2
    exit 2
  fi
}
build_image "$img_a"
build_image "$img_b"

if ! sha_a="$(sha256sum "$img_a" | awk '{print $1}')" \
  || ! sha_b="$(sha256sum "$img_b" | awk '{print $1}')"; then
  echo "reproducible-build: hashing the built images failed (setup error)." >&2
  exit 2
fi
echo "A: ${sha_a}  ${img_a}"
echo "B: ${sha_b}  ${img_b}"

if [ "$sha_a" = "$sha_b" ]; then
  echo 'RESULT: identical -- grml-debootstrap VM image is bit-for-bit reproducible.'
  exit 0
fi

echo 'RESULT: images DIFFER -- not reproducible. Localizing with diffoscope.' >&2

report='reproducible-report.txt'
rm -f "$report"

# diffoscope unpacks the raw images itself -- the partition table plus the ext4 root
# filesystem (via libguestfs) -- and produces a recursive, format-aware per-file diff,
# so no manual loop-mount is needed (and nothing to leak). Run the STREAMING diffoscope
# from trixie-backports: trixie ships 297, which OOMs on a large DIFFERING member of
# multi-GB images, whereas >= 302 streams the diff (diffoscope salsa issue #342). It
# runs inside a debian:trixie --privileged container because backports is Debian-only
# and libguestfs needs privileges + LIBGUESTFS_BACKEND=direct to launch its (KVM-less,
# TCG) appliance. Bound the diff and keep the temp dir on real disk (TMPDIR=/var/tmp).
# Diagnostic only: on any failure the script still exits 1 (the images differ) with
# whatever report was produced.
arch="$(dpkg --print-architecture)"
docker run --privileged --rm -v "$(pwd)":/code -w /code debian:trixie bash -c '
  set -eu
  echo "deb http://deb.debian.org/debian trixie-backports main" \
    > /etc/apt/sources.list.d/trixie-backports.list
  apt-get update -qq
  apt-get install --yes --no-install-recommends -t trixie-backports diffoscope
  # Format descenders diffoscope needs to fully localize a grml root filesystem
  # (diffoscope only WARNs on a missing one, so this list degrades gracefully):
  #   - libguestfs-tools + a kernel: descend the raw disk image -> partitions -> the
  #     ext4 root and the FAT ESP (the fs layer; the core of the diff).
  #   - fakeroot: compare ownership / device nodes.
  #   - binutils: readable ELF diffs for differing binaries (else a raw hexdump).
  #   - xz-utils, zstd, gzip: transparently diff compressed members (man pages,
  #     kernel modules) instead of reporting the whole compressed blob.
  #   - xxd: hexdump fallback for any remaining binary member.
  apt-get install --yes --no-install-recommends \
    libguestfs-tools "linux-image-'"$arch"'" \
    fakeroot binutils xz-utils zstd gzip xxd
  export LIBGUESTFS_BACKEND=direct TMPDIR=/var/tmp
  drc=0
  diffoscope \
    --max-diff-input-lines 100000 --max-diff-block-lines-saved 10000 \
    --exclude "boot/initrd*" --exclude "boot/vmlinuz*" \
    --text "/code/'"$report"'" "/code/'"$img_a"'" "/code/'"$img_b"'" || drc=$?
  # diffoscope exits 0 (identical) or 1 (differ, report written); >1 is a real error.
  [ "$drc" -le 1 ] || { echo "diffoscope error (rc=$drc)" >&2; exit "$drc"; }
' || echo "diffoscope did not complete cleanly (see ${report} if present)." >&2

echo "--- ${report} ---" >&2
if [ -f "$report" ]; then
  cat "$report" >&2
else
  echo "(no diffoscope report was produced)" >&2
fi
exit 1
