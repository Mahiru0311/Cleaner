#!/usr/bin/env python3
"""Static regression checks for Cleaner v2 (read-only in-app directory
browser only — no editing, no sharing, no plist/hex editors, no Go to Path;
KernelSU Miuix home; WQFiles cache cleaner 1:1; GestaltX icon language;
SF Symbols only, no emoji)."""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "App"
CORE = ROOT / "Core"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def require(text: str, needle: str, label: str) -> None:
    if needle not in text:
        raise AssertionError(f"missing {label}: {needle}")


def forbid(text: str, needle: str, label: str) -> None:
    if needle in text:
        raise AssertionError(f"stale {label}: {needle}")


def forbid_any(text: str, needles, label: str) -> None:
    for needle in needles:
        forbid(text, needle, label)


cleaner = read(APP / "CLCleanerViewController.m")
cache = read(CORE / "CLCache.m")
home = read(APP / "CLHomeViewController.m")
tabbar = read(APP / "CLTabBarController.m")
settings = read(APP / "CLSettingsViewController.m")
log_view = read(APP / "CLLogViewController.m")
main = read(APP / "main.m")
build = read(ROOT / "build.sh")
info = read(ROOT / "Info.plist")
all_sources = "".join(
    p.read_text(encoding="utf-8") for p in list(APP.glob("*.m")) + list(CORE.glob("*.m"))
)

# --- Deleted in v2: full file browser, plist editor, hex viewer, sharing/ZIP.
# v2.2 brings back a read-only in-app directory browser (CLAppDirectory*),
# which is the one authorised exception: tap an app to enter its container.
# No editing, no sharing, no Go to Path. ---
forbid_any(all_sources, [
    "WQDirViewController", "WQPlistEditor", "WQHexViewer", "WQSharing",
    "wq_share", "UIActivityViewController", "openFolder",
    "在文件浏览器中显示",
], "deleted file-browser/editor/sharing surface")
# (v0.1 filenames appear in provenance comments only; the build list is
# checked against build.sh below.)

# --- Cache cleaner keeps the v0.1 WQCache invariants (renamed CLCache). ---
# A cancelled scan always completes (cancelled=YES) so the page never gets
# stuck on "scanning"; a validation failure rescans by itself.
require(cache, "cancelled", "scanner completion reports cancellation")
require(cleaner, "已重新扫描", "validation failure rescans automatically")
forbid(cleaner, "_cleanRequiresRescan", "removed rescan flag (auto-rescan instead)")
require(cache, "item.selected = !item.limited", "limited cache rows are not selected")
require(cleaner, "if (item.crashLogs)", "crash-log branch")
require(cleaner, "NSUInteger appCount = 0;", "cache header excludes crash logs from app count")
require(cleaner, "self.refreshControl = [UIRefreshControl new];", "cache refresh control")
require(cleaner, "_lastScanFinished <= 0", "cache rescans stale data on appearance")
require(cleaner, "_cleanCancellation", "cache clean cancellation")
require(cleaner, "action:@selector(stopClean)", "cache clean stop button")
require(cleaner, "请先关闭正在运行的应用。", "cache clean warning")
require(cleaner, "只选大缓存", "large-cache-only selection")
require(cleaner, "清理（%@）", "clean button shows selected size")

