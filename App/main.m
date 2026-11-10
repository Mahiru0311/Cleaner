//
//  main.m
//  Cleaner v2 — entry point. Scene delegate owns a CLTabBarController;
//  no UINavigationController root, no file browser, no sharing.
//

#import <UIKit/UIKit.h>
#import "CLTabBarController.h"
#import "CLApp.h"
#import "CLGrant.h"
#import "CLLaunchServices.h"
#import "CleanerIntents-Swift.h"

@interface CLSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation CLSceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session
       options:(UISceneConnectionOptions *)connectionOptions
{
    UIWindow *window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    window.rootViewController = [CLTabBarController new];
    [window makeKeyAndVisible];
    self.window = window;

    // Recover an interrupted restore from a previous launch, if any.
    NSString *recovery = cl_recover_interrupted_restore();
    if (recovery.length) cl_log(@"%@", recovery);

    // Cold launch from a shortcut (cleaner://clean / cleaner://scan).
    for (UIOpenURLContext *context in connectionOptions.URLContexts) {
        [self handleURLContext:context];
    }
}

// iPhone Shortcuts (v2.3): cleaner://clean and cleaner://scan are handled
// on-device by the tab bar — no server, no network.
- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts
{
    for (UIOpenURLContext *context in URLContexts) [self handleURLContext:context];
}

- (void)handleURLContext:(UIOpenURLContext *)context
{
    CLTabBarController *tabBar = (CLTabBarController *)self.window.rootViewController;
    if ([tabBar isKindOfClass:CLTabBarController.class]) [tabBar handleShortcutURL:context.URL];
}

@end

@interface CLAppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation CLAppDelegate

- (UISceneConfiguration *)application:(UIApplication *)application
    configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession
                                  options:(UISceneConnectionOptions *)options
{
    UISceneConfiguration *config = [[UISceneConfiguration alloc] initWithName:@"Default"
                                                                  sessionRole:connectingSceneSession.role];
    config.delegateClass = CLSceneDelegate.class;
    return config;
}

@end

int main(int argc, char *argv[])
{
    @autoreleasepool {
        // Keep the App Intent types linked (CleanerIntents.swift): the
        // system discovers intents by scanning the binary, and nothing
        // else references them — without this call, -dead_strip could
        // drop them and the shortcut would silently disappear.
        [CLIntentsBootstrap keepAlive];
        cl_set_container_label_resolver(cl_bundle_id_for_container);
        cl_set_container_list_provider(cl_ls_container_paths);
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(CLAppDelegate.class));
    }
}
