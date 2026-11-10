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
//  Execution budget: a Shortcuts intent with openAppWhenRun = false has
//  roughly a 30 s budget (the headless-app background-task cap), so the
//  clean stops starting new apps after 25 s and reports partial progress
//  honestly (appsRemaining > 0) instead of pretending it finished. A
//  re-run is cheap — the measurement cache is warm and the already-clean
//  apps measure ~0.
//
//  CLIntentsBootstrap.keepAlive() is called from main.m, but keepAlive
//  alone does NOT keep the types linked (v2.4 lesson): under -O + LTO +
//  -dead_strip the optimizer deleted the side-effect-free metadata
//  references and the intent types vanished from the binary. What keeps
//  them is CLCleanerShortcutsInfo below: the Settings guide reads the
//  registered shortcuts through it and shows their titles, a real data
//  flow to UIKit that the optimizer cannot delete.

import AppIntents
import Foundation

struct CleanCacheIntent: AppIntent {
    static var title: LocalizedStringResource = "清理全部缓存"
    static var description = IntentDescription("在后台清理全部应用的缓存和临时文件，并执行已启用的自定义规则，无需打开 Cleaner。")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
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

// v2.5 — the REAL reason the intent types survive the linker, not
// keepAlive: the Settings Shortcuts guide reads the registered shortcuts
// through this class and shows their titles on screen. keepAlive alone
// did NOT work: in v2.4 it only wrote `_ = CleanCacheIntent.self`, and
// under -O + LTO + -dead_strip the optimizer deleted the side-effect-free
// metadata references and then the types and their protocol conformances
// entirely — the v2.4 binary had no CleanCacheIntent / CleanerShortcuts
// symbols at all (only the 8 CLIntentsBootstrap symbols), and the
// Shortcuts app found nothing. Reading CleanerShortcuts.appShortcuts here
// and returning the titles to a UIKit label is a genuine data flow the
// optimizer cannot delete: the provider, its appShortcuts property, the
// AppShortcut values and the CleanCacheIntent instances inside them must
// all stay linked. Do not "simplify" this back to a keepAlive-only call.
@objc(CLCleanerShortcutsInfo)
public final class CLCleanerShortcutsInfo: NSObject {
    @objc public static var shortcutCount: Int {
        CleanerShortcuts.appShortcuts.count
    }
    @objc public static var shortcutTitles: [String] {
        CleanerShortcuts.appShortcuts.compactMap { shortcut in
            guard let title = shortcut.shortTitle else { return nil }
            return String(localized: title)
        }
    }
}