# --- Home: KernelSU v3.2.5 Miuix 1:1 (copy changed). ---
# v2.3 (user, 2026-11-10 19:28): the final direction is the 1:1 KSU home —
# the 19:17 full-width rectangle and the 19:20 white-card variants were
# both rejected. Green card #DFFAE4, hollow CheckCircleOutline badge
# #36D167, 110pt, at the card's bottom-right corner (+27/+31), CLIPPED
# by the card (v2.4): KSU's icon sits inside the Card and the Card cuts
# the ring at its right and bottom edges — only ~3/4 of the arc + the
# check are drawn. A complete ring dangling outside the card (v2.0–v2.3)
# is what always looked floating and fake.
require(home, "0xDFFAE4", "green status card #DFFAE4")
require(home, "0x36 / 255.0 green:0xD1 / 255.0 blue:0x67", "check badge #36D167")
require(home, "CheckCircleOutline", "hollow outline check badge (KSU icon)")
require(home, "@\"已授权\"", "authorised status title")
require(home, "@\"受限\"", "restricted status title")
require(home, "@\"未授权\"", "unauthorised status title")
require(home, "@\"不支持\"", "unsupported status title")
require(home, "runGrantProbe", "grant probe for the restricted state")
require(home, "@\"正在检查…\"", "checking state while probing")
require(home, "去清理", "status card explains before jumping when blocked")
require(home, "@\"应用\"", "apps mini card")
require(home, "@\"可清理\"", "reclaimable mini card")
forbid(home, "setTitle:@\"去清理\"", "separate go-to-clean button (status card is the entry)")
forbid(home, "appGroupPill", "the 19:20 white-card pill is gone in the 1:1 KSU home")
forbid(home, "status.backgroundColor = UIColor.systemBackgroundColor", "white status card (19:20 variant, rejected)")
require(home, "tag.fill", "version row icon")
require(home, "checkmark.shield.fill", "support-range row icon")
# --- Home layout fixes (v2.1, from the real-device screenshot). ---
# Mode line 15pt / max 2 lines (16pt wrapped mid-word in the narrow card);
# content bottom -20 (system tab bar owns the safe area now).
require(home, "systemFontOfSize:15 weight:UIFontWeightMedium", "mode line 15pt")
require(home, "numberOfLines = 2", "mode line at most 2 lines")
require(home, "constant:-20", "content bottom padding 20")
forbid(home, "constant:-110", "old -110 padding for the deleted floating bar")
# --- Home layout (v2.2): the power button did nothing: deleted, rescan is
# pull-to-refresh now. ---
forbid(home, "powerTapped", "deleted power button action")
forbid(home, 'systemImageNamed:@"power"', "deleted power button icon")
require(home, "userRefresh", "pull-to-refresh rescan")
require(home, "scroll.refreshControl = refresh;", "home refresh control")
require(home, "constant:-32", "content width for 16pt side margins")
forbid(home, "constraintGreaterThanOrEqualToConstant:212", "green card min height 212 (v2.3 slab: a floor re-introduces a tall card)")
# --- Home layout (v2.4, user 2026-11-10 20:00): the badge is CLIPPED,
# not overflowing. The status card has clipsToBounds = YES, the 110pt
# badge keeps KSU's +27/+31 offsets (its frame sticks out past the card
# on the right and bottom — that is what the card cuts), and the green
# card is EXACTLY as tall as the right column (KSU's Row uses
# height(IntrinsicSize.Min); measured on the reference: green 543x578,
# right column 549x574, ratio ~1.007 ≈ 1:1, widths ~50/50). The v2.3
# "+90" made a tall empty slab ("这里长出来这么多"); it is gone, and
# the badge can never touch the white cards because the card cuts it.
# The other states' 88pt in-card icon is unaffected (it never overflowed).
require(home, "status.clipsToBounds = YES", "status card clips the badge (KSU Card)")
forbid(home, "status.clipsToBounds = NO", "v2.3 complete ring dangling outside the card")
require(home, "checkBadgeView.widthAnchor constraintEqualToConstant:110", "110pt check badge")
require(home, "checkBadgeView.trailingAnchor constraintEqualToAnchor:status.trailingAnchor constant:27",
        "badge frame extends 27pt past the card's right edge (clipped)")
require(home, "checkBadgeView.bottomAnchor constraintEqualToAnchor:status.bottomAnchor constant:31",
        "badge frame extends 31pt past the card's bottom edge (clipped)")
require(home, "statusRow.alignment = UIStackViewAlignmentTop", "right column top-aligned, not stretched")
require(home, "[status.heightAnchor constraintEqualToAnchor:rightColumn.heightAnchor]",
        "green card exactly as tall as the right column")
forbid(home, "rightColumn.heightAnchor constant:90", "v2.3 +90 slab")
require(home, "setCustomSpacing:13 afterView:statusRow", "13pt gap below the row (nothing overflows)")
require(home, "bringSubviewToFront:self.checkBadgeView", "badge drawn above the row")
require(home, "statusIconView.widthAnchor constraintEqualToConstant:88", "other states keep the 88pt in-card icon")


def _const(source, pattern, label):
    m = re.search(pattern, source)
    if not m:
        raise AssertionError(f"missing {label}: {pattern}")
    return float(m.group(1))


