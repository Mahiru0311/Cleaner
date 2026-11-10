//
//  CLCustomClean.h
//  Cleaner v2.3 — user-defined cleaning rules, presets and excludes.
//
//  Custom cleaning (user-ordered 2026-11-10): pick an app (or all apps) +
//  a folder / file extension / file-name pattern, saved as rules; an
//  exclude list (never clean these apps/folders); four built-in presets.
//  v2.4: extension/name rules can also filter by file age (only older
//  than N days), size (only larger than X / smaller than Y) and subfolder
//  (only under Library/Caches/<name>), and every rule can be dry-run
//  first (preview matched files + bytes, then confirm).
//  v2.5: directory rules (kind @"directory") — the user picks a directory
//  in the picker page (drill-down, or pastes a path) and chooses a scope:
//  purge the whole directory, or delete only files matching conditions
//  (extensions / name / age / size) inside that directory. A directory
//  rule may target any subpath of a container except the container root
//  itself and the top-level Documents / Library; a target outside
//  Library/Caches + tmp is allowed but warned about (user data).
//  Safety boundary (unchanged from the rest of the app): a folder rule may
//  target any subpath of a container except the container root itself and
//  the top-level Documents / Library; extension and name rules only ever
//  touch Library/Caches + tmp (cl_clean_matching_files enforces that).
//  Deleting an app's data (Documents/Library) stays the backup-first
//  "清空数据" flow in CLAppActions — custom rules never do it.
//  Rule/preset research: docs/GITHUB-RESEARCH-v2.3.md §4,
//  directory-picker research: docs/GITHUB-RESEARCH-v2.5.md §2–§3
//  (BleachBit Custom tab, SD Maid SE custom filters, Filza drill-down).
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
// v2.4 filters (extension/name rules only; absent = no filter).
extern NSString *const CLCustomRuleMinAgeDaysKey;  // NSNumber days: only files older than this
extern NSString *const CLCustomRuleMinSizeKey;     // NSNumber bytes: only files at least this big
extern NSString *const CLCustomRuleMaxSizeKey;     // NSNumber bytes: only files at most this big
extern NSString *const CLCustomRuleSubfolderKey;   // NSString: only under this subfolder
                                                   // (e.g. "Library/Caches/com.foo", or a bare
                                                   // name = a subfolder of Library/Caches)
// v2.5 directory rules (kind @"directory", picked in CLRulePickerViewController):
// pattern = the container-relative directory path (e.g. "Library/Caches/xxx"
// or "Documents/Downloads"). scope = @"all" (purge the whole directory's
// contents, like a folder rule) or @"filtered" (delete only files matching
// the conditions below, inside that directory). A filtered rule must carry
// at least one condition; a scope-all rule must carry none (refused, never
// silently ignored — the v2.4 folder-rule principle).
extern NSString *const CLCustomRuleScopeKey;       // @"all" | @"filtered"
extern NSString *const CLCustomRuleScopeAll;       // @"all"
extern NSString *const CLCustomRuleScopeFiltered;  // @"filtered"
extern NSString *const CLCustomRuleExtensionsKey;  // NSString CSV, e.g. ".mp4,.mov"
extern NSString *const CLCustomRuleNameKey;        // NSString filename substring

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

// One new rule with v2.4 filters (any filter may be nil = no filter).
NSDictionary *cl_custom_clean_make_rule_full(NSString *bundleID, NSString *kind, NSString *pattern,
                                             NSNumber *_Nullable minAgeDays, NSNumber *_Nullable minSize,
                                             NSNumber *_Nullable maxSize, NSString *_Nullable subfolder);

// One new directory rule (v2.5): the directory was picked in the picker.
// scope @"all" ignores the conditions (pass nil); scope @"filtered" needs
// at least one condition (extensions CSV, name substring, age, size).
NSDictionary *cl_custom_clean_make_directory_rule(NSString *bundleID, NSString *pattern, NSString *scope,
                                                  NSString *_Nullable extensionsCSV, NSString *_Nullable name,
                                                  NSNumber *_Nullable minAgeDays, NSNumber *_Nullable minSize,
                                                  NSNumber *_Nullable maxSize);

// Resolve a pasted/typed directory path to an app + container-relative
// path. Accepts an absolute path (e.g. copied from the directory view's
// "复制路径": the container it belongs to is found among the scanned apps)
// or a relative path under the given app (bundleID may be nil when the
// path is absolute). NO with *reason when the path belongs to no scanned
// app, escapes the container, or is the container root itself.
// The out params are only set on YES.
BOOL cl_custom_clean_resolve_pasted_path(NSString *path, NSArray<CLCacheItem *> *apps,
                                        NSString *_Nullable bundleID,
                                        NSString *_Nullable *_Nullable bundleIDOut,
                                        NSString *_Nullable *_Nullable relativeOut,
                                        NSString *_Nullable *_Nullable reason);

