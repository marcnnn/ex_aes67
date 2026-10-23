#!/bin/sh
# Builds the interop images (rootless podman). Usage: containers/build.sh [name...]
set -e
cd "$(dirname "$0")"
names=${*:-$(ls -d */ | tr -d /)}
for n in $names; do
  echo "== building ex-interop-$n"
  podman build -t "ex-interop-$n" "$n"
done
