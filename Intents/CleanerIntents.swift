//  CleanerIntents.swift
//  Cleaner v2.4 — App Intent: "清理全部缓存".
//
//  HOW IT RUNS (verified against Apple docs + WWDC 2026-345, and three
//  independent write-ups — see docs/REFACTOR-v2.md §11): the intent is
//  compiled into the MAIN APP target, not into a separate extension.
//  With openAppWhenRun = false, iOS headless-launches the Cleaner process
//  in the background (no scene, no UI) when the app isn't running, and
//  runs perform() in-process. The user taps the shortcut and the clean
//  happens in the background — the app never opens. That is exactly what
//  the user asked for ("不需要打开应用，直接点击快捷方式，它就会自动
//  清理，我的意思是在后台").
//
//  There is deliberately NO App Intents extension target: an extension
//  would run in a separate process, and the sandbox grant (worse_query
//  container_query, issued in the app process) would have to be
//  re-obtained there — unverified. In the app process the grant is the
//  same one v2/v2.3 already proved on-device, and the intent shares the
//  app's 24 h measurement cache and custom-rules plist for free.
//
//  HEADLESS SELF-CONTAINMENT (v2.6, verified by reading the code — the
//  on-device proof is the diagnostics below): CLBackgroundCleanRun
//  touches nothing that needs a scene or a UI. The grant is obtained
//  in-process (container_query via the App Group entitlement, same call
//  the UI clean uses); the measurement cache and the custom-rules plist
//  live in the app's own Caches directory, which is the same directory
//  in a headless launch (same app, same container); the scan, the purge
//  and the rules all run on background queues; main() only calls
//  keepAlive, sets the container resolvers and starts UIApplicationMain
//  — the scene delegate (and its URL handling) never runs without a
//  scene. What headless launch DOES need: the App Group entitlement
//  intact (re-signing must keep it) and the app NOT force-quit — see
//  below. It does NOT need the app open, in the background, or ever
//  launched before in this boot beyond the one first launch that lets
//  the system index the shortcut.
//
//  FORCE-QUIT CAVEAT (v2.6, honest platform limit, also stated in the
//  guide): if the user force-quits Cleaner (swipes it away in the app
//  switcher), iOS will not relaunch it in the background until it is
//  opened again — a force-quit is the user telling the system to leave
//  the app alone. Normal suspended background is fine and needs no
//  action. If a shortcut tap does nothing at all, check this first.
//
//  DIAGNOSTICS (v2.6): every run is recorded in the App Group
//  (cl_intent_last_run, Core/CLBackgroundClean.m) with the time, freed
//  bytes, apps cleaned/remaining, partial/timeout, and whether the run
//  was headless (no connected scene) or the app was already alive. The
//  Settings guide shows the last run, so the next "it opened the app"
//  report can be told apart from "the intent ran headless".
//
//  Execution budget: a Shortcuts intent with openAppWhenRun = false has
//  roughly a 30 s budget (the headless-app background-task cap), so the
//  clean stops starting new apps after 25 s and reports partial progress
//  honestly (appsRemaining > 0) instead of pretending it finished. A
//  re-run is cheap — the measurement cache is warm and the already-clean
//  apps measure ~0.
//
//  CLIntentsBootstrap.keepAlive() is called from main.m. Whether
//  keepAlive alone keeps the types linked was never actually proven:
//  the v2.4 "optimizer removed the types" conclusion rested on greps
//  for the LITERAL mangled names ("CleanerShortcutsV", "appShortcuts"),
//  which never appear in any binary — Swift's mangler substitutes the
//  word "Cleaner" (see build.sh). The v2.5 diagnostic dump (run
//  42825889428) proved the types ARE in the linked binary. What
//  guarantees it stays that way is the pre-strip check in build.sh,
//  which greps the real (word-substituted) mangled symbols. The guide
//  page still reads the registered shortcuts through
//  CLCleanerShortcutsInfo below, so the user can see the live status.

import AppIntents
import Foundation
import UIKit