# Layout math, not just strings: the green card must be as tall as the
# right column (ratio ~1:1, measured on the KSU reference: 578px vs
# 574px), the badge frame must extend past the card's bounds on the right
# and bottom (that is what the card clips), and the card must clip
# (clipsToBounds = YES) — otherwise the badge is a complete ring dangling
# outside the card again. Parsed from the constraints, so a future edit
# that re-adds the +90 slab, un-clips the card, or moves the badge fails
# this check instead of shipping.
# Geometry: green height == right column height (equal constraint, no
# constant); badge spans [cardRight, cardRight + 27] horizontally and
# [cardBottom, cardBottom + 31] vertically outside the card; the 13pt gap
# below the row is the normal gap, not overflow clearance.
_green_fraction = _const(home, r"multiplier:([0-9.]+)", "green card width fraction")
_row_gap = _const(home, r"statusRow\.spacing = ([0-9.]+)", "status row gap")
_badge = _const(home, r"checkBadgeView\.widthAnchor constraintEqualToConstant:([0-9.]+)", "check badge size")
_overflow_right = _const(home, r"checkBadgeView\.trailingAnchor constraintEqualToAnchor:status\.trailingAnchor constant:(-?[0-9.]+)", "badge right overflow")
_overflow_down = _const(home, r"checkBadgeView\.bottomAnchor constraintEqualToAnchor:status\.bottomAnchor constant:(-?[0-9.]+)", "badge down overflow")
_gap_below = _const(home, r"setCustomSpacing:([0-9.]+) afterView:statusRow", "gap below the status row")
if _badge != 110 or _overflow_right != 27 or _overflow_down != 31:
    raise AssertionError(f"badge geometry is not KSU's 110pt / +27 / +31: {_badge} / {_overflow_right} / {_overflow_down}")
if _overflow_right <= 0 or _overflow_down <= 0:
    raise AssertionError("badge frame does not extend past the card's bounds: nothing for the card to clip")
if _green_fraction != 0.48:
    raise AssertionError(f"green card width fraction is {_green_fraction}, expected 0.48 (measured KSU ~50/50 split)")
if _gap_below != 13:
    raise AssertionError(f"gap below the status row is {_gap_below}, expected 13")
if _row_gap != 13:
    raise AssertionError(f"status row gap is {_row_gap}, expected 13")

# --- Native tab bar (v2.1): standard UITabBarController, iOS 26 Liquid
# Glass — the v2.0 custom floating solid-white capsule bar is gone. ---
tabbar_h = read(APP / "CLTabBarController.h")
require(tabbar_h, "@interface CLTabBarController : UITabBarController", "system tab bar subclass")
require(tabbar, "self.viewControllers = @[homeNav, cleanNav, appsNav, settingsNav]", "four tabs")
require(tabbar, "house.fill", "home tab icon")
require(tabbar, "trash.fill", "clean tab icon")
require(tabbar, "square.grid.2x2.fill", "apps tab icon")
require(tabbar, "gearshape.fill", "settings tab icon")
require(tabbar, "tabBar.tintColor = UIColor.systemBlueColor", "blue tab tint")
require(tabbar, "UINavigationController", "each tab in its own nav controller")
forbid(tabbar, "cornerRadius = 32", "custom capsule bar radius")
forbid(tabbar, "shadowOpacity", "hand-rolled bar shadow")
forbid(tabbar, "additionalSafeAreaInsets", "manual safe-area hack for the floating bar")
forbid(tabbar, "UIButton", "hand-rolled tab buttons")
forbid(tabbar, "imageEdgeInsets", "deprecated button edge insets")
forbid(tabbar, "titleEdgeInsets", "deprecated button edge insets")

# --- Settings: attribution + log without share. ---
for name in ("worse_query", "KAMUI", "WQFiles", "KernelSU", "GestaltX", "3105"):
    require(settings, name, f"settings attribution {name}")
require(settings, "图标风格参考 huamidev/GestaltX（GPL-3.0）", "icon-language credit line")
forbid(log_view, "UIActivityViewController", "log share button")

# --- Icons (v2.2, Filza-style): real icon at native resolution, iOS
# continuous squircle, no stretch, no plain rounded rect anywhere. ---
# v2.3 monochrome: the fallback is a neutral first-letter tile (black on
# cream #F5F1E8), never a coloured symbol block.
ui = read(APP / "CLUI.m")
require(ui, "cornerCurve = kCACornerCurveContinuous", "continuous squircle curve")
require(ui, "0.2237", "squircle radius 22.37% of the side")
require(ui, "contentsScale = scale", "layer renders at device scale, not 1x")
require(ui, "cl_device_scale", "cached device scale for background icon loads")
require(ui, "static const int formats[] = {2, 3, 1, 0, 4};", "icon formats tried largest-first")
require(ui, "cl_letter_tile", "neutral first-letter fallback tile")
require(ui, "0xF5 / 255.0", "cream #F5F1E8 tile background")
forbid(ui, "bezierPathWithRoundedRect", "plain rounded rect (not a squircle)")
forbid(ui, "cl_service_tile", "coloured keyword symbol tiles (v2.2, user: ugly)")

