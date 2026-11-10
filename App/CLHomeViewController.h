//
//  CLHomeViewController.h
//  Cleaner v2 — Home, 1:1 replica of KernelSU v3.2.5 (Miuix) home, copy changed.
//  See docs/REFACTOR-v2.md §4 and docs/kernelsu-old-home-reference.jpg.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface CLHomeViewController : UIViewController
// Set by the tab bar controller: jumping to the Cleaner tab.
@property (nonatomic, copy, nullable) void (^goToClean)(void);
@end

NS_ASSUME_NONNULL_END
