#! /usr/bin/env bash

set -x
set -euo pipefail

if [ -z "$1" ]
then
    >&2 echo "Please pass libgit2 version as first argument of this script ($0)"
    exit 1
fi

# Wait for docker pull to complete downloading container
manylinux_image="ghcr.io/pyca/cryptography-manylinux2014:x86_64"
docker pull "${manylinux_image}" &
wait

# Build wheels
docker run --rm -v `pwd`:/io "${manylinux_image}" /io/travis/build-manylinux-wheels.sh $1 &
wait
