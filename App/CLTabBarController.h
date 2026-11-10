//
//  CLTabBarController.h
//  Cleaner v2.1 — standard UITabBarController (iOS 26 native Liquid Glass).
//  4 tabs, each in its own UINavigationController, tint blue — the same
//  pattern as huami GestaltX's plain SwiftUI TabView + .tint(.blue).
//  No custom capsule view, no solid white background, no manual shadow;
//  the system renders the floating glass pill and handles safe-area /
//  content insets, so every page's last row stays reachable.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface CLTabBarController : UITabBarController
@end

NS_ASSUME_NONNULL_END