# --- No model-ID strings in list/search UI (v2.3). The device line stays
# for the Log page header only; the home info card shows the marketing name
# only, with the correct iPhone18,x mapping (verified 2026-11-10: 18,1 =
# 17 Pro, 18,2 = 17 Pro Max, 18,3 = 17, 18,4 = Air — v2.2 had them swapped).
forbid(cleaner, "cl_device_header", "device strip under the cleaner search field")
apps_source = read(APP / "CLAppsViewController.m")
forbid(apps_source, "cl_device_header", "device strip under the apps search field")
require(log_view, "cl_device_line", "device line kept for the log header")
require(home, '"iPhone18,2": @"iPhone 17 Pro Max"', "correct 18,2 mapping")
require(home, '"iPhone18,3": @"iPhone 17"', "correct 18,3 mapping")
forbid(home, '"iPhone18,1": @"iPhone 17"', "swapped 18,1 mapping (v2.2)")

# --- App count after cleaning (v2.3 bug, v2.4 fix attempt, v2.5 real fix):
# the home count is DISTINCT BUNDLE IDs, not containers. v2.3 counted
# PluginKitPlugin extension containers (1226); v2.4 counted Application
# containers only, but one app has a Bundle container AND a Data container,
# so the 20:46 screenshot still showed 267. v2.5 keeps a NSMutableSet of
# bundle IDs and reports its count — it must equal the clean-list item
# count (114 on the user's phone) and stay after cleaning.
require(cache, "totalAppCount", "store keeps the total distinct apps")
require(cache, "appBundleIDs", "scanner collects distinct bundle IDs")
require(cache, "totalApps:(NSUInteger)totalApps", "scanner reports the measured app count")
require(cache, "ctx.totalContainers++", "every measured container is counted (progress)")
forbid(cache, "totalAppContainers", "container counting is gone (v2.4 bug: 267)")
require(home, "store.totalAppCount", "home shows the measured total, not the row count")
require(cleaner, "totalApps:totalApps", "cleaner passes the total through")

# --- Scan speed (v2.2): 4 parallel workers, incremental batches, persistent
# measurement cache, one ancestry walk per container. ---
# v2.3: the NSFileManager enumerator is replaced by an fd walk (3105-style:
# fstatat AT_SYMLINK_NOFOLLOW, fdopendir, openat O_NOFOLLOW) that never
# resolves a path through a symlink, and the Caches tree also returns its
# top-5 subdirectory sizes.
require(cache, "dispatch_apply(4,", "bounded 4-worker measurement")
require(cache, "itemsUpdate", "incremental batch delivery")
require(cache, "cl-cache-measure.plist", "persistent measurement cache")
require(cache, "cl_measure_cache_lookup", "measurement cache lookup")
require(cache, "cl_measure_cache_store", "measurement cache store")
require(cache, "CLSafetyContainerTargetsSafe", "combined container+targets safety check")
require(cache, "cl_measure_fd", "fd-based tree walk")
require(cache, "fdopendir", "fd-relative listing")
require(cache, "AT_SYMLINK_NOFOLLOW", "no-follow stat in the walk")
require(cache, "cl_measure_tree_subdirs", "subdir breakdown measurement")
require(cache, "cacheSubdirs", "Caches top-5 subdirectory breakdown")
require(cache, "cl_purge_folder_contents", "per-folder purge helper")
require(cache, "cl_clean_matching_files", "extension/name match cleaner")
forbid(cache, "enumeratorAtURL", "NSFileManager path enumerator replaced by the fd walk")
forbid(cache, "[NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil]",
       "full readdir pass as an access probe")
require(read(CORE / "CLSafety.h"), "CLSafetyContainerTargetsSafe", "combined safety helper declared")
require(cleaner, "itemsUpdate:", "clean page consumes incremental batches")

