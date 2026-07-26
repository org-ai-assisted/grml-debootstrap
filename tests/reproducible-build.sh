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

echo 'RESULT: images DIFFER -- not reproducible. Localizing the difference.' >&2

# Diagnostics only from here: diff/cmp exit non-zero on an expected difference, so do not let
# errexit abort before the report is written.
set +e

# The raw images are multi-GB, so diffoscope over them is impractical; instead pinpoint the
# difference structurally: the raw byte offset, the partition table, then -- most usefully -- the
# root filesystem's file contents and mtimes (the latter is the usual remaining reproducibility
# gap: a package maintainer script that stamps a file with the wall-clock build time).
report='reproducible-report.txt'
{
  echo "A sha256: ${sha_a}"
  echo "B sha256: ${sha_b}"
  echo
  echo '=== first differing byte (cmp) ==='
  cmp "$img_a" "$img_b" || true
  # Cap the byte enumeration: on a broad regression cmp -l would emit one line per
  # differing byte across multi-GB images (billions of lines, hours). head closes
  # the pipe early, so cmp stops at the cap.
  cap=100000
  n="$(cmp -l "$img_a" "$img_b" 2>/dev/null | head -n "$cap" | wc -l)"
  [ "$n" -ge "$cap" ] && echo "differing byte count: >= ${cap} (capped)" \
                      || echo "differing byte count: ${n}"
  echo
  echo '=== partition table diff (sfdisk -d) ==='
  diff <(sfdisk -d "$img_a" 2>/dev/null) <(sfdisk -d "$img_b" 2>/dev/null) || true
} > "$report" 2>&1

# Register cleanup BEFORE allocating loop devices / mounts, so a failure part-way
# through (e.g. mount A succeeds but mount B fails) does not leak an active mount, loop
# devices or temp dirs into later CI jobs.
loop_a='' ; loop_b='' ; mnt_a='' ; mnt_b=''
# shellcheck disable=SC2317  # invoked indirectly via 'trap cleanup EXIT'
cleanup() {
  [ -n "$mnt_a" ] && mountpoint -q "$mnt_a" 2>/dev/null && sudo umount "$mnt_a" 2>/dev/null
  [ -n "$mnt_b" ] && mountpoint -q "$mnt_b" 2>/dev/null && sudo umount "$mnt_b" 2>/dev/null
  [ -n "$loop_a" ] && sudo losetup -d "$loop_a" 2>/dev/null
  [ -n "$loop_b" ] && sudo losetup -d "$loop_b" 2>/dev/null
  [ -n "$mnt_a" ] && rmdir "$mnt_a" 2>/dev/null
  [ -n "$mnt_b" ] && rmdir "$mnt_b" 2>/dev/null
  return 0
}
trap cleanup EXIT

loop_a="$(sudo losetup -fP --show "$img_a")"
loop_b="$(sudo losetup -fP --show "$img_b")"
mnt_a="$(mktemp -d)"
mnt_b="$(mktemp -d)"
# The ext4 root is the last partition (p1 on a plain msdos VM, p2 when an ESP precedes it).
root_a="${loop_a}p1" ; root_b="${loop_b}p1"
if [ -e "${loop_a}p2" ]; then root_a="${loop_a}p2" ; root_b="${loop_b}p2" ; fi
if sudo mount -o ro "$root_a" "$mnt_a" && sudo mount -o ro "$root_b" "$mnt_b"; then
  {
    echo
    echo '=== root filesystem: file content differences (diff -qr) ==='
    # --no-dereference compares symlinks as symlinks; without it diff follows an
    # absolute symlink (e.g. /etc/ssl/certs/*.pem) out of the mount and floods the
    # report with spurious "No such file" lines.
    sudo diff -qr --no-dereference "$mnt_a" "$mnt_b" 2>&1 | head -200
    echo
    echo '=== root filesystem: file mtime differences (epoch path) ==='
    diff <(cd "$mnt_a" && sudo find . -printf '%T@ %p\n' | sort -k2) \
         <(cd "$mnt_b" && sudo find . -printf '%T@ %p\n' | sort -k2) | head -200
    echo
    echo '=== content of each differing file (byte offsets + readable strings) ==='
    sudo diff -qr --no-dereference "$mnt_a" "$mnt_b" 2>/dev/null \
      | sed -n 's/^Files \(.*\) and \(.*\) differ$/\1|\2/p' \
      | while IFS='|' read -r fa fb; do
          echo "--- ${fa#"$mnt_a"} ($(sudo stat -c%s "$fa" 2>/dev/null) bytes) ---"
          sudo cmp -l "$fa" "$fb" 2>&1 | head -20
          # Readable-string delta. Use mktemp (not predictable /tmp names, which are
          # symlink/TOCTOU-prone) and temp files rather than process substitution (a
          # sudo'd diff cannot open the caller's /dev/fd/NN). sudo is only needed to
          # READ the root-owned image files; the redirect target is user-owned.
          sa="$(mktemp)" ; sb="$(mktemp)"
          # shellcheck disable=SC2024
          sudo strings "$fa" > "$sa" 2>/dev/null
          # shellcheck disable=SC2024
          sudo strings "$fb" > "$sb" 2>/dev/null
          diff "$sa" "$sb" 2>&1 | head -30
          rm -f "$sa" "$sb"
        done
  } >> "$report" 2>&1
fi
# Loop devices and mounts are released by the EXIT trap (cleanup).

echo "--- ${report} ---" >&2
cat "$report" >&2
exit 1
