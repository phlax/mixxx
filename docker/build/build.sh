#!/usr/bin/env bash

set -euxo pipefail

rm -f /src/build/CMakeCache.txt
rm -rf /src/build/CMakeFiles

cmake -S /src -B /src/build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build /src/build -j"$(nproc)"