# --- Apps page: cancelled scans reset state and rescan on appear. ---
apps = read(APP / "CLAppsViewController.m")
require(apps, "扫描已取消", "cancelled app scan resets state")
require(apps, "_lastScanFinished", "apps page tracks finished scans")
# --- Apps page (v2.2): tap goes straight into the app's directory. The old
# backup/restore/clear sheet and its handlers moved to CLAppActions; the
# directory browser is the entry point, not a button behind backup. ---
require(apps, '#import "CLAppDirectoryViewController.h"', "directory browser import")
require(apps, "pushViewController:dir", "tap pushes the directory view")
require(apps, "dir.onDataChanged", "directory actions rescan the list")
require(apps, "点一个应用进入它的目录", "footer describes tap-to-enter")
forbid(apps, 'actionWithTitle:@"备份数据"', "old backup sheet action")
forbid(apps, "cl_clear_app_data", "clear moved to CLAppActions")
directory = read(APP / "CLAppDirectoryViewController.m")
actions = read(APP / "CLAppActions.m")
require(actions, "cl_clear_app_data", "clear goes through the Core function")
require(actions, "cl_make_app_backup", "backup goes through the Core function")
require(actions, "cl_restore_app", "restore goes through the Core function")
require(directory, "cl_path_inside_container", "directory stays inside the app container")
require(directory, "CLSafetyHasNoSymlinkAncestry", "directory checks symlink ancestry")
require(directory, "备份", "backup nav-bar button in the directory view")
require(directory, "恢复备份", "restore action in the directory view")
require(directory, "清空数据", "clear action in the directory view")
require(directory, "initWithApp:", "drill-down into subfolders")
require(directory, "path:entry.path", "drill-down pushes the tapped subfolder")
forbid(directory, "UIActivityViewController", "no sharing from the directory browser")
# --- Directory view (v2.3): swipe a folder to empty it; Caches
# subdirectories show their scanned size. ---
require(directory, "cl_purge_folder_contents", "per-folder clean")
require(directory, "trailingSwipeActionsConfigurationForRowAtIndexPath", "swipe-to-clean action")
require(directory, "cacheSubdirs", "Caches subdirectory sizes from the scan")
require(directory, "左滑文件夹可清空其内容", "footer describes swipe-to-clean")
forbid(directory, "只读浏览", "directory is no longer read-only (folders can be cleaned)")

# --- Custom cleaning (v2.3): rules, presets, excludes; folder rules refuse
# the container root and Documents/Library themselves; extension/name rules
# only touch Library/Caches + tmp. ---
custom = read(CORE / "CLCustomClean.m")
custom_vc = read(APP / "CLCustomCleanViewController.m")
require(custom, "cl_custom_clean_presets", "built-in presets")
require(custom, "cl_custom_clean_validate_folder_pattern", "folder rule validation")
require(custom, "cl_custom_clean_run", "rule execution")
require(custom, "cl_purge_folder_contents", "folder rules purge contents")
require(custom, "cl_clean_matching_files", "extension/name rules match files")
require(custom, "视频缓存", "video cache preset")
require(custom, "图片缓存", "image cache preset")
require(custom, "日志文件", "log files preset")
require(custom, "临时文件", "tmp files preset")
require(custom_vc, "自定义清理", "custom cleaning page")
require(custom_vc, "开始清理", "run button")
require(custom_vc, "添加规则", "add-rule flow")
require(custom_vc, "添加排除", "add-exclude flow")
require(cleaner, "自定义清理…", "custom cleaning entry in the clean page menu")
# --- Custom cleaning (v2.4): finer rules + harder logic. Age filter (only
# files older than N days), size filter (only larger than X / smaller than
# Y), subfolder scope (only under Library/Caches/<name>), dry-run preview
# (matched files + bytes, then confirm), whole-rule validation, and the
# engine re-validates the container identity before every delete with
# per-item accounting (freed / failed / skipped) and idempotent re-runs.
require(custom, "CLCustomRuleMinAgeDaysKey", "age filter key")
require(custom, "CLCustomRuleMinSizeKey", "min-size filter key")
require(custom, "CLCustomRuleMaxSizeKey", "max-size filter key")
require(custom, "CLCustomRuleSubfolderKey", "subfolder scope key")
require(custom, "cl_custom_clean_make_rule_full", "rule constructor with filters")
require(custom, "cl_custom_clean_validate_rule", "whole-rule validation")
require(custom, "cl_custom_clean_dry_run", "dry-run preview")
require(custom, "cl_custom_clean_run_one_rule", "single-rule run from the preview")
require(custom, "cl_custom_clean_run_with_cancellation", "cancellable run")
require(custom, "cl_clean_matching_files_filtered", "filtered match engine")
require(cache, "CLCleanMatchOptions", "filter options struct")
require(cache, "CLCleanMatchResult", "per-item accounting struct")
require(custom_vc, "预览匹配", "rule preview action")
require(custom_vc, "清理这些文件", "dry-run confirm button")

