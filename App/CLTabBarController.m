//
//  CLTabBarController.m
//  Cleaner v2 — custom floating capsule tab bar (Miuix style).
//  White capsule with shadow, 4 tabs: 首页 house.fill, 清理 trash.fill,
//  应用 square.grid.2x2.fill, 设置 gearshape.fill. Selected: blue glyph +
//  blue text on a grey pill; unselected: black solid icons.
//

#import "CLTabBarController.h"
#import "CLHomeViewController.h"
#import "CLCleanerViewController.h"
#import "CLAppsViewController.h"
#import "CLSettingsViewController.h"

@interface CLTabBarController ()
@property (nonatomic, strong) NSArray<UINavigationController *> *tabs;
@property (nonatomic, strong) UIView *bar;
@property (nonatomic, strong) UIView *pill;
@property (nonatomic, strong) NSArray<UIButton *> *buttons;
@property (nonatomic) NSInteger selectedIndex;
@end

@implementation CLTabBarController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;

    CLHomeViewController *home = [CLHomeViewController new];
    __weak typeof(self) weakSelf = self;
    home.goToClean = ^{ [weakSelf setSelectedIndex:1]; };
    CLCleanerViewController *cleaner = [CLCleanerViewController new];
    CLAppsViewController *apps = [CLAppsViewController new];
    CLSettingsViewController *settings = [CLSettingsViewController new];
    self.tabs = @[
        [[UINavigationController alloc] initWithRootViewController:home],
        [[UINavigationController alloc] initWithRootViewController:cleaner],
        [[UINavigationController alloc] initWithRootViewController:apps],
        [[UINavigationController alloc] initWithRootViewController:settings],
    ];
    for (UINavigationController *nav in self.tabs) {
        // Keep content above the floating bar.
        nav.additionalSafeAreaInsets = UIEdgeInsetsMake(0, 0, 92, 0);
    }

    [self buildBar];
    [self setSelectedIndex:0];
}

- (void)buildBar
{
    UIView *bar = [UIView new];
    bar.backgroundColor = UIColor.systemBackgroundColor;
    bar.layer.cornerRadius = 32;
    bar.layer.shadowColor = UIColor.blackColor.CGColor;
    bar.layer.shadowOpacity = 0.12;
    bar.layer.shadowRadius = 12;
    bar.layer.shadowOffset = CGSizeMake(0, 4);
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:bar];
    self.bar = bar;
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [bar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [bar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [bar.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-12],
        [bar.heightAnchor constraintEqualToConstant:64],
    ]];

    UIView *pill = [UIView new];
    pill.backgroundColor = UIColor.systemGray5Color;
    pill.layer.cornerRadius = 20;
    pill.translatesAutoresizingMaskIntoConstraints = NO;
    [bar addSubview:pill];
    self.pill = pill;

    NSArray<NSString *> *icons = @[@"house.fill", @"trash.fill", @"square.grid.2x2.fill", @"gearshape.fill"];
    NSArray<NSString *> *titles = @[@"首页", @"清理", @"应用", @"设置"];
    NSMutableArray<UIButton *> *buttons = [NSMutableArray array];
    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.distribution = UIStackViewDistributionFillEqually;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [bar addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:6],
        [stack.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-6],
        [stack.topAnchor constraintEqualToAnchor:bar.topAnchor constant:6],
        [stack.bottomAnchor constraintEqualToAnchor:bar.bottomAnchor constant:-6],
    ]];
    for (NSInteger i = 0; i < 4; i++) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.tag = i;
        // Icon above label (imageEdgeInsets/titleEdgeInsets are deprecated
        // since iOS 15; the configuration owns the layout now). The
        // configuration must be set before the image/title, or it wipes them.
        UIButtonConfiguration *config = [UIButtonConfiguration plainButtonConfiguration];
        config.imagePlacement = NSDirectionalRectEdgeTop;
        config.imagePadding = 4;
        config.titleTextAttributesTransformer = ^NSDictionary<NSAttributedStringKey, id> * _Nonnull(NSDictionary<NSAttributedStringKey, id> * _Nonnull incoming) {
            NSMutableDictionary *attributes = [incoming mutableCopy];
            attributes[NSFontAttributeName] = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
            return attributes;
        };
        button.configuration = config;
        UIImage *image = [UIImage systemImageNamed:icons[i]];
        [button setImage:image forState:UIControlStateNormal];
        [button setTitle:titles[i] forState:UIControlStateNormal];
        button.tintColor = UIColor.labelColor;
        [button addTarget:self action:@selector(tabTapped:) forControlEvents:UIControlEventTouchUpInside];
        [buttons addObject:button];
        [stack addArrangedSubview:button];
    }
    self.buttons = buttons;
}

- (void)tabTapped:(UIButton *)sender
{
    [self setSelectedIndex:sender.tag];
}

- (void)setSelectedIndex:(NSInteger)index
{
    if (index < 0 || index >= (NSInteger)self.tabs.count) return;
    UIViewController *current = self.childViewControllers.firstObject;
    UINavigationController *next = self.tabs[index];
    if (current == next) {
        [self updateBarAppearanceAnimated:NO];
        return;
    }
    if (current) {
        [current willMoveToParentViewController:nil];
        [current.view removeFromSuperview];
        [current removeFromParentViewController];
    }
    [self addChildViewController:next];
    next.view.frame = self.view.bounds;
    next.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view insertSubview:next.view belowSubview:self.bar];
    [next didMoveToParentViewController:self];
    self.selectedIndex = index;
    // Button frames are needed for the pill position.
    [self.view layoutIfNeeded];
    [self updateBarAppearanceAnimated:YES];
}

- (void)updateBarAppearanceAnimated:(BOOL)animated
{
    void (^apply)(void) = ^{
        for (NSInteger i = 0; i < (NSInteger)self.buttons.count; i++) {
            UIButton *button = self.buttons[i];
            BOOL selected = i == self.selectedIndex;
            UIColor *color = selected ? UIColor.systemBlueColor : UIColor.labelColor;
            button.tintColor = color;
            UIButtonConfiguration *config = button.configuration;
            config.baseForegroundColor = color;
            button.configuration = config;
        }
        UIButton *selected = self.buttons[self.selectedIndex];
        self.pill.frame = CGRectMake(selected.frame.origin.x + 4, 6,
                                     selected.frame.size.width - 8, 52);
    };
    if (animated) {
        [UIView animateWithDuration:0.25 animations:apply];
    } else {
        apply();
    }
}

@end
