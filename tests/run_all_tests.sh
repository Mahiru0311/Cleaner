#!/usr/bin/env bash
# All host-side fixtures are disposable; no iOS app/container operation is run.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
mkdir -p "$ROOT/.work/tests"
OUT=$(mktemp -d "$ROOT/.work/tests/all.XXXXXX")
mkdir -p "$OUT/fixtures"
export TMPDIR="$OUT/fixtures/"
export PYTHONDONTWRITEBYTECODE=1
MAC_SDK=$(xcrun --sdk macosx --show-sdk-path)
ASAN_FLAG=""
if [[ "${WQ_ASAN:-0}" == "1" ]]; then
    ASAN_FLAG="-fsanitize=address -fno-omit-frame-pointer"
    export ASAN_OPTIONS="detect_leaks=0"
fi

compile_run() {
    local name=$1
    shift
    printf '\n== %s ==\n' "$name"
    xcrun --sdk macosx clang -fobjc-arc -fmodules -fmodules-cache-path="$OUT/modules-macos" \
        -isysroot "$MAC_SDK" -Wall -Wextra -Werror $ASAN_FLAG -DCL_ACCESS_TESTING=1 -I. "$@" \
        -framework Foundation -o "$OUT/$name" > "$OUT/$name-build.log" 2>&1 || {
            cat "$OUT/$name-build.log" >&2
            return 1
        }
    "$OUT/$name" > "$OUT/$name-run.log" 2>&1 || {
        cat "$OUT/$name-run.log" >&2
        return 1
    }
    tail -3 "$OUT/$name-run.log"
}

# All Core sources are Foundation-only, so the macOS host can compile and run
# them. CLAppRestoreTests imports Core/CLApp.m directly (for the static
# cl_restore_plan), so it links the other four Core files only.
CORE_SOURCES="Core/CLGrant.m Core/CLScan.m Core/CLCache.m Core/CLLaunchServices.m Core/CLApp.m"
compile_run CLSafetyTests $CORE_SOURCES tests/CLSafetyTests.m
compile_run CLCacheSafetyTests $CORE_SOURCES tests/CLCacheSafetyTests.m
compile_run CLCacheMeasureTests $CORE_SOURCES tests/CLCacheMeasureTests.m
compile_run CLCachePurgeTests $CORE_SOURCES tests/CLCachePurgeTests.m
compile_run CLGrantCopyTests $CORE_SOURCES tests/CLGrantCopyTests.m
compile_run CLAppsCopyTests $CORE_SOURCES tests/CLAppsCopyTests.m
compile_run CLAppSupportTests $CORE_SOURCES tests/CLAppSupportTests.m
compile_run CLLaunchServicesTests $CORE_SOURCES tests/CLLaunchServicesTests.m
compile_run CLAppRestoreTests Core/CLGrant.m Core/CLScan.m Core/CLCache.m Core/CLLaunchServices.m tests/CLAppRestoreTests.m

printf '\n== Python release and static UI checks ==\n'
python3 -m unittest discover -s tests -p 'test_*.py' -v > "$OUT/python-tests.log" 2>&1 || {
    cat "$OUT/python-tests.log" >&2
    exit 1
}
tail -5 "$OUT/python-tests.log"
python3 tests/browser_ui_regressions.py | tee "$OUT/browser-ui.log"

if [[ "${WQ_SKIP_IOS_CHECK:-0}" != 1 ]]; then
    printf '\n== Strict iOS arm64 syntax/link checks ==\n'
    IOS_SDK=$(xcrun --sdk iphoneos --show-sdk-path)
    MIN_OS=$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' Info.plist)
    SOURCES=(Core/CLGrant.m Core/CLScan.m Core/CLCache.m Core/CLApp.m Core/CLLaunchServices.m App/CLUI.m App/CLCleanerViewController.m App/CLAppsViewController.m App/CLHomeViewController.m App/CLSettingsViewController.m App/CLLogViewController.m App/CLTabBarController.m App/main.m)
    FLAGS=(-fobjc-arc -fmodules "-fmodules-cache-path=$OUT/modules-ios" -arch arm64 "-miphoneos-version-min=$MIN_OS" -isysroot "$IOS_SDK" -I Core -I App -Wall -Wextra -Werror -O2)
    xcrun --sdk iphoneos clang -fsyntax-only "${FLAGS[@]}" "${SOURCES[@]}" > "$OUT/ios-syntax.log" 2>&1 || {
        cat "$OUT/ios-syntax.log" >&2
        exit 1
    }
    xcrun --sdk iphoneos clang "${FLAGS[@]}" -framework UIKit -framework Foundation -framework Security -framework UniformTypeIdentifiers \
        "${SOURCES[@]}" -o "$OUT/Cleaner-link-check" > "$OUT/ios-link.log" 2>&1 || {
        cat "$OUT/ios-link.log" >&2
        exit 1
    }
    printf 'iOS syntax and link checks: PASS\n'
else
    printf '\niOS syntax/link checks explicitly skipped (WQ_SKIP_IOS_CHECK=1).\n'
fi
plutil -lint Info.plist entitlements.plist | tee "$OUT/plist-lint.log"
bash -n build.sh tests/run_all_tests.sh tests/run_apps_tests.sh \
    tests/run_access_safety_tests.sh tests/run_launchservices_tests.sh
printf '\nAll requested regression suites passed. Logs retained in: %s\n' "$OUT"