struct CleanCacheIntent: AppIntent {
    static var title: LocalizedStringResource = "清理全部缓存"
    static var description = IntentDescription("在后台清理全部应用的缓存和临时文件，并执行已启用的自定义规则，无需打开 Cleaner。")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        // Headless means: no scene is connected — the app was not open
        // (and not even alive in the background) when the shortcut ran.
        // A suspended app still has its scene, so this is false then.
        let headless = await MainActor.run { UIApplication.shared.connectedScenes.isEmpty }
        // The clean does filesystem work synchronously — run it off the
        // intent's thread on a background queue.
        let result: [String: Any] = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let raw = CLBackgroundCleanRun(25.0)
                continuation.resume(returning: raw as? [String: Any] ?? [:])
            }
        }
        let freed = (result["freed"] as? NSNumber)?.uint64Value ?? 0
        let customFreed = (result["customFreed"] as? NSNumber)?.uint64Value ?? 0
        let totalFreed = freed + customFreed
        let appsCleaned = (result["appsCleaned"] as? NSNumber)?.intValue ?? 0
        let appsRemaining = (result["appsRemaining"] as? NSNumber)?.intValue ?? 0
        let appsTotal = (result["appsTotal"] as? NSNumber)?.intValue ?? 0
        let failed = (result["failed"] as? NSNumber)?.intValue ?? 0
        let partial = (result["partial"] as? NSNumber)?.boolValue ?? false
        let error = result["error"] as? String
        // Record the run in the App Group before answering, so the
        // Settings guide can show what actually happened (including the
        // error case — a failed run is still a run).
        var record: [String: Any] = [
            "freed": totalFreed, "customFreed": customFreed,
            "appsCleaned": appsCleaned, "appsRemaining": appsRemaining,
            "appsTotal": appsTotal, "failed": failed,
            "partial": partial,
            "timedOut": (result["timedOut"] as? NSNumber)?.boolValue ?? false,
            "duration": (result["duration"] as? NSNumber)?.doubleValue ?? 0,
            "headless": headless,
        ]
        if let error = error { record["error"] = error }
        cl_intent_record_run(record as NSDictionary)
        let sizeText = ByteCountFormatter.string(fromByteCount: Int64(totalFreed), countStyle: .file)
        if let error = error {
            return .result(dialog: "清理失败：\(error)")
        }
        if partial {
            return .result(dialog: "已释放 \(sizeText)（部分完成：已清理 \(appsCleaned) 个应用，还有 \(appsRemaining) 个未清理，\(failed) 个失败），请再运行一次。")
        }
        if appsTotal > 0 {
            return .result(dialog: "已释放 \(sizeText)，清理了 \(appsCleaned) 个应用。")
        }
        return .result(dialog: "已释放 \(sizeText)。")
    }
}

// Pre-built shortcut, so the action shows up in the Shortcuts app (and
// can be bound to the Action Button) without the user building one by
// hand. AppShortcutsProvider only exists in the app target — another
// reason the intent lives here, not in an extension.
struct CleanerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CleanCacheIntent(),
            phrases: ["用 \(.applicationName) 清理全部缓存", "在 \(.applicationName) 里清理缓存"],
            shortTitle: "清理全部缓存",
            systemImageName: "trash"
        )
    }
}

// Keeps the intent types linked: called once from main.m. The system
// discovers intents by scanning the binary, and no app code references
// them — without this, -dead_strip could drop them.
@objc(CLIntentsBootstrap)
public final class CLIntentsBootstrap: NSObject {
    @objc public static func keepAlive() {
        _ = CleanCacheIntent.self
        _ = CleanerShortcuts.self
    }
}

// v2.5 — the Settings Shortcuts guide reads the registered shortcuts
// through this class and shows their titles on screen. @_optimize(none)
// and the explicit metatype references below are kept as belt and
// braces, but they are NOT what keeps the types linked: five v2.5 builds
// "lost" CleanerShortcuts at the build check while the types were present
// all along — the check grepped for literal mangled names that Swift's
// word substitution never emits (see build.sh). The pre-strip check in
// build.sh, grepping the real mangled symbols, is the real protection:
// if a future change really drops the types, the build fails loudly
// instead of shipping a shortcut the Shortcuts app cannot see.
@objc(CLCleanerShortcutsInfo)
public final class CLCleanerShortcutsInfo: NSObject {
    // @_optimize(none) is kept (harmless, and it stops the methods being
    // constant-folded), but it is not load-bearing: the types survive
    // because they are genuinely referenced, and the build verifies the
    // real mangled symbols pre-strip.
    @_optimize(none)
    @objc public static var shortcutCount: Int {
        // Explicit metatype references (belt and braces — the data flow
        // below already references both types).
        _ = CleanerShortcuts.self
        _ = CleanCacheIntent.self
        return CleanerShortcuts.appShortcuts.count
    }
    @_optimize(none)
    @objc public static var shortcutTitles: [String] {
        // AppShortcut does not expose shortTitle for reading (it is only
        // an initializer parameter), so the display title comes from the
        // intent itself — the same string the Shortcuts app shows for the
        // action. There is one title per REGISTERED shortcut, so the count
        // still comes from the provider: an empty provider shows as empty
        // here, which is exactly what the guide page's live status needs.
        _ = CleanerShortcuts.self
        _ = CleanCacheIntent.self
        return CleanerShortcuts.appShortcuts.map { _ in String(localized: CleanCacheIntent.title) }
    }
}
