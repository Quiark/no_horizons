#!/bin/bash
set -euo pipefail
export DEST=${DEST:-$SHARED_WORKSPACE/Luanti/ContentDB.proxy/packages}
for m in nh_warpstorms nh_boring nh_nebula; do
    rm -rf "$DEST/$m"
    mkdir -p "$DEST/$m"
    cp -R "$m/." "$DEST/$m/"
done
