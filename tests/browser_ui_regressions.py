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
require(home, "0xDFFAE4", "green status card #DFFAE4")
require(home, "0x36 / 255.0 green:0xD1 / 255.0 blue:0x67", "check circle #36D167")
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
require(home, "tag.fill", "version row icon")
require(home, "checkmark.shield.fill", "support-range row icon")
# --- Home layout fixes (v2.1, from the real-device screenshot). ---
# Mode line 15pt / max 2 lines (16pt wrapped mid-word in the narrow card);
# content bottom -20 (system tab bar owns the safe area now).
require(home, "systemFontOfSize:15 weight:UIFontWeightMedium", "mode line 15pt")
require(home, "numberOfLines = 2", "mode line at most 2 lines")
require(home, "constant:-20", "content bottom padding 20")
forbid(home, "constant:-110", "old -110 padding for the deleted floating bar")
# --- Home layout fixes (v2.2, from the v2.1 real-device screenshot). ---
# The power button did nothing: deleted, rescan is pull-to-refresh now.
# The check circle no longer overflows the card at all: KSU's (27, 31)
# overflow cannot work here — the gap to the right column is 13pt, so any
# rightward overflow of 13pt+ intersects the white card, which is drawn on
# top (the v2.1 screenshot showed the circle's right half hidden under it).
# v2.2 anchors the 88pt circle fully inside the card, 12pt from the right
# and bottom edges; the gap below the status row is the standard 13pt.
forbid(home, "powerTapped", "deleted power button action")
forbid(home, 'systemImageNamed:@"power"', "deleted power button icon")
forbid(home, "constant:27", "KSU check-circle overflow right (collides with white card)")
forbid(home, "constant:31", "KSU check-circle overflow down (collides with info card)")
forbid(home, "setCustomSpacing:44 afterView:statusRow", "v2.1 44pt gap for the overflowing circle")
forbid(home, "constraintGreaterThanOrEqualToConstant:200", "v2.1 green card min height 200")
require(home, "userRefresh", "pull-to-refresh rescan")
require(home, "scroll.refreshControl = refresh;", "home refresh control")
require(home, "constraintEqualToConstant:88", "88pt check circle")
require(home, "constant:-32", "content width for 16pt side margins")
require(home, "setCustomSpacing:13 afterView:statusRow", "13pt gap after status row")
require(home, "constraintGreaterThanOrEqualToConstant:212", "green card min height 212")


def _const(source, pattern, label):
    m = re.search(pattern, source)
    if not m:
        raise AssertionError(f"missing {label}: {pattern}")
    return float(m.group(1))


# Layout math, not just strings: the check circle frame must be strictly
# inside the green card and must not intersect either right-column card, for
# any row width. Parsed from the constraints, so a future edit that moves
# the circle back outside fails this check instead of shipping.
_green_fraction = _const(home, r"multiplier:([0-9.]+)", "green card width fraction")
_row_gap = _const(home, r"statusRow\.spacing = ([0-9.]+)", "status row gap")
_circle = _const(home, r"statusIconView\.widthAnchor constraintEqualToConstant:([0-9.]+)", "check circle size")
_inset_right = -_const(home, r"statusIconView\.trailingAnchor constraintEqualToAnchor:status\.trailingAnchor constant:(-?[0-9.]+)", "check circle right inset")
_inset_bottom = -_const(home, r"statusIconView\.bottomAnchor constraintEqualToAnchor:status\.bottomAnchor constant:(-?[0-9.]+)", "check circle bottom inset")
_min_height = _const(home, r"constraintGreaterThanOrEqualToConstant:([0-9.]+)", "green card min height")
if _inset_right < 0 or _inset_bottom < 0:
    raise AssertionError("check circle overflows the green card instead of sitting inside it")
for _width in (300, 400, 500):
    _green_right = _width * _green_fraction
    _white_left = _green_right + _row_gap
    _circle_right = _green_right - _inset_right
    if not _circle_right < _white_left:
        raise AssertionError(f"check circle intersects the right column at row width {_width}")
    _circle_top = _min_height - _inset_bottom - _circle
    if _circle_top < 100:
        raise AssertionError("check circle collides with the three text lines (~97pt)")

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
for name in ("worse_query", "KAMUI", "WQFiles", "KernelSU", "GestaltX"):
    require(settings, name, f"settings attribution {name}")
require(settings, "图标风格参考 huamidev/GestaltX（GPL-3.0）", "icon-language credit line")
forbid(log_view, "UIActivityViewController", "log share button")

# --- Icons (v2.2, Filza-style): real icon at native resolution, iOS
# continuous squircle, no stretch, no plain rounded rect anywhere. ---
ui = read(APP / "CLUI.m")
require(ui, "cornerCurve = kCACornerCurveContinuous", "continuous squircle curve")
require(ui, "0.2237", "squircle radius 22.37% of the side")
require(ui, "contentsScale = scale", "layer renders at device scale, not 1x")
require(ui, "cl_device_scale", "cached device scale for background icon loads")
require(ui, "static const int formats[] = {2, 3, 1, 0, 4};", "icon formats tried largest-first")
forbid(ui, "bezierPathWithRoundedRect", "plain rounded rect (not a squircle)")

# --- Scan speed (v2.2): 4 parallel workers, incremental batches, persistent
# measurement cache, one ancestry walk per container, cheap open() probe. ---
require(cache, "dispatch_apply(4,", "bounded 4-worker measurement")
require(cache, "itemsUpdate", "incremental batch delivery")
require(cache, "cl-cache-measure.plist", "persistent measurement cache")
require(cache, "cl_measure_cache_lookup", "measurement cache lookup")
require(cache, "cl_measure_cache_store", "measurement cache store")
require(cache, "CLSafetyContainerTargetsSafe", "combined container+targets safety check")
require(cache, "O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_CLOEXEC", "cheap open() access probe")
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

# --- App entry: tab container root, resolvers set, restore recovery. ---
require(main, "CLTabBarController", "tab bar root")
require(main, "cl_set_container_label_resolver", "container label resolver")
require(main, "cl_set_container_list_provider", "container list provider")
require(main, "cl_recover_interrupted_restore", "interrupted restore recovery")

# --- Build: only the v2 sources, iPhone only, 0.2.2. ---
for source in ("Core/CLGrant.m", "Core/CLScan.m", "Core/CLCache.m", "Core/CLApp.m",
               "Core/CLLaunchServices.m", "App/CLUI.m", "App/CLCleanerViewController.m",
               "App/CLAppsViewController.m", "App/CLAppActions.m",
               "App/CLAppDirectoryViewController.m", "App/CLHomeViewController.m",
               "App/CLSettingsViewController.m", "App/CLLogViewController.m",
               "App/CLTabBarController.m", "App/main.m"):
    require(build, source, f"build source {source}")
forbid(build, "WQCore.m", "v0.1 build source")
require(build, "-Os -flto -dead_strip", "size optimisation flags")
require(info, "<string>0.2.2</string>", "version 0.2.2")
forbid(info, "<string>0.2.1</string>", "old version 0.2.1")
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