// Split an extensions CSV (".mp4,.mov" — commas, Chinese commas and spaces
// all separate) into a normalized array (each starts with ".", lowercased).
// Empty entries are dropped; an empty result is an empty array, not nil.
NSArray<NSString *> *cl_custom_clean_parse_extensions(NSString *_Nullable csv);

// Human-readable one-line summary of a rule, e.g.
// "全部应用 · 扩展 .mp4" / "微信 · 文件夹 Library/Caches/xxx".
NSString *cl_custom_clean_rule_summary(NSDictionary *rule);

// v2.6: the summary split for the two-line rule cell. The title is the
// rule itself (app + directory/kind + scope); the filters line is the
// conditions only ("扩展 .mp4,.mov · 名字含 thumb · 30天前 · >1KB"), or
// nil when the rule has no filters. The summary is title + filters.
NSString *cl_custom_clean_rule_title(NSDictionary *rule);
NSString *_Nullable cl_custom_clean_rule_filters_text(NSDictionary *rule);

// Validate a folder-rule pattern (relative path under a container).
// NO with *reason when it targets the container root, Documents, or Library.
BOOL cl_custom_clean_validate_folder_pattern(NSString *pattern, NSString *_Nullable *_Nullable reason);

// Validate a whole rule (kind + pattern + age/size/subfolder filters).
// Folder rules refuse filters (they purge a whole folder's contents).
// NO with *reason on any problem; the rule is never executed when invalid.
BOOL cl_custom_clean_validate_rule(NSDictionary *rule, NSString *_Nullable *_Nullable reason);

// Run all enabled rules against the scanned apps (CLCacheItem array, from
// the shared store). Runs on a background queue; progress/completion are
// called on that queue — the caller hops to main. Result:
// @{@"freed": NSNumber, @"failed": NSNumber, @"skipped": NSNumber
//   (pattern-matched but filtered out by age/size),
//   @"matched": NSNumber, @"matchedBytes": NSNumber,
//   @"cancelled": NSNumber BOOL,
//   @"perRule": @[@{@"rule": dict, @"freed": NSNumber, @"failed": NSNumber,
//                   @"skipped": NSNumber, @"matched": NSNumber,
//                   @"matchedBytes": NSNumber, @"sample": @[NSString],
//                   @"apps": NSNumber, @"reason": NSString (optional)}],
//   @"warnings": @[NSString] (non-cache targets that were cleaned)}.
typedef void (^CLCustomCleanProgress)(NSString *status);
void cl_custom_clean_run(NSArray<CLCacheItem *> *apps, CLCustomCleanProgress _Nullable progress,
                         void (^completion)(NSDictionary *result));

// Cancellable run (the plain run calls this with nil cancellation). A
// cancelled run stops between apps; what was already deleted stays
// deleted, the rest is left for the next run (interrupt safe).
void cl_custom_clean_run_with_cancellation(NSArray<CLCacheItem *> *apps,
                                           CLScanCancellation *_Nullable cancellation,
                                           CLCustomCleanProgress _Nullable progress,
                                           void (^completion)(NSDictionary *result));

// Dry-run preview for ONE rule: what it would delete, without deleting
// anything. Result: @{@"matched": NSNumber, @"bytes": NSNumber,
// @"sample": @[NSString] (up to 50, "App name · relative/path"),
// @"skipped": NSNumber, @"apps": NSNumber, @"failed": NSNumber,
// @"reason": NSString (optional), @"warnings": @[NSString]}.
void cl_custom_clean_dry_run(NSArray<CLCacheItem *> *apps, NSDictionary *rule,
                             CLCustomCleanProgress _Nullable progress,
                             void (^completion)(NSDictionary *result));

// Run ONE rule (the dry-run preview's confirm button). Result: the same
// per-rule entry as the full run, plus @"warnings".
void cl_custom_clean_run_one_rule(NSArray<CLCacheItem *> *apps, NSDictionary *rule,
                                  CLCustomCleanProgress _Nullable progress,
                                  void (^completion)(NSDictionary *result));

#ifdef CL_ACCESS_TESTING
// Tests only: redirect the rules plist (default: our Caches directory).
// Lets the regression tests exercise save/load/edit/delete without
// touching the real plist.
void cl_custom_clean_set_plist_path_for_testing(NSString *_Nullable path);
#endif

NS_ASSUME_NONNULL_END