# --- iPhone Shortcuts (v2.4): the App Intent lives in the MAIN APP
# target, not in an extension. With openAppWhenRun = false, iOS
# headless-launches the app process in the background (no scene) and runs
# perform() in-process — the user taps the shortcut and the clean happens
# in the background without opening the app, using the same sandbox grant,
# measurement cache and custom rules as the app itself (no separate
# extension process, no unproven grant flow). AppShortcutsProvider
# pre-registers the shortcut, so it shows up in the Shortcuts app and can
# be bound to the Action Button. The cleaner:// URL scheme stays as a
# fallback (it opens the app + asks for confirmation).
# The old NSExtension/PlugIns form is NOT used: modern App Intents
# extensions are ExtensionKit (@main struct : AppIntentsExtension,
# EXAppExtensionAttributes, Extensions/) — and no extension is needed
# at all here.
intents = read(ROOT / "Intents" / "CleanerIntents.swift")
background = read(CORE / "CLBackgroundClean.m")
require(intents, "struct CleanCacheIntent: AppIntent", "clean intent in the app target")
require(intents, "static var openAppWhenRun: Bool = false", "intent does not open the app")
require(intents, "CLBackgroundCleanRun(25.0)", "intent runs the background clean on a 25 s budget")
require(intents, "struct CleanerShortcuts: AppShortcutsProvider", "pre-built shortcut provider")
require(intents, "CLIntentsBootstrap", "keep-alive bootstrap for the linker")
require(background, "CLBackgroundCleanRun", "background clean entry point")
require(background, "CLCacheValidateItem", "background clean re-validates before purging")
require(background, "cl_custom_clean_run", "background clean runs the enabled custom rules")
require(build, "swiftc", "Swift intent compiled in build.sh")
require(build, "-framework AppIntents", "AppIntents framework linked")
require(build, "Intents/CleanerIntents.swift", "Swift intent source in the build")
require(build, "Core/CLBackgroundClean.m", "background clean in the build")
require(build, "CleanerIntents.o", "Swift object linked into the app binary")
# v2.5: the v2.4 check that used to sit here was FAKE — it only grepped
# build.sh text for "CleanCacheIntent", and build.sh itself only grepped
# the BINARY for the bare name, which survives dead-strip. The verified
# v2.4 binary had 1 bare name string each and ZERO mangled symbols /
# ZERO appShortcuts, and the Shortcuts app found nothing. The real
# checks: build.sh greps the binary for the Swift-mangled symbols
# ($s…V) and the appShortcuts witness, and the guide page reads the
# registered shortcuts through CLCleanerShortcutsInfo. What keeps the
# types linked is the FLAG level, not the data flow: the guide's data
# flow was constant-folded by swiftc -O (run 42823044882), and
# @_optimize(none) on the computed properties plus explicit metatype
# references still lost CleanerShortcuts (runs 42824508382 /
# 42825022774) — so swiftc now uses -Onone and the link drops -flto.
require(build, "-Onone", "swiftc compiles the intent file without optimisation")
require(build, "[$]s[0-9]+CleanerIntents[0-9]+CleanCacheIntentV", "build checks the mangled CleanCacheIntent symbol")
require(build, "[$]s[0-9]+CleanerIntents[0-9]+CleanerShortcutsV", "build checks the mangled CleanerShortcuts symbol")
require(build, "appShortcuts", "build checks the appShortcuts witness in the binary")
# The symbol check must run BEFORE strip: strip -x removes the local
# symbols (v2.4 binary: 415 global, 1 local), so a post-strip symbol grep
# measures strip, not the types — it failed a build that had the types.
if not (build.index("CleanCacheIntentV") < build.index('strip -x "$APP/Cleaner"')):
    raise AssertionError("intent symbol check must come before strip -x")
