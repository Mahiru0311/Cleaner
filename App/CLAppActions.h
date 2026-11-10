
//
//  CLAppActions.h
//  Cleaner v2.2 — backup / restore / clear flows for one app, shared by the
//  Apps list and the in-app directory browser. Each method runs the work on
//  the io queue, presents the result on `host`, and then calls `completion`
//  so the caller can rescan or refresh its listing. The caller owns any
//  busy UI; nothing here assumes which screen called it.
//

#import <UIKit/UIKit.h>

@class CLAppItem;

NS_ASSUME_NONNULL_BEGIN

@interface CLAppActions : NSObject
// Backs up the app's Documents + Library. Shows the result alert on host.
+ (void)backupApp:(CLAppItem *)app from:(UIViewController *)host
       completion:(void (^_Nullable)(void))completion;
// Restores the app's Documents/Library from a backup (picks one when there
// are several). Shows the result on host.
+ (void)restoreApp:(CLAppItem *)app from:(UIViewController *)host
        sourceView:(nullable UIView *)source
        completion:(void (^_Nullable)(void))completion;
// Asks first, then clears Documents + Library + tmp (optionally backing up
// first). Shows the result on host.
+ (void)confirmClearApp:(CLAppItem *)app from:(UIViewController *)host
             completion:(void (^_Nullable)(void))completion;
@end

NS_ASSUME_NONNULL_END
