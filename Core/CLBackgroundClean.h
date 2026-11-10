
//
//  CLBackgroundClean.h
//  Cleaner v2.4 — the default clean, runnable without any UI.
//
//  Used by the App Intent (Intents/CleanerIntents.swift): Shortcuts runs
//  the intent in the main app process (headless, no scene — see the Swift
//  file), so this runs in the same process as the app's own clean, with
//  the same sandbox grant, the same 24 h measurement cache and the same
//  custom-rules plist. No extension process is involved, so there is no
//  separate grant to obtain.
//
//  CLBackgroundCleanRun is SYNCHRONOUS on the calling thread — call it off
//  the main thread. It scans (measurement cache first), purges every app's
//  Library/Caches + tmp, then runs the enabled custom rules. The whole run
//  shares one time budget (a Shortcuts intent has roughly a 30 s execution
//  budget): once the budget is spent, no new app is started and the result
//  says so honestly (partial=YES, appsRemaining>0) instead of pretending
//  the clean finished.
//
//  Result dictionary:
//    freed (NSNumber bytes, app clean), customFreed (NSNumber bytes),
//    failed (NSNumber, apps that failed to purge), customFailed,
//    appsCleaned / appsSkipped / appsRemaining / appsTotal (NSNumber),
//    partial (NSNumber BOOL), timedOut (NSNumber BOOL),
//    customSkipped (NSNumber BOOL — custom rules not run, out of time),
//    scanLimited (NSNumber BOOL), duration (NSNumber seconds),
//    error (NSString, only when the scan itself failed).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

NSDictionary *CLBackgroundCleanRun(NSTimeInterval budgetSeconds);

NS_ASSUME_NONNULL_END
