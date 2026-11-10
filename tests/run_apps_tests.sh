#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .work/tests
OUT=$(mktemp -d "$PWD/.work/tests/apps.XXXXXX")
cleanup() {
    rm -rf -- "$OUT"
}
trap cleanup EXIT
SDK=$(xcrun --sdk macosx --show-sdk-path)
CORE="Core/CLGrant.m Core/CLScan.m Core/CLCache.m Core/CLLaunchServices.m Core/CLApp.m"
for test in CLAppSupportTests CLAppsCopyTests; do
    xcrun --sdk macosx clang -fobjc-arc -fmodules -fmodules-cache-path="$OUT/modules-macos" -isysroot "$SDK" \
        -Wall -Wextra -Werror -DCL_ACCESS_TESTING=1 -I. $CORE "tests/$test.m" \
        -framework Foundation -o "$OUT/$test"
    "$OUT/$test"
done
# CLAppRestoreTests imports Core/CLApp.m directly, so it links the other
# four Core files only.
xcrun --sdk macosx clang -fobjc-arc -fmodules -fmodules-cache-path="$OUT/modules-macos" -isysroot "$SDK" \
    -Wall -Wextra -Werror -DCL_ACCESS_TESTING=1 -I. Core/CLGrant.m Core/CLScan.m Core/CLCache.m Core/CLLaunchServices.m tests/CLAppRestoreTests.m \
    -framework Foundation -o "$OUT/CLAppRestoreTests"
"$OUT/CLAppRestoreTests"