forbid(build, 'grep -a -q "CleanCacheIntent" "$app_path/Cleaner"', "bare-name grep is gone (it passed on the broken v2.4 binary)")
forbid(build, 'grep -a -q "CleanerShortcuts" "$app_path/Cleaner"', "bare-name grep is gone (it passed on the broken v2.4 binary)")
forbid(build, "# no -dead_strip risk here — main.m references CLIntentsBootstrap, which references the intent types.", "the wrong dead-strip comment is gone")
require(intents, "CLCleanerShortcutsInfo", "shortcuts info exposes the registered shortcuts to UIKit")
require(intents, "CleanerShortcuts.appShortcuts", "intent types are really used: the guide reads the registered shortcuts")
require(main, "[CLIntentsBootstrap keepAlive]", "main keeps the intent types linked")
require(main, "CleanerIntents-Swift.h", "main imports the generated Swift header")
forbid(build, "appex", "no app-extension target")
forbid(build, "PlugIns", "no PlugIns directory: the intent is in the app binary")
require(info, "CFBundleURLTypes", "URL scheme registered (fallback)")
require(info, "<string>cleaner</string>", "cleaner:// scheme")
require(main, "openURLContexts", "scene handles incoming URLs")
require(main, "handleShortcutURL", "URL dispatch to the tab bar")
require(tabbar, "handleShortcutURL", "tab bar deep-links the clean page")
require(tabbar, 'isEqualToString:@"cleaner"', "cleaner:// scheme check")
require(settings, "快捷指令", "shortcuts guide in Settings")
require(settings, "cleaner://clean", "clean URL in Settings")
require(settings, "cleaner://scan", "scan URL in Settings")
require(settings, "不打开应用", "background shortcut copy in Settings")
require(settings, "清理全部缓存", "intent name in Settings")
require(cleaner, "startShortcutAction", "cleaner page shortcut entry point")

# --- Shortcuts guide (v2.5): the user could not find the shortcut at all
# (20:44 screenshot: search "cleaner" in the Shortcuts app → 0 results;
# 20:46: the phone really runs v0.2.4 (1), already opened, still 0 — "not
# installed / never opened" are both ruled out. Root cause, verified on
# the v2.4 binary: -dead_strip deleted the intent types; keepAlive only
# referenced their metadata). The guide page states the preconditions
# first (install 0.2.5, open Cleaner once, let the system index, then
# search), shows a LIVE status read from the real registration (not a
# hardcoded string), and has a button that opens the Shortcuts app.
# "Not found" is NOT reported as fixed until the user finds it on-device
# and taps it once.
guide = read(APP / "CLShortcutsGuideViewController.m")
require(guide, "shortcutTitles", "guide shows the registered shortcut titles")
require(guide, "cl-ui-launched-once", "guide shows whether the app was launched once")
require(guide, "shortcuts://", "button opens the Shortcuts app")
require(guide, "先装 0.2.5", "precondition: install 0.2.5 first")
require(guide, "打开一次 Cleaner", "precondition: open Cleaner once so the system indexes")
require(guide, "重启手机", "fallback: restart the phone to re-index")
require(guide, "不需要服务器", "no-server note in the guide")
require(settings, "CLShortcutsGuideViewController", "Settings opens the guide page")
require(main, "cl-ui-launched-once", "scene launch marks the app as launched once")

# --- Directory picker for custom rules (v2.5): tap 添加规则 opens a NEW
# page (BleachBit's Custom tab + file picker; SD Maid SE's custom-filter
# structure; Filza drill-down). Pick an app, drill into its container,
# choose the scope for the directory shown, confirm with 选择 at the top
# right — the rule joins future cleans (clean page AND the background
# intent). A path can also be typed/pasted. The system file picker cannot
# reach other apps' containers, so the drill-down is in-app.
picker = read(APP / "CLRulePickerViewController.m")
require(picker, "选择目录", "picker page")
require(picker, "清空整个目录", "scope: clear the whole directory")
require(picker, "按条件删", "scope: delete by conditions")
require(picker, "手动输入路径", "manual path entry")
require(picker, "前往", "go to a pasted path")
require(picker, "不能直接选容器根目录", "container root refused")
require(picker, "这个目录不是缓存目录", "user-data warning before confirming")
require(picker, "initWithRule", "edit reopens the picker prefilled")
require(picker, "cl_custom_clean_resolve_pasted_path", "pasted path resolves to app + relative path")
require(picker, "cl_custom_clean_make_directory_rule", "picker saves a directory rule")
require(custom_vc, "CLRulePickerViewController", "add rule opens the picker")
require(custom_vc, "编辑这条规则", "directory rules can be edited")
require(custom, "cl_custom_clean_make_directory_rule", "directory-rule constructor")
require(custom, "CLCustomRuleScopeAll", "directory scope: all")
require(custom, "CLCustomRuleScopeFiltered", "directory scope: filtered")
require(custom, "rootsMayBeAnywhere", "filtered walk lifts the Caches/tmp roots restriction")
require(custom, "cl_custom_clean_resolve_pasted_path", "pasted-path resolution in the engine")

