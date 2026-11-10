#!/usr/bin/env bash
# Builds Cleaner.ipa (arm64, ad-hoc signed with the App Group entitlement;
# re-sign with your sideloading tool, keeping an App Group).
# The app policy is iOS 26.0 or later; the SDK version is intentionally not the
# deployment target. Set CLEANER_FINAL_IPA to override the publication path.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$ROOT"
MINIMUM_IOS_VERSION=26.0
FINAL_IPA=${CLEANER_FINAL_IPA:-${WQFILES_FINAL_IPA:-Cleaner.ipa}}

# Publish only after the host regression suite passes. The packaged artifact
# still needs device validation, but this prevents a known-broken source tree
# from replacing the release IPA.
if [[ "${WQ_SKIP_PREFLIGHT:-0}" != 1 && -x "$ROOT/tests/run_all_tests.sh" ]]; then
    "$ROOT/tests/run_all_tests.sh"
fi
if [[ "$FINAL_IPA" != /* ]]; then
    FINAL_IPA="$ROOT/$FINAL_IPA"
fi
FINAL_DIR=$(dirname -- "$FINAL_IPA")
if [[ ! -d "$FINAL_DIR" ]]; then
    echo "final IPA directory does not exist: $FINAL_DIR" >&2
    exit 1
fi

plist_value() {
    plutil -extract "$1" raw -o - "$2"
}

fail() {
    echo "build validation failed: $*" >&2
    exit 1
}

EXPECTED_BUNDLE_ID=$(plist_value CFBundleIdentifier Info.plist)
EXPECTED_VERSION=$(plist_value CFBundleShortVersionString Info.plist)
EXPECTED_BUILD=$(plist_value CFBundleVersion Info.plist)
EXPECTED_MINIMUM_OS=$(plist_value MinimumOSVersion Info.plist)
APP_GROUP=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' entitlements.plist)
[[ -n "$APP_GROUP" ]] || fail "entitlements.plist has no App Group"
[[ "$EXPECTED_MINIMUM_OS" == "$MINIMUM_IOS_VERSION" ]] || \
    fail "Info.plist minimum OS $EXPECTED_MINIMUM_OS does not match build policy $MINIMUM_IOS_VERSION"

OUT=$(mktemp -d "$FINAL_DIR/.Cleaner-build.XXXXXX")
IPA_TMP=$(mktemp "$FINAL_DIR/.Cleaner.ipa.XXXXXX")
rm -f -- "$IPA_TMP"
CHECK_DIR=""
cleanup() {
    if [[ -n "${OUT:-}" && -d "$OUT" ]]; then rm -rf -- "$OUT"; fi
    if [[ -n "${IPA_TMP:-}" && -e "$IPA_TMP" ]]; then rm -f -- "$IPA_TMP"; fi
    if [[ -n "${CHECK_DIR:-}" && -d "$CHECK_DIR" ]]; then rm -rf -- "$CHECK_DIR"; fi
}
trap cleanup EXIT

APP="$OUT/Payload/Cleaner.app"
mkdir -p "$APP"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
# App Intent (v2.4): CleanerIntents.swift is compiled first — it emits the
# generated ObjC header (CleanerIntents-Swift.h, imported by App/main.m
# for the keepAlive call) and the object file linked into the app below.
# The intent lives in the MAIN APP target, not in an extension: with
# openAppWhenRun = false iOS headless-launches the app process in the
# background and runs perform() in-process, so the clean uses the same
# sandbox grant, measurement cache and custom rules as the app itself.
# -swift-version 5 keeps Swift 6 strict-concurrency diagnostics out of
# the NSDictionary bridging; -parse-as-library stops swiftc synthesising
# a _main entry point for the file (it is library code — App/main.m owns
# main, and without the flag the link fails on a duplicate _main).
# -dead_strip WARNING (v2.4 lesson, verified on the v2.4 binary): the old
# comment here said "no -dead_strip risk — main.m references
# CLIntentsBootstrap, which references the intent types". That was WRONG.
# keepAlive only wrote `_ = CleanCacheIntent.self` / `_ =
# CleanerShortcuts.self` — side-effect-free metadata references that -O +
# LTO deletes, after which -dead_strip removes the types and their
# protocol conformances entirely. The v2.4 binary had NO CleanCacheIntent /
# CleanerShortcuts mangled symbols and NO appShortcuts at all (only the 8
# CLIntentsBootstrap symbols and 1 bare name string each). What keeps the
# types linked in v2.5 is a REAL data flow, not keepAlive: the Settings
# Shortcuts guide reads CleanerShortcuts.appShortcuts through
# CLCleanerShortcutsInfo and shows the titles on screen — the optimizer
# cannot delete a flow that ends in a UIKit label. keepAlive is kept as
# a belt-and-braces call, but it is NOT the protection. validate_app
# below now checks the mangled symbols, not the bare names.
# NOTE (v2.5, runs 42823044882 / 42824508382 / 42825022774): the first
# v2.5 builds STILL lost the types. What did NOT work, in order:
# (1) the real data flow (guide reads appShortcuts) — swiftc -O
# constant-folded it (appShortcuts is a literal 1-element array, the
# title is a constant), so the references never reached the object file;
# (2) @_optimize(none) on CLCleanerShortcutsInfo's computed properties
# plus explicit `_ = CleanerShortcuts.self` metatype references — the
# pre-strip check then PASSED CleanCacheIntent but STILL failed
# CleanerShortcuts. CleanerShortcuts is never instantiated (only its
# static property is read), so its metadata is not needed by the code,
# and the attribute is a function-level one that may not apply to a
# property getter at all; -flto then re-optimizes across modules at link
# time and can delete what swiftc kept. So the fix is at the flag level,
# not the code level: swiftc compiles the intent file with -Onone (no
# Swift optimisation at all — the file is tiny, performance is
# irrelevant), and the link drops -flto (keeps -Os for the ObjC compile).
# -dead_strip stays removed. Do NOT re-add -O for swiftc, -flto, or
# -dead_strip without re-verifying the mangled symbols in the built
# binary. If the IPA grows past the 250KB target, revisit — but a
# shortcut the Shortcuts app cannot see is worse than a few KB.
xcrun --sdk iphoneos swiftc -target arm64-apple-ios26.0 -sdk "$SDK" -Onone -swift-version 5 \
    -parse-as-library -module-name CleanerIntents \
    -import-objc-header Intents/CleanerIntents-Bridging-Header.h \
    -emit-objc-header-path "$OUT/CleanerIntents-Swift.h" \
    -I Core -c Intents/CleanerIntents.swift -o "$OUT/CleanerIntents.o"
xcrun --sdk iphoneos clang -fobjc-arc -fmodules -fmodules-cache-path="$OUT/ModuleCache" -arch arm64 \
    -miphoneos-version-min="$MINIMUM_IOS_VERSION" \
    -isysroot "$SDK" -I Core -I App -I "$OUT" -Wall -Wextra -Werror -Os \
    -framework UIKit -framework Foundation -framework Security -framework UniformTypeIdentifiers \
    -framework AppIntents \
    Core/CLGrant.m Core/CLScan.m Core/CLCache.m Core/CLApp.m Core/CLLaunchServices.m Core/CLCustomClean.m \
    Core/CLBackgroundClean.m \
    App/CLUI.m App/CLCleanerViewController.m App/CLAppsViewController.m App/CLCustomCleanViewController.m \
    App/CLAppActions.m App/CLAppDirectoryViewController.m \
    App/CLHomeViewController.m App/CLSettingsViewController.m App/CLLogViewController.m \
    App/CLRulePickerViewController.m App/CLShortcutsGuideViewController.m \
    App/CLTabBarController.m App/main.m "$OUT/CleanerIntents.o" -o "$APP/Cleaner"
# App Intent check — BEFORE strip (v2.5, run 42823793730 lesson). The
# mangled-symbol check MUST run here, on the just-linked binary, not in
# validate_app: `strip -x` below removes essentially all local symbols
# (the v2.4 binary's symbol table has 415 global symbols and 1 local),
# and Swift struct metadata symbols are local — strip deletes them even
# when the types are present and working. Only @objc class symbols
# (CLIntentsBootstrap) survive strip, which is why the v2.4 binary showed
# those 8 and nothing else. So a post-strip symbol grep measures strip,
# not the types: it failed the first v2.5 build that had the types in the
# code. Here, pre-strip, the symbols are intact: the mangled symbols
# ([$]s…V) and the appShortcuts witness prove the types really made it
# into the linked binary. The length digits are matched loosely ([0-9]+)
# so the check does not depend on counting the identifier length by hand:
# "CleanerShortcuts" is 16 characters (Cleaner 7 + Shortcuts 9), and the
# v2.4 binary's surviving $s14CleanerIntents18CLIntentsBootstrapC (18
# chars) confirms the length-prefix rule — an earlier note wrote 17 for
# CleanerShortcuts, which is a miscount; either way the regex matches,
# and the real emitted symbol is confirmed when the built IPA is verified.
# Bare names are NOT checked here: the v2.4 binary still contained the
# plain strings "CleanCacheIntent" and "CleanerShortcuts" (1 each) while
# the types themselves were gone — grepping a bare name passed on a binary
# with no intent in it, and the Shortcuts app found nothing.
# DIAGNOSTIC (v2.5, run 42825431199): the pre-strip check still fails
# on CleanerShortcuts even with swiftc -Onone and no -flto, so the
# "optimizer removed it" theory is dead — the symbol may never be
# emitted, or under a different name. Dump every CleanerIntents mangled
# symbol in the linked binary to the log so the next fix is based on
# what is actually there, not on a theory. Remove once resolved.
echo "--- CleanerIntents symbols in linked binary ---"
grep -a -o '[$]s[0-9]*CleanerIntents[A-Za-z0-9_]*' "$APP/Cleaner" | sort -u || true
echo "--- end CleanerIntents symbols ---"
grep -aE -q '[$]s[0-9]+CleanerIntents[0-9]+CleanCacheIntentV' "$APP/Cleaner" || \
    fail "linked binary is missing the CleanCacheIntent type (no mangled symbol — the Swift optimizer may have removed it)"
grep -aE -q '[$]s[0-9]+CleanerIntents[0-9]+CleanerShortcutsV' "$APP/Cleaner" || \
    fail "linked binary is missing the CleanerShortcuts provider (no mangled symbol — the Swift optimizer may have removed it)"
grep -a -q "appShortcuts" "$APP/Cleaner" || \
    fail "linked binary has no appShortcuts witness"
xcrun --sdk iphoneos strip -x "$APP/Cleaner"
cp Info.plist "$APP/Info.plist"
cp icons/AppIcon*@*.png "$APP/"
plutil -convert binary1 "$APP/Info.plist"
codesign -f -s - --entitlements entitlements.plist "$APP"

validate_app() {
    local app_path=$1
    [[ -x "$app_path/Cleaner" ]] || fail "missing executable in $app_path"
    [[ -f "$app_path/Info.plist" ]] || fail "missing Info.plist in $app_path"
    [[ "$(plist_value CFBundleIdentifier "$app_path/Info.plist")" == "$EXPECTED_BUNDLE_ID" ]] || \
        fail "bundle identifier does not match source metadata"
    [[ "$(plist_value CFBundleShortVersionString "$app_path/Info.plist")" == "$EXPECTED_VERSION" ]] || \
        fail "short version does not match source metadata"
    [[ "$(plist_value CFBundleVersion "$app_path/Info.plist")" == "$EXPECTED_BUILD" ]] || \
        fail "build version does not match source metadata"
    [[ "$(plist_value MinimumOSVersion "$app_path/Info.plist")" == "$EXPECTED_MINIMUM_OS" ]] || \
        fail "minimum OS does not match source metadata"
    codesign --verify --deep --strict "$app_path"
    local signed_entitlements
    signed_entitlements=$(codesign -d --entitlements :- "$app_path" 2>&1) || \
        fail "unable to inspect signed entitlements"
    [[ "$signed_entitlements" == *"$APP_GROUP"* ]] || \
        fail "signed app is missing required App Group $APP_GROUP"
    # App Intent (v2.5): the binary must link AppIntents. The intent TYPES
    # themselves are verified BEFORE strip (right after the link above),
    # not here: `strip -x` removes the local symbols, and Swift struct
    # metadata symbols are local — a post-strip symbol grep measures strip,
    # not the types (it failed a build that had the types in the code).
    # Only the AppIntents link is checked here, on the final binary.
    otool -L "$app_path/Cleaner" | grep -q "AppIntents" || \
        fail "app binary does not link AppIntents"
}

# Package to a same-directory temporary sibling, then validate the actual ZIP
# contents and signature. The final path is untouched until all checks pass.
(cd "$OUT" && zip -qry "$IPA_TMP" Payload)
unzip -tqq "$IPA_TMP"
CHECK_DIR=$(mktemp -d "$OUT/ipa-check.XXXXXX")
unzip -q "$IPA_TMP" -d "$CHECK_DIR"
validate_app "$CHECK_DIR/Payload/Cleaner.app"
mv -f -- "$IPA_TMP" "$FINAL_IPA"
IPA_TMP=""
echo "wrote $FINAL_IPA"
