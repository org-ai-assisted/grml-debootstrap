#!/bin/bash
# Exercise the apt-sources handling of reproducible (snapshot.debian.org) builds.
#
# chroot-script's sources stages write to absolute paths under /etc/apt, so this
# runs them inside a throwaway container. It checks the build-time sources, the
# end-of-build swap back to the configured mirror, and that a normal build is
# unaffected.
#
# Usage: tests/snapshot-sources-test.sh          # runs itself in docker
#        IN_CONTAINER=1 tests/snapshot-sources-test.sh   # run here (destructive)

# The RELEASE/COMPONENTS/MIRROR/... assignments below are the stub configuration
# consumed by the eval'd chroot-script stage functions, so shellcheck cannot see
# their use from here.
# shellcheck disable=SC2034

set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
IMAGE="${IMAGE:-debian:trixie}"

if [ -z "${IN_CONTAINER:-}" ]; then
  exec docker run --rm -v "${REPO_DIR}:/repo:ro" -e IN_CONTAINER=1 \
    "$IMAGE" bash /repo/tests/snapshot-sources-test.sh
fi

CHROOT_SCRIPT='/repo/chroot-script'
[ -r "$CHROOT_SCRIPT" ] || CHROOT_SCRIPT="${REPO_DIR}/chroot-script"

# Pull in just the stage functions under test. They are plain top-level
# functions terminated by a '}' in column 0.
extract_function() {
  sed -n "/^$1() {\?\$/,/^}\$/p" "$CHROOT_SCRIPT"
}

eval "$(extract_function writesource)"
eval "$(extract_function rewrite_snapshot_sources)"
eval "$(extract_function chrootmirror)"
eval "$(extract_function restore_snapshot_mirror)"

failures=0
check() {
  local description="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "ok   - ${description}"
  else
    echo "FAIL - ${description}: expected '${expected}', got '${actual}'"
    failures=$((failures + 1))
  fi
}

reset_sources() {
  rm -rf /etc/apt/sources.list.d /var/lib/apt/lists
  mkdir -p /etc/apt/sources.list.d /var/lib/apt/lists
  : > /var/lib/apt/lists/leftover-index
}

count_matches() { grep -c "$1" /etc/apt/sources.list.d/debian.sources || true; }

# Everything left in /var/lib/apt/lists besides the 'partial' subdir. Globbed
# rather than parsed out of ls so odd filenames cannot skew the result.
remaining_indices() {
  local entry name result=''
  for entry in /var/lib/apt/lists/* /var/lib/apt/lists/.[!.]* ; do
    [ -e "$entry" ] || continue
    name="${entry##*/}"
    [ "$name" = 'partial' ] && continue
    result="${result}${result:+ }${name}"
  done
  printf '%s' "$result"
}

SNAPSHOT='https://snapshot.debian.org/archive/debian/20260101T000000Z'
SNAPSHOT_SECURITY='https://snapshot.debian.org/archive/debian-security/20260101T000000Z'
REAL_MIRROR='http://deb.debian.org/debian'

RELEASE='trixie'
COMPONENTS='main'
KEEP_SRC_LIST='no'
FALLBACK_MIRROR="$REAL_MIRROR"

echo '== reproducible build: build-time sources point at the snapshot =='
reset_sources
SOURCE_DATE_EPOCH=1767225600
MIRROR="$SNAPSHOT"
FINAL_MIRROR="$REAL_MIRROR"
SNAPSHOT_SECURITY_MIRROR="$SNAPSHOT_SECURITY"
chrootmirror >/dev/null

check 'base stanza uses the snapshot archive'      1 "$(count_matches "^URIs: ${SNAPSHOT}\$")"
check 'security stanza uses the snapshot archive'  1 "$(count_matches "^URIs: ${SNAPSHOT_SECURITY}\$")"
check 'no live security.debian.org at build time'  0 "$(count_matches '^URIs: http://security.debian.org')"
check 'both snapshot stanzas skip Valid-Until'     2 "$(count_matches '^Check-Valid-Until: no$')"
check 'legacy sources.list is gone'                'absent' \
  "$([ -e /etc/apt/sources.list ] && echo present || echo absent)"

echo '== reproducible build: end-of-build swap back to the configured mirror =='
restore_snapshot_mirror >/dev/null

check 'base stanza restored to the real mirror'    1 "$(count_matches "^URIs: ${REAL_MIRROR}\$")"
check 'security restored to security.debian.org'   1 "$(count_matches '^URIs: http://security.debian.org/debian-security$')"
check 'no snapshot URI survives in the image'      0 "$(count_matches '^URIs: https://snapshot.debian.org')"
check 'Check-Valid-Until removed with the snapshot' 0 "$(count_matches '^Check-Valid-Until')"
check 'stanzas rewritten, not appended'            2 "$(count_matches '^URIs: ')"
check 'snapshot package indices dropped'           '' \
  "$(remaining_indices)"

