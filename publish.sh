#!/bin/bash
export DEST=$SHARED_WORKSPACE/Luanti/ContentDB.proxy/packages/no_horizons
mkdir -p $DEST
cp * $DEST/
cp -r models textures $DEST/
