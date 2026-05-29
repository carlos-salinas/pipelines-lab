#!/usr/bin/env bash
set -x
# Export Environment
export RELEASE_DIR=${RELEASE_DIR:-/tmp/release}

export RELEASE_DATE=`date -u +'%Y-%m-%dT%H:%M:%S%:z'`
make release

cd  ${RELEASE_DIR}
echo $RELEASE_DATE> build_timestamp.txt
sha256sum *.yaml > SHA256SUMS.txt
