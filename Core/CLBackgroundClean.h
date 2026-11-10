
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
//  Intent-run diagnostics (v2.6): every intent run is recorded in the
//  App Group (cl-intent-last-run.plist) so the Settings guide can show
//  what actually happened — the last run's time, freed bytes, apps
//  cleaned/remaining, whether it was partial or timed out, and whether
//  the run was headless (no scene — the app was not open) or the app was
//  already alive. The guide reads it with cl_intent_last_run; nil means
//  no intent run has been recorded yet. A runCount is kept alongside.
//  The record is written by the intent itself (Swift), not by the
//  background clean, because only the intent knows whether the process
//  was headless-launched (UIApplication.connectedScenes is empty).
//  Keys: date, freed, customFreed, appsCleaned, appsRemaining, appsTotal,
//  failed, partial, timedOut, duration, headless, error (optional),
//  runCount.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

NSDictionary *CLBackgroundCleanRun(NSTimeInterval budgetSeconds);

// Record one intent run (info as above; date is filled in when absent).
void cl_intent_record_run(NSDictionary *info);
// The last recorded intent run, or nil when none has been recorded.
NSDictionary *_Nullable cl_intent_last_run(void);

NS_ASSUME_NONNULL_END
