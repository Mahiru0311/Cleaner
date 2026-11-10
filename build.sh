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
# NOTE (v2.5, runs 42823044882 / 42824508382 / 42825022774 / 42825431199):
# the first v2.5 builds all "lost" CleanerShortcuts at the pre-strip
# check — but the types were NEVER lost. The check was wrong: it grepped
# for the literal mangled name "CleanerShortcutsV", which never appears
# (word substitution — see the check below). The data flow, @_optimize(none),
# metatype references, -Onone and dropping -flto were all chasing a
# phantom optimizer bug that did not exist. -Onone (swiftc) and no -flto
# are KEPT anyway — harmless for a tiny Swift file, and they remove
# variables — but they are NOT the fix. Do NOT re-add -dead_strip without
# re-verifying the mangled symbols in the built binary. If the IPA grows
# past the 250KB target, revisit — but a shortcut the Shortcuts app
# cannot see is worse than a few KB.
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
# App Intent check — BEFORE strip (v2.5). The mangled-symbol check MUST
# run here, on the just-linked binary, not in validate_app: `strip -x`
# removes the local symbols, and Swift struct metadata symbols are local
# (the v2.4 binary's symbol table has 415 global symbols and 1 local).
# Only the AppIntents link is checked in validate_app; the intent types
# are verified here, pre-strip, where the symbols are intact.
# WORD SUBSTITUTION (v2.5, run 42825889428 — the real lesson): Swift's
# mangler substitutes words already seen. The module is "CleanerIntents"
# (words: Cleaner, Intents), so "CleanerShortcuts" is mangled as
# $s14CleanerIntents0A9ShortcutsV — "Cleaner" becomes the substitution
# 0A, only "Shortcuts" is spelled out — and "appShortcuts" as
# 03appC0. The literal strings "CleanerShortcutsV" and "appShortcuts"
# NEVER appear in the binary. The old greps looked for those literals,
# so they failed on every v2.5 build even though the types were present
# all along — five runs (42823044882 / 42824508382 / 42825022774 /
# 42825431199 / 42825889428) chased a phantom optimizer bug that did
# not exist. The diagnostic dump in run 42825889428 proved the types
# are in the binary (full CleanerShortcuts metadata, descriptor,
# appShortcuts accessor, AppShortcutsProvider witnesses). "CleanCacheIntent"
# is spelled out in full (16 chars) because "Clean" is not the word
# "Cleaner", so no substitution applies to it.
grep -aE -q '[$]s14CleanerIntents16CleanCacheIntentV' "$APP/Cleaner" || \
    fail "linked binary is missing the CleanCacheIntent type (no mangled symbol)"
grep -aE -q '[$]s14CleanerIntents0A9ShortcutsV' "$APP/Cleaner" || \
    fail "linked binary is missing the CleanerShortcuts provider (no mangled symbol)"
grep -a -q '0A9ShortcutsV03appC0' "$APP/Cleaner" || \
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
