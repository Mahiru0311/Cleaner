#!/usr/bin/env bash
# Access/safety regression tests: cache-swap recovery, symlink-ancestry
# safety, purge, measure and atomic copy. The mutation tests for the
# deleted file browser/editor are gone with that feature.
set -euo pipefail
cd "$(dirname "$0")/.."
# Generated compiler output stays inside this worktree; fixtures use UUID temp paths.
OUT=.work/access-tests
mkdir -p "$OUT/tmp"
export TMPDIR="$PWD/$OUT/tmp/"
SDK=$(xcrun --sdk macosx --show-sdk-path)
CORE="Core/CLGrant.m Core/CLScan.m Core/CLCache.m Core/CLLaunchServices.m Core/CLApp.m"
for test in CLSafetyTests CLCacheSafetyTests CLCachePurgeTests CLCacheMeasureTests CLGrantCopyTests; do
    xcrun --sdk macosx clang -fobjc-arc -fmodules -fmodules-cache-path="$OUT/ModuleCache" -isysroot "$SDK" \
        -Wall -Wextra -Werror -DCL_ACCESS_TESTING=1 -I. $CORE "tests/$test.m" \
        -framework Foundation -o "$OUT/$test"
    "$OUT/$test"
done
