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
compile_run CLCacheFastPathTests $CORE_SOURCES tests/CLCacheFastPathTests.m
compile_run CLCachePurgeTests $CORE_SOURCES tests/CLCachePurgeTests.m
compile_run CLCustomCleanTests $CORE_SOURCES Core/CLCustomClean.m tests/CLCustomCleanTests.m
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
    # The App Intent (v2.4) is Swift, compiled into the main app target:
    # compile it first — it emits the generated ObjC header main.m imports
    # (CleanerIntents-Swift.h) and the object linked into the app binary.
    # This also type-checks the Swift file on the macOS runner. The
    # const-values flags are the same as build.sh's (v2.7): a misspelled
    # flag fails the preflight here instead of the release build.
    # -Xfrontend eats exactly one argument, so the protocols file needs
    # two -Xfrontend flags; the const-values path comes from the output
    # file map, not from a command-line flag.
    cat > "$OUT/output-file-map.json" <<EOF
{
  "$ROOT/Intents/CleanerIntents.swift": {
    "object": "$OUT/CleanerIntents.o",
    "const-values": "$OUT/CleanerIntents.swiftconstvalues"
  }
}
EOF
    xcrun --sdk iphoneos swiftc -target arm64-apple-ios26.0 -sdk "$IOS_SDK" -O -swift-version 5 \
        -parse-as-library -module-name CleanerIntents \
        -emit-const-values \
        -output-file-map "$OUT/output-file-map.json" \
        -Xfrontend -const-gather-protocols-file -Xfrontend Intents/swift_const_gather_protocols.json \
        -import-objc-header Intents/CleanerIntents-Bridging-Header.h \
        -emit-objc-header-path "$OUT/CleanerIntents-Swift.h" \
        -I Core -c Intents/CleanerIntents.swift -o "$OUT/CleanerIntents.o" > "$OUT/ios-swift.log" 2>&1 || {
            cat "$OUT/ios-swift.log" >&2
            exit 1
        }
    SOURCES=(Core/CLGrant.m Core/CLScan.m Core/CLCache.m Core/CLApp.m Core/CLLaunchServices.m Core/CLCustomClean.m Core/CLBackgroundClean.m App/CLUI.m App/CLCleanerViewController.m App/CLAppsViewController.m App/CLCustomCleanViewController.m App/CLAppActions.m App/CLAppDirectoryViewController.m App/CLHomeViewController.m App/CLSettingsViewController.m App/CLLogViewController.m App/CLRulePickerViewController.m App/CLShortcutsGuideViewController.m App/CLTabBarController.m App/main.m)
    FLAGS=(-fobjc-arc -fmodules "-fmodules-cache-path=$OUT/modules-ios" -arch arm64 "-miphoneos-version-min=$MIN_OS" -isysroot "$IOS_SDK" -I Core -I App -I "$OUT" -Wall -Wextra -Werror -O2)
    xcrun --sdk iphoneos clang -fsyntax-only "${FLAGS[@]}" "${SOURCES[@]}" > "$OUT/ios-syntax.log" 2>&1 || {
        cat "$OUT/ios-syntax.log" >&2
        exit 1
    }
    xcrun --sdk iphoneos clang "${FLAGS[@]}" -framework UIKit -framework Foundation -framework Security -framework UniformTypeIdentifiers -framework AppIntents \
        "${SOURCES[@]}" "$OUT/CleanerIntents.o" -o "$OUT/Cleaner-link-check" > "$OUT/ios-link.log" 2>&1 || {
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
