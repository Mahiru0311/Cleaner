
//
//  CLRulePickerViewController.h
//  Cleaner v2.5 — directory picker for custom rules.
//
//  The user asked for this page directly (2026-11-10): tap 添加规则 and a
//  NEW page opens — a file-picker page. Pick an app, drill into its
//  container (Filza-style, folders first), choose the scope for the
//  directory shown (clear the whole directory, or delete only files
//  matching conditions: extension / name / age / size), then confirm with
//  选择 at the top right — the rule joins future cleaning (clean page and
//  the background shortcut). A path can also be typed or pasted.
//  Research: docs/GITHUB-RESEARCH-v2.5.md §2–§3 (BleachBit's Custom tab +
//  file picker, SD Maid SE's custom-filter structure, Filza drill-down;
//  the system file picker cannot reach other apps' containers, so the
//  drill-down is in-app).
//
//  The scope belongs to the directory on screen: drilling deeper opens a
//  new instance of this page for the subfolder, and 选择 there confirms
//  that subfolder. Editing a rule reopens the picker prefilled.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class CLCacheItem;

@interface CLRulePickerViewController : UITableViewController <UISearchBarDelegate>
// New rule.
- (instancetype)init;
// Drill into a subfolder of an app's container (used by the picker itself).
- (instancetype)initWithApp:(CLCacheItem *)app path:(NSString *)path;
// Edit an existing rule (prefilled; saving replaces it, same UUID).
// Only directory rules (and folder rules, treated as scope-all directory
// rules) can be edited here; the caller checks the kind first.
- (instancetype)initWithRule:(NSDictionary *)rule;
// Called after the rule is saved (new or edited).
@property (nonatomic, copy, nullable) void (^onSaved)(void);
@end

NS_ASSUME_NONNULL_END
