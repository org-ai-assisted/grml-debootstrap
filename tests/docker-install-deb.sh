#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Install an already built grml-debootstrap.deb.
# Wrapper around apt-get install for usage inside docker.

set -eu -o pipefail

if [ "$#" -ne 1 ]; then
  echo "$0: Invalid arguments" >&2
  echo "Expect: $0 DEB_NAME" >&2
  exit 1
fi
DEB_NAME="$1"

apt-get update
# docker images can be relatively old, especially for unstable.
apt-get upgrade -qq -y
# mtools (ESP rebuild) and python3 (deterministic identifier derivation) are only
# Recommends of grml-debootstrap, but check4progs treats both as hard requirements
# for a reproducible build; install them explicitly so a build never aborts on that
# guard if Recommends handling changes.
apt-get install -qq -y "$DEB_NAME" mtools python3
