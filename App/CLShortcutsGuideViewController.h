
//
//  CLShortcutsGuideViewController.h
//  Cleaner v2.5 — Shortcuts guide: preconditions, live status, steps.
//
//  Why this page exists (2026-11-10 20:44): the user searched "cleaner"
//  in the Shortcuts app and found nothing. The v2.4 package's intent
//  registration was verified fine — but the v2.4 BINARY had no intent
//  types at all: -O + LTO + -dead_strip deleted them (keepAlive only
//  referenced the type metadata, which the optimizer threw away). v2.5
//  fixes that with a real data flow (CLCleanerShortcutsInfo reads the
//  registered shortcuts and shows their titles here) and a real binary
//  check in build.sh. This page therefore does two things the old alert
//  did not: it states the preconditions (install 0.2.5, open Cleaner
//  once, let the system index, then search), and it shows a LIVE status
//  (does this build actually carry the intent? has this phone launched
//  the app once?) so the user can tell "old version" from "broken
//  registration" themselves.
//  "Not found" is NOT reported as fixed until the user finds it on-device
//  and taps it once.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface CLShortcutsGuideViewController : UITableViewController
@end

NS_ASSUME_NONNULL_END
