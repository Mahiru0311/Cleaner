//
//  CLTabBarController.h
//  Cleaner v2.1 — standard UITabBarController (iOS 26 native Liquid Glass).
//  4 tabs, each in its own UINavigationController, tint blue — the same
//  pattern as huami GestaltX's plain SwiftUI TabView + .tint(.blue).
//  No custom capsule view, no solid white background, no manual shadow;
//  the system renders the floating glass pill and handles safe-area /
//  content insets, so every page's last row stays reachable.
//  v2.6: also the tab bar's delegate (crossfade on tab select, except
//  the cleaner tab — its clean animation must not be disturbed).
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface CLTabBarController : UITabBarController <UITabBarControllerDelegate>

// iPhone Shortcuts (v2.3, URL scheme cleaner://): cleaner://clean jumps to
// the clean page and starts a clean (with the usual confirm dialog);
// cleaner://scan jumps to the clean page and rescans. Handled on-device;
// no server is involved.
- (void)handleShortcutURL:(NSURL *)url;

@end

NS_ASSUME_NONNULL_END