echo '== normal build: unaffected by any of this =='
reset_sources
unset SOURCE_DATE_EPOCH FINAL_MIRROR SNAPSHOT_SECURITY_MIRROR
MIRROR="$REAL_MIRROR"
chrootmirror >/dev/null

check 'base stanza uses the configured mirror'     1 "$(count_matches "^URIs: ${REAL_MIRROR}\$")"
check 'security uses live security.debian.org'     1 "$(count_matches '^URIs: http://security.debian.org/debian-security$')"
check 'no Check-Valid-Until in a normal build'     0 "$(count_matches '^Check-Valid-Until')"

FINAL_MIRROR=''
restore_snapshot_mirror >/dev/null
check 'restore is a no-op without SOURCE_DATE_EPOCH' 1 "$(count_matches "^URIs: ${REAL_MIRROR}\$")"
check 'apt indices untouched in a normal build'    'leftover-index' \
  "$(remaining_indices)"

echo '== stanzas added by earlier stages (custom_scripts) survive the swap =='
reset_sources
SOURCE_DATE_EPOCH=1767225600
MIRROR="$SNAPSHOT"
FINAL_MIRROR="$REAL_MIRROR"
SNAPSHOT_SECURITY_MIRROR="$SNAPSHOT_SECURITY"
KEEP_SRC_LIST='no'
chrootmirror >/dev/null
# what a custom script would append
writesource '/etc/apt/sources.list.d/debian.sources' 'deb' 'http://example.com/custom' \
  "$RELEASE" 'main' '/usr/share/keyrings/debian-archive-keyring.gpg'
restore_snapshot_mirror >/dev/null

check 'custom stanza still present'                1 "$(count_matches '^URIs: http://example.com/custom$')"
check 'snapshot stanza still swapped'              1 "$(count_matches "^URIs: ${REAL_MIRROR}\$")"
check 'no snapshot URI left behind'                0 "$(count_matches '^URIs: https://snapshot.debian.org')"

echo '== a local (file:) mirror is not written into the installed system =='
reset_sources
SOURCE_DATE_EPOCH=1767225600
MIRROR="$SNAPSHOT"
FINAL_MIRROR='file:///srv/local-mirror'
SNAPSHOT_SECURITY_MIRROR="$SNAPSHOT_SECURITY"
chrootmirror >/dev/null
restore_snapshot_mirror >/dev/null

check 'file: mirror replaced by the fallback'      1 "$(count_matches "^URIs: ${FALLBACK_MIRROR}\$")"
check 'no file: URI in the installed system'       0 "$(count_matches '^URIs: file:')"

echo '== a mirror URL containing regex/sed metacharacters is written verbatim =='
reset_sources
SOURCE_DATE_EPOCH=1767225600
MIRROR="$SNAPSHOT"
# '&' would expand to the whole match in a sed replacement, and '|' would end
# the s||| expression outright.
FINAL_MIRROR='http://cache.example.com/?u=deb.debian.org&c=1|x'
SNAPSHOT_SECURITY_MIRROR="$SNAPSHOT_SECURITY"
KEEP_SRC_LIST='no'
chrootmirror >/dev/null
restore_snapshot_mirror >/dev/null

check 'metacharacter mirror written verbatim'      1 "$(count_matches "^URIs: ${FINAL_MIRROR}\$")"
check 'no snapshot URI left behind'                0 "$(count_matches '^URIs: https://snapshot.debian.org')"

echo '== KEEP_SRC_LIST: sources left alone, snapshot indices still dropped =='
reset_sources
SOURCE_DATE_EPOCH=1767225600
MIRROR="$SNAPSHOT"
FINAL_MIRROR="$REAL_MIRROR"
SNAPSHOT_SECURITY_MIRROR="$SNAPSHOT_SECURITY"
KEEP_SRC_LIST='yes'
printf 'Types: deb\nURIs: %s\nSuites: %s\nComponents: main\n' \
  'http://example.com/debian' "$RELEASE" > /etc/apt/sources.list.d/debian.sources
restore_snapshot_mirror >/dev/null

check 'user-provided sources untouched'            1 "$(count_matches '^URIs: http://example.com/debian$')"
check 'snapshot indices still dropped'             '' \
  "$(remaining_indices)"

echo
if [ "$failures" -eq 0 ]; then
  echo 'snapshot-sources-test: all checks passed'
else
  echo "snapshot-sources-test: ${failures} check(s) failed"
  exit 1
fi
