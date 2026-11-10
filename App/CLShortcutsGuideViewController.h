
//
//  CLShortcutsGuideViewController.h
//  Cleaner v2.5 — Shortcuts guide: preconditions, live status, steps.
//
//  Why this page exists (2026-11-10 20:44): the user searched "cleaner"
//  in the Shortcuts app and found nothing. The v2.4 package's intent
//  registration was verified fine, and the types WERE in the binary
//  (proven by the __swift5_types descriptors in v2.5) — the 20:46
//  "optimizer removed the types" diagnosis was wrong and is withdrawn;
//  the real on-device cause was never established. v2.6 therefore does
//  not assert a fix: it states the preconditions (install 0.2.6, open
//  Cleaner once, let the system index, then search), shows a LIVE status
//  (does this build actually carry the intent? has this phone launched
//  the app once?) and the LAST RUN (what the shortcut actually did,
//  including whether the app was opened for it), so the user can tell
//  "old version" from "broken registration" themselves — and so the
//  next "it opened the app" report can be told apart from a headless
//  intent run (which was, until v2.6, indistinguishable from the
//  cleaner:// URL scheme opening the app).
//  "Not found" is NOT reported as fixed until the user finds it on-device
//  and taps it once.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface CLShortcutsGuideViewController : UITableViewController
@end

NS_ASSUME_NONNULL_END