# --- Mode line (v2.5): v2.1's 15pt + max 2 lines did not stop the
# mid-word break ("<App Group> [沙 / 盒模式]" on the 20:46 screenshot).
# The copy is now just "沙盒模式" — short enough to never break.
require(home, "沙盒模式", "mode line is short")
forbid(home, '@"<App Group> [沙盒模式]"', "old mode line that broke mid-word")

# --- Animations (v2.3, redone): scan batches insert with a fade, the
# progress bar shows the real scan fraction, cleaning shows a per-row
# spinner and a green check per finished row, the big total counts down
# as cache is freed, and a spring check + haptic lands on success.
# System animation only (UIView spring / CADisplayLink), no custom spinner.
require(cleaner, "insertRowsAtIndexPaths", "scan batches insert with animation")
require(cleaner, "CLCacheScanFraction", "scan progress fraction from N/M")
require(cleaner, "cleanSpinner", "per-row cleaning spinner")
require(cleaner, "animateTotalTo", "total counts down as cache is freed")
require(cleaner, "CADisplayLink", "countdown display link")
require(cleaner, "doneView", "spring success check in the summary card")
require(cleaner, "usingSpringWithDamping", "spring animation for the success check")
require(cleaner, "notificationOccurred", "success haptic")

# --- App entry: tab container root, resolvers set, restore recovery. ---
require(main, "CLTabBarController", "tab bar root")
require(main, "cl_set_container_label_resolver", "container label resolver")
require(main, "cl_set_container_list_provider", "container list provider")
require(main, "cl_recover_interrupted_restore", "interrupted restore recovery")

# --- Build: only the v2 sources, iPhone only, 0.2.5. ---
for source in ("Core/CLGrant.m", "Core/CLScan.m", "Core/CLCache.m", "Core/CLApp.m",
               "Core/CLLaunchServices.m", "Core/CLCustomClean.m", "Core/CLBackgroundClean.m",
               "App/CLUI.m",
               "App/CLCleanerViewController.m", "App/CLAppsViewController.m",
               "App/CLCustomCleanViewController.m", "App/CLAppActions.m",
               "App/CLAppDirectoryViewController.m", "App/CLHomeViewController.m",
               "App/CLSettingsViewController.m", "App/CLLogViewController.m",
               "App/CLRulePickerViewController.m", "App/CLShortcutsGuideViewController.m",
               "App/CLTabBarController.m", "App/main.m"):
    require(build, source, f"build source {source}")
forbid(build, "WQCore.m", "v0.1 build source")
# v2.5: the link keeps -Os (ObjC compile) but drops -flto and
# -dead_strip on purpose. -flto re-optimizes across modules at link time
# and deleted the intent types (runs 42824508382 / 42825022774); swiftc
# uses -Onone for the intent file. Do not re-add -flto or -dead_strip
# without re-verifying the mangled symbols in the built binary.
forbid(build, "-Os -flto", "-flto removed from the link")
forbid(build, "-Os -dead_strip", "dead-strip removed from the link")
# v2.5: the strict check in run_all_tests.sh has its OWN source list — a
# file in build.sh but not there links fine in build.sh and then fails the
# preflight link with undefined symbols (CLRulePickerViewController /
# CLShortcutsGuideViewController in run 42822455960). Both lists must match.
runner = read(ROOT / "tests" / "run_all_tests.sh")
for source in ("App/CLRulePickerViewController.m", "App/CLShortcutsGuideViewController.m"):
    require(runner, source, f"strict-check source {source}")
require(info, "<string>0.2.5</string>", "version 0.2.5")
forbid(info, "<string>0.2.4</string>", "old version 0.2.4")
forbid(info, "CFBundleIcons~ipad", "iPad icon set")
forbid(info, "UISupportedInterfaceOrientations~ipad", "iPad orientations")

# --- No emoji anywhere in the app sources (long-term rule). ---
emoji = re.compile("[\U0001F300-\U0001FAFF\u2600-\u27BF\uFE0F\u200D]")
for path in list(APP.glob("*.m")) + list(APP.glob("*.h")) + \
        list(CORE.glob("*.m")) + list(CORE.glob("*.h")):
    match = emoji.search(path.read_text(encoding="utf-8"))
    if match:
        raise AssertionError(f"emoji found in {path.name}: {match.group(0)!r}")

print("browser UI regression checks: PASS")
