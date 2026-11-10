//
//  CLCustomClean.h
//  Cleaner v2.3 — user-defined cleaning rules, presets and excludes.
//
//  Custom cleaning (user-ordered 2026-11-10): pick an app (or all apps) +
//  a folder / file extension / file-name pattern, saved as rules; an
//  exclude list (never clean these apps/folders); four built-in presets.
//  Safety boundary (unchanged from the rest of the app): a folder rule may
//  target any subpath of a container except the container root itself and
//  the top-level Documents / Library; extension and name rules only ever
//  touch Library/Caches + tmp (cl_clean_matching_files enforces that).
//  Deleting an app's data (Documents/Library) stays the backup-first
//  "清空数据" flow in CLAppActions — custom rules never do it.
//  Rule/preset research: docs/GITHUB-RESEARCH-v2.3.md §4.
//

#import <Foundation/Foundation.h>
#import "CLCache.h"

NS_ASSUME_NONNULL_BEGIN

// Rule dictionary keys.
extern NSString *const CLCustomRuleIDKey;        // UUID string
extern NSString *const CLCustomRuleBundleIDKey;  // bundle id, or @"*" for all apps
extern NSString *const CLCustomRuleKindKey;      // @"folder" | @"extension" | @"name"
extern NSString *const CLCustomRulePatternKey;   // folder relative path, ".ext", or substring
extern NSString *const CLCustomRuleEnabledKey;   // NSNumber BOOL

// Preset dictionary keys (from cl_custom_clean_presets).
extern NSString *const CLCustomPresetTitleKey;
extern NSString *const CLCustomPresetDetailKey;
extern NSString *const CLCustomPresetRulesKey;   // NSArray<NSDictionary *> rule dicts

// Rules + excludes, persisted in cl-custom-rules.plist in our Caches.
NSArray<NSDictionary *> *cl_custom_clean_rules(void);
void cl_custom_clean_save_rules(NSArray<NSDictionary *> *rules);
NSArray<NSString *> *cl_custom_clean_excluded_apps(void);
NSArray<NSString *> *cl_custom_clean_excluded_folders(void);
void cl_custom_clean_save_excludes(NSArray<NSString *> *apps, NSArray<NSString *> *folders);

// Four built-in presets: video cache, image cache, log files, tmp files.
NSArray<NSDictionary *> *cl_custom_clean_presets(void);

// One new rule (enabled, fresh UUID).
NSDictionary *cl_custom_clean_make_rule(NSString *bundleID, NSString *kind, NSString *pattern);

// Human-readable one-line summary of a rule, e.g.
// "全部应用 · 扩展 .mp4" / "微信 · 文件夹 Library/Caches/xxx".
NSString *cl_custom_clean_rule_summary(NSDictionary *rule);

// Validate a folder-rule pattern (relative path under a container).
// NO with *reason when it targets the container root, Documents, or Library.
BOOL cl_custom_clean_validate_folder_pattern(NSString *pattern, NSString *_Nullable *_Nullable reason);

// Run all enabled rules against the scanned apps (CLCacheItem array, from
// the shared store). Runs on a background queue; progress/completion are
// called on that queue — the caller hops to main. Result:
// @{@"freed": NSNumber, @"failed": NSNumber,
//   @"perRule": @[@{@"rule": dict, @"freed": NSNumber, @"failed": NSNumber,
//                   @"reason": NSString (optional)}],
//   @"warnings": @[NSString] (non-cache targets that were cleaned)}.
typedef void (^CLCustomCleanProgress)(NSString *status);
void cl_custom_clean_run(NSArray<CLCacheItem *> *apps, CLCustomCleanProgress _Nullable progress,
                         void (^completion)(NSDictionary *result));

NS_ASSUME_NONNULL_END
