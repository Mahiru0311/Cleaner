//
//  CLCleanerViewController.h
//  Cleaner v2 — cache cleaner page (WQFiles Cache Cleaner 1:1, Chinese).
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface CLCleanerViewController : UITableViewController <UISearchResultsUpdating>

// iPhone Shortcuts (v2.3, URL scheme cleaner://): @"clean" selects all
// cleanable rows and shows the usual confirm dialog; @"scan" rescans.
// If a scan is running when the shortcut fires, the action runs when the
// scan finishes. No server is involved — the URL is handled on-device.
- (void)startShortcutAction:(NSString *)action;

@end

NS_ASSUME_NONNULL_END
