
//
//  CLAppDirectoryViewController.h
//  Cleaner v2.2 — read-only drill-down into one app's container. Tap an app
//  on the Apps page and land here directly — no backup/restore sheet in
//  between. Backup / restore / clear are nav-bar actions inside this view
//  (root level only); deeper levels are plain browsing. No editing, no
//  sharing, no Go to Path (the v2 file browser stays dropped otherwise).
//

#import <UIKit/UIKit.h>

@class CLAppItem;

NS_ASSUME_NONNULL_BEGIN

@interface CLAppDirectoryViewController : UITableViewController
- (instancetype)initWithApp:(CLAppItem *)app;
// Root directory of the app (the container); subfolders push another
// instance with the same app and a deeper path.
- (instancetype)initWithApp:(CLAppItem *)app path:(NSString *)path;
// Called after a backup / restore / clear, so the Apps list can rescan.
@property (nonatomic, copy, nullable) void (^onDataChanged)(void);
@end

NS_ASSUME_NONNULL_END
