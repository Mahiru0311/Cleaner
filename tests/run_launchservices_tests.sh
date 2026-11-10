#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .work/tests
OUT=$(mktemp -d "$PWD/.work/tests/launchservices.XXXXXX")
BINARY=$OUT/CLLaunchServicesTests
cleanup() {
    rm -rf -- "$OUT"
}
trap cleanup EXIT
MACOS_SDK=$(xcrun --sdk macosx --show-sdk-path)
xcrun --sdk macosx clang -arch arm64 -fobjc-arc -fmodules -fmodules-cache-path="$OUT/modules-macos" -isysroot "$MACOS_SDK" \
    -Wall -Wextra -Werror -DCL_ACCESS_TESTING=1 -I. Core/CLGrant.m Core/CLScan.m Core/CLCache.m Core/CLLaunchServices.m Core/CLApp.m tests/CLLaunchServicesTests.m \
    -framework Foundation -o "$BINARY"
"$BINARY"
IOS_SDK=$(xcrun --sdk iphoneos --show-sdk-path)
MIN_OS=$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' Info.plist)
xcrun --sdk iphoneos clang -arch arm64 -fobjc-arc -fmodules -fmodules-cache-path="$OUT/modules-ios" -isysroot "$IOS_SDK" \
    -miphoneos-version-min="$MIN_OS" -Wall -Wextra -Werror -I. -I Core -fsyntax-only \
    Core/CLLaunchServices.m tests/CLLaunchServicesTests.m
