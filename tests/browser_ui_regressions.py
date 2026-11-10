#!/usr/bin/env python3
"""Static regression checks for Cleaner v2 (no file browser, no sharing,
no plist/hex editors; KernelSU Miuix home; WQFiles cache cleaner 1:1;
GestaltX icon language; SF Symbols only, no emoji)."""
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

# --- Deleted in v2: file browser, plist editor, hex viewer, sharing/ZIP. ---
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
require(home, "constraintEqualToConstant:110", "110pt check circle")
require(home, "constant:27", "check circle offset 27 right")
require(home, "constant:31", "check circle offset 31 down")
require(home, "@\"已授权\"", "authorised status title")
require(home, "@\"受限\"", "restricted status title")
require(home, "@\"未授权\"", "unauthorised status title")
require(home, "@\"不支持\"", "unsupported status title")
require(home, "runGrantProbe", "grant probe for the restricted state")
require(home, "@\"正在检查…\"", "checking state while probing")
require(home, "去清理", "status card explains before jumping when blocked")
require(home, "@\"重新扫描\"", "power menu rescan action")
require(home, "@\"应用\"", "apps mini card")
require(home, "@\"可清理\"", "reclaimable mini card")
forbid(home, "setTitle:@\"去清理\"", "separate go-to-clean button (status card is the entry)")
require(home, "tag.fill", "version row icon")
require(home, "checkmark.shield.fill", "support-range row icon")
# --- Home layout fixes (v2.1, from the real-device screenshot). ---
# Mode line 15pt / max 2 lines (16pt wrapped mid-word in the narrow card);
# 44pt gap after the status row so the check's 31pt overflow clears the
# info card; green card min height 200 so text and check never collide;
# content bottom -20 (system tab bar owns the safe area now).
require(home, "systemFontOfSize:15 weight:UIFontWeightMedium", "mode line 15pt")
require(home, "numberOfLines = 2", "mode line at most 2 lines")
require(home, "setCustomSpacing:44 afterView:statusRow", "44pt gap after status row")
require(home, "constraintGreaterThanOrEqualToConstant:200", "green card min height 200")
require(home, "constant:-20", "content bottom padding 20")
forbid(home, "constant:-110", "old -110 padding for the deleted floating bar")

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

# --- Apps page: cancelled scans reset state and rescan on appear. ---
apps = read(APP / "CLAppsViewController.m")
require(apps, "扫描已取消", "cancelled app scan resets state")
require(apps, "_lastScanFinished", "apps page tracks finished scans")
require(apps, "cl_clear_app_data", "clear goes through the Core function")

# --- App entry: tab container root, resolvers set, restore recovery. ---
require(main, "CLTabBarController", "tab bar root")
require(main, "cl_set_container_label_resolver", "container label resolver")
require(main, "cl_set_container_list_provider", "container list provider")
require(main, "cl_recover_interrupted_restore", "interrupted restore recovery")

# --- Build: only the v2 sources, iPhone only, 0.2.1. ---
for source in ("Core/CLGrant.m", "Core/CLScan.m", "Core/CLCache.m", "Core/CLApp.m",
               "Core/CLLaunchServices.m", "App/CLUI.m", "App/CLCleanerViewController.m",
               "App/CLAppsViewController.m", "App/CLHomeViewController.m",
               "App/CLSettingsViewController.m", "App/CLLogViewController.m",
               "App/CLTabBarController.m", "App/main.m"):
    require(build, source, f"build source {source}")
forbid(build, "WQCore.m", "v0.1 build source")
require(build, "-Os -flto -dead_strip", "size optimisation flags")
require(info, "<string>0.2.1</string>", "version 0.2.1")
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
