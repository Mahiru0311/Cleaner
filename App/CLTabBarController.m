//
//  CLTabBarController.m
//  Cleaner v2.1 — standard UITabBarController (iOS 26 native Liquid Glass).
//  Replaces the v2.0 custom floating solid-white capsule bar, which the
//  user rightly called ugly on a real device: it was a solid white pill
//  with a hand-rolled shadow that sat on top of content and hid the last
//  info row. The system tab bar is translucent glass on iOS 26 (floating
//  pill, shrinks on scroll, like GestaltX's TabView), and the system owns
//  the bottom safe-area and content insets — no manual bottom padding
//  on any page.
//

#import "CLTabBarController.h"
#import "CLHomeViewController.h"
#import "CLCleanerViewController.h"
#import "CLAppsViewController.h"
#import "CLSettingsViewController.h"

@implementation CLTabBarController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.tabBar.tintColor = UIColor.systemBlueColor;

    CLHomeViewController *home = [CLHomeViewController new];
    __weak typeof(self) weakSelf = self;
    home.goToClean = ^{ weakSelf.selectedIndex = 1; };
    CLCleanerViewController *cleaner = [CLCleanerViewController new];
    CLAppsViewController *apps = [CLAppsViewController new];
    CLSettingsViewController *settings = [CLSettingsViewController new];

    UINavigationController *homeNav = [[UINavigationController alloc] initWithRootViewController:home];
    homeNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"首页"
                                                       image:[UIImage systemImageNamed:@"house.fill"]
                                                         tag:0];
    UINavigationController *cleanNav = [[UINavigationController alloc] initWithRootViewController:cleaner];
    cleanNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"清理"
                                                        image:[UIImage systemImageNamed:@"trash.fill"]
                                                          tag:1];
    UINavigationController *appsNav = [[UINavigationController alloc] initWithRootViewController:apps];
    appsNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"应用"
                                                       image:[UIImage systemImageNamed:@"square.grid.2x2.fill"]
                                                         tag:2];
    UINavigationController *settingsNav = [[UINavigationController alloc] initWithRootViewController:settings];
    settingsNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"设置"
                                                           image:[UIImage systemImageNamed:@"gearshape.fill"]
                                                             tag:3];
    self.viewControllers = @[homeNav, cleanNav, appsNav, settingsNav];
}

// cleaner://clean and cleaner://scan (v2.3). The URL's host is the action;
// anything else is ignored. Selecting the tab first makes the cleaner
// page's view (and its scan) exist before the action runs.
- (void)handleShortcutURL:(NSURL *)url
{
    if (![[url.scheme lowercaseString] isEqualToString:@"cleaner"]) return;
    NSString *action = url.host.lowercaseString;
    if (![action isEqualToString:@"clean"] && ![action isEqualToString:@"scan"]) return;
    UINavigationController *cleanNav = (UINavigationController *)self.viewControllers[1];
    if (![cleanNav isKindOfClass:UINavigationController.class]) return;
    CLCleanerViewController *cleaner = (CLCleanerViewController *)cleanNav.viewControllers.firstObject;
    if (![cleaner isKindOfClass:CLCleanerViewController.class]) return;
    self.selectedIndex = 1;
    [cleaner startShortcutAction:action];
}

@end
