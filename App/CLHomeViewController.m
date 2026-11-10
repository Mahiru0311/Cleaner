//
//  CLHomeViewController.m
//  Cleaner v2 — Home, 1:1 replica of KernelSU v3.2.5 (Miuix) home, copy changed.
//  Layout (see HomeMiuix.kt StatusCard + the reference screenshot):
//  light-grey background, huge bold title, green status card left (#DFFAE4,
//  88pt check circle INSIDE the card's bottom-right corner, #36D167) + two
//  white mini cards right, one white info card, standard UITabBarController
//  (iOS 26 native Liquid Glass, owned by CLTabBarController since v2.1).
//  v2.2: the power button is gone (it did nothing; rescan is pull-to-refresh
//  now) and the check circle no longer overflows the card — see buildUI.
//  No emoji anywhere; SF Symbols only.
//

#import "CLHomeViewController.h"
#import "CLCache.h"
#import "CLGrant.h"
#import "CLUI.h"
#import <sys/sysctl.h>

static NSString *cl_device_model(void)
{
    size_t size = 0;
    sysctlbyname("hw.machine", NULL, &size, NULL, 0);
    if (size == 0) return @"iPhone";
    char *machine = malloc(size);
    sysctlbyname("hw.machine", machine, &size, NULL, 0);
    NSString *identifier = [NSString stringWithUTF8String:machine];
    free(machine);
    // iPhone 17 family (iPhone18,x); anything else falls back to the raw id.
    NSDictionary *known = @{
        @"iPhone18,1": @"iPhone 17",
        @"iPhone18,2": @"iPhone 17 Pro",
        @"iPhone18,3": @"iPhone 17 Pro Max",
        @"iPhone18,4": @"iPhone Air",
    };
    return known[identifier] ?: identifier ?: @"iPhone";
}

static BOOL cl_system_supported(void)
{
    NSArray<NSString *> *parts = [UIDevice.currentDevice.systemVersion componentsSeparatedByString:@"."];
    NSInteger major = parts.count > 0 ? parts[0].integerValue : 0;
    NSInteger minor = parts.count > 1 ? parts[1].integerValue : 0;
    NSInteger patch = parts.count > 2 ? parts[2].integerValue : 0;
    // Supported: iOS 26.0–26.7.2 and the 27.0–27.2 line (see REFACTOR-v2.md §6).
    if (major == 26) return minor < 7 || (minor == 7 && patch <= 2);
    if (major == 27) return minor <= 2;
    return NO;
}

// Home status: four user-visible states. Checking is transient — the grant
// probe runs once per launch on a background queue.
typedef NS_ENUM(NSInteger, CLHomeState) {
    CLHomeStateChecking,
    CLHomeStateAuthorized,
    CLHomeStateRestricted,
    CLHomeStateUnauthorized,
    CLHomeStateUnsupported,
};

@interface CLHomeViewController ()
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIView *warningCard;
@property (nonatomic, strong) UILabel *warningLabel;
@property (nonatomic, strong) UIView *statusCard;
@property (nonatomic, strong) UILabel *statusTitleLabel;
@property (nonatomic, strong) UILabel *statusModeLabel;
@property (nonatomic, strong) UILabel *statusVersionLabel;
@property (nonatomic, strong) UIImageView *statusIconView;
@property (nonatomic, strong) UILabel *appCountLabel;
@property (nonatomic, strong) UILabel *reclaimableLabel;
@property (nonatomic, strong) UILabel *groupStatusValueLabel;
@property (nonatomic, strong) CLCacheScanner *scanner;
@property (nonatomic) BOOL didStartScan;
@property (nonatomic) CLHomeState state;
@property (nonatomic) BOOL probeStarted;
@property (nonatomic) BOOL probeDone;
@property (nonatomic) BOOL probeRestricted;
@end

@implementation CLHomeViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    [self buildUI];
    [self refreshFromStore];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshFromStore)
                                                 name:CLCacheStoreDidUpdateNotification object:nil];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    if (!self.didStartScan) {
        self.didStartScan = YES;
        [self ensureScan];
    }
    [self refreshStatus];
}

#pragma mark - Data

- (void)ensureScan
{
    CLCacheStore *store = [CLCacheStore shared];
    if (store.lastScanFinished > 0 || store.scanning) return;
    if (!self.scanner) self.scanner = [CLCacheScanner new];
    store.scanning = YES;
    [self.scanner startWithProgress:nil completion:^(NSArray<CLCacheItem *> *items, BOOL limited, NSString *__unused note, BOOL cancelled) {
        if (cancelled) {
            // The Home scan was superseded (e.g. the Cleaner page started
            // its own). Do not touch the store; the other scan owns it now.
            [CLCacheStore shared].scanning = NO;
            return;
        }
        [[CLCacheStore shared] updateWithItems:items limited:limited];
    }];
}

- (void)refreshFromStore
{
    // The store posts its notification off the main thread (scan completion).
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self refreshFromStore]; });
        return;
    }
    CLCacheStore *store = [CLCacheStore shared];
    self.appCountLabel.text = store.lastScanFinished > 0
        ? [NSString stringWithFormat:@"%lu", (unsigned long)store.appCount] : @"–";
    self.reclaimableLabel.text = store.lastScanFinished > 0
        ? cl_size_text(store.totalBytes) : @"–";
    [self.scrollView.refreshControl endRefreshing];
}

// The grant probe: App Group present, but can worse_query actually issue an
// extension? Ask for one on our own container (always grantable when the
// mechanism works). Runs once per launch, off the main thread.
- (void)runGrantProbe
{
    if (self.probeStarted) return;
    self.probeStarted = YES;
    dispatch_async(cl_io(), ^{
        BOOL ok = cl_grant([NSHomeDirectory() stringByResolvingSymlinksInPath]);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.probeRestricted = !ok;
            self.probeDone = YES;
            [self refreshStatus];
        });
    });
}

- (UIColor *)cardColorLight:(uint32_t)light dark:(uint32_t)dark
{
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        uint32_t rgb = traits.userInterfaceStyle == UIUserInterfaceStyleDark ? dark : light;
        return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                               green:((rgb >> 8) & 0xFF) / 255.0
                                blue:(rgb & 0xFF) / 255.0 alpha:1];
    }];
}

- (void)refreshStatus
{
    NSString *version = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"0.2.2";
    BOOL supported = cl_system_supported();
    BOOL hasGroup = cl_app_group() != nil;
    if (!supported) {
        self.state = CLHomeStateUnsupported;
    } else if (!hasGroup) {
        self.state = CLHomeStateUnauthorized;
    } else if (!self.probeDone) {
        self.state = CLHomeStateChecking;
        [self runGrantProbe];
    } else {
        self.state = self.probeRestricted ? CLHomeStateRestricted : CLHomeStateAuthorized;
    }

    switch (self.state) {
        case CLHomeStateAuthorized:
            self.statusCard.backgroundColor = [self cardColorLight:0xDFFAE4 dark:0x1A3825];
            self.statusTitleLabel.text = @"已授权";
            self.statusModeLabel.text = @"<App Group> [沙盒模式]";
            self.statusIconView.image = [UIImage systemImageNamed:@"checkmark.circle"];
            self.statusIconView.tintColor = [UIColor colorWithRed:0x36 / 255.0 green:0xD1 / 255.0 blue:0x67 / 255.0 alpha:1];
            self.warningCard.hidden = YES;
            break;
        case CLHomeStateRestricted:
            self.statusCard.backgroundColor = [self cardColorLight:0xFFF3D6 dark:0x3A2E12];
            self.statusTitleLabel.text = @"受限";
            self.statusModeLabel.text = @"沙盒授权不完整";
            self.statusIconView.image = [UIImage systemImageNamed:@"exclamationmark.triangle.fill"];
            self.statusIconView.tintColor = UIColor.systemOrangeColor;
            self.warningCard.backgroundColor = [self cardColorLight:0xFFF3D6 dark:0x3A2E12];
            self.warningLabel.text = @"App Group 已拿到，但沙盒授权探针失败：worse_query 无法签发访问权限，扫描和清理可能不可用。请重新签名安装，或查看日志。";
            self.warningCard.hidden = NO;
            break;
        case CLHomeStateUnauthorized:
            self.statusCard.backgroundColor = [self cardColorLight:0xF9DEDC dark:0x5C1A1A];
            self.statusTitleLabel.text = @"未授权";
            self.statusModeLabel.text = @"未获得 App Group";
            self.statusIconView.image = [UIImage systemImageNamed:@"exclamationmark.triangle.fill"];
            self.statusIconView.tintColor = UIColor.systemRedColor;
            self.warningCard.backgroundColor = [self cardColorLight:0xF9DEDC dark:0x5C1A1A];
            self.warningLabel.text = @"未获得 App Group 权限，请用保留 App Group 的方式重新签名安装。";
            self.warningCard.hidden = NO;
            break;
        case CLHomeStateUnsupported:
            self.statusCard.backgroundColor = [self cardColorLight:0xF9DEDC dark:0x5C1A1A];
            self.statusTitleLabel.text = @"不支持";
            self.statusModeLabel.text = @"当前系统不受支持";
            self.statusIconView.image = [UIImage systemImageNamed:@"xmark.octagon.fill"];
            self.statusIconView.tintColor = UIColor.systemRedColor;
            self.warningCard.backgroundColor = [self cardColorLight:0xF9DEDC dark:0x5C1A1A];
            self.warningLabel.text = @"当前系统版本不在支持范围内（iOS 26.0–26.7.2 / 27.2）。";
            self.warningCard.hidden = NO;
            break;
        case CLHomeStateChecking:
            self.statusCard.backgroundColor = UIColor.systemGray5Color;
            self.statusTitleLabel.text = @"正在检查…";
            self.statusModeLabel.text = @"正在确认沙盒授权…";
            self.statusIconView.image = [UIImage systemImageNamed:@"hourglass"];
            self.statusIconView.tintColor = UIColor.secondaryLabelColor;
            self.warningCard.hidden = YES;
            break;
    }
    self.statusVersionLabel.text = [NSString stringWithFormat:@"版本：%@", version];
    self.groupStatusValueLabel.text = !hasGroup ? @"未授权"
        : (self.state == CLHomeStateChecking ? @"检查中…"
        : (self.state == CLHomeStateRestricted ? @"受限" : @"正常"));
}

#pragma mark - Actions

// Pull-to-refresh rescan (the v2.0/v2.1 power button did this and nothing
// else, so it was deleted in v2.2). Same work as the old power menu: forget
// the shared scan + name database, re-run the grant probe, rescan.
- (void)userRefresh
{
    [[CLCacheStore shared] invalidateScan];
    self.didStartScan = NO;
    self.probeStarted = NO;
    self.probeDone = NO;
    self.probeRestricted = NO;
    [self refreshStatus];
    [self ensureScan];
    // The spinner stays until the scan reports back: refreshFromStore ends
    // it when the store updates (ending it here would hide it the moment
    // the scan starts).
}

- (void)statusCardTapped
{
    switch (self.state) {
        case CLHomeStateAuthorized:
        case CLHomeStateRestricted:
            // Restricted may still partly work; the Cleaner page shows what
            // actually fails. Authorized goes straight in.
            if (self.goToClean) self.goToClean();
            break;
        case CLHomeStateChecking:
            // Probe in flight; ignore the tap until the state is known.
            break;
        case CLHomeStateUnauthorized:
        case CLHomeStateUnsupported: {
            NSString *title = self.state == CLHomeStateUnauthorized
                ? @"未获得 App Group 权限" : @"当前系统不受支持";
            NSString *message = self.state == CLHomeStateUnauthorized
                ? @"Cleaner 需要 App Group 才能访问其它应用的容器。请用保留 App Group 的方式重新签名安装（AltStore / SideStore 会自动创建）。仍可前往清理页查看，但扫描会失败。"
                : @"当前系统版本不在支持范围内（iOS 26.0–26.7.2 / 27.2），worse_query 可能已被修复。仍可前往清理页查看，但扫描会失败。";
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
            __weak typeof(self) weakSelf = self;
            [alert addAction:[UIAlertAction actionWithTitle:@"去清理" style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused a) {
                if (weakSelf.goToClean) weakSelf.goToClean();
            }]];
            [self presentViewController:alert animated:YES completion:nil];
            break;
        }
    }
}

#pragma mark - UI

- (UILabel *)makeLabel:(NSString *)text font:(UIFont *)font color:(UIColor *)color
{
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = font;
    label.textColor = color;
    return label;
}

- (UIView *)makeMiniCardWithTitle:(NSString *)title valueLabel:(UILabel *)valueLabel
{
    UIView *card = [UIView new];
    card.backgroundColor = UIColor.systemBackgroundColor;
    card.layer.cornerRadius = 28;
    UILabel *titleLabel = [self makeLabel:title font:[UIFont systemFontOfSize:15 weight:UIFontWeightRegular]
                                    color:UIColor.secondaryLabelColor];
    valueLabel.font = [UIFont systemFontOfSize:34 weight:UIFontWeightBold];
    valueLabel.textColor = UIColor.labelColor;
    valueLabel.adjustsFontSizeToFitWidth = YES;
    valueLabel.minimumScaleFactor = 0.6;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel, valueLabel]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 2;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],
    ]];
    return card;
}

- (UIView *)makeInfoRowWithIcon:(NSString *)icon title:(NSString *)title valueLabel:(UILabel *)valueLabel
{
    UIImageView *iconView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:icon]];
    iconView.tintColor = UIColor.labelColor;
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [iconView.widthAnchor constraintEqualToConstant:24],
        [iconView.heightAnchor constraintEqualToConstant:24],
    ]];
    UILabel *titleLabel = [self makeLabel:title font:[UIFont systemFontOfSize:17 weight:UIFontWeightSemibold]
                                    color:UIColor.labelColor];
    valueLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    valueLabel.textColor = UIColor.secondaryLabelColor;
    valueLabel.numberOfLines = 0;
    UIStackView *texts = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel, valueLabel]];
    texts.axis = UILayoutConstraintAxisVertical;
    texts.spacing = 2;
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[iconView, texts]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 12;
    row.alignment = UIStackViewAlignmentCenter;
    return row;
}

- (void)buildUI
{
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.showsVerticalScrollIndicator = NO;
    [self.view addSubview:scroll];
    self.scrollView = scroll;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
    // Pull-to-refresh rescan (replaces the deleted power button, v2.2).
    UIRefreshControl *refresh = [UIRefreshControl new];
    [refresh addTarget:self action:@selector(userRefresh) forControlEvents:UIControlEventValueChanged];
    scroll.refreshControl = refresh;

    // Home metrics (v2.2): 16pt side margins, 13pt gaps between cards.
    UIStackView *content = [UIStackView new];
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = 13;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:16],
        [content.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-16],
        [content.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:12],
        // v2.1: the system tab bar owns the bottom safe area now (the -110
        // was padding for the deleted floating capsule bar). 20pt of
        // breathing room is all the content needs; the last row scrolls
        // fully above the glass tab bar.
        [content.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-20],
        [content.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-32],
    ]];

    // Huge bold title, left aligned (v2.2: the power button row is gone).
    UILabel *title = [self makeLabel:@"Cleaner" font:[UIFont systemFontOfSize:40 weight:UIFontWeightBold]
                               color:UIColor.labelColor];
    [content addArrangedSubview:title];
    [content setCustomSpacing:13 afterView:title];

    // Warning card: only when something is wrong.
    UIView *warning = [UIView new];
    warning.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithRed:0x5C / 255.0 green:0x1A / 255.0 blue:0x1A / 255.0 alpha:1]
            : [UIColor colorWithRed:0xF9 / 255.0 green:0xDE / 255.0 blue:0xDC / 255.0 alpha:1];
    }];
    warning.layer.cornerRadius = 28;
    warning.hidden = YES;
    self.warningCard = warning;
    self.warningLabel = [self makeLabel:@"" font:[UIFont systemFontOfSize:15 weight:UIFontWeightRegular]
                                  color:UIColor.labelColor];
    self.warningLabel.numberOfLines = 0;
    self.warningLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [warning addSubview:self.warningLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.warningLabel.leadingAnchor constraintEqualToAnchor:warning.leadingAnchor constant:16],
        [self.warningLabel.trailingAnchor constraintEqualToAnchor:warning.trailingAnchor constant:-16],
        [self.warningLabel.topAnchor constraintEqualToAnchor:warning.topAnchor constant:12],
        [self.warningLabel.bottomAnchor constraintEqualToAnchor:warning.bottomAnchor constant:-12],
    ]];
    [content addArrangedSubview:warning];

    // Status row: green card left, two white mini cards right.
    UIView *status = [UIView new];
    status.layer.cornerRadius = 28;
    status.clipsToBounds = NO;
    self.statusCard = status;
    self.statusTitleLabel = [self makeLabel:@"已授权" font:[UIFont systemFontOfSize:22 weight:UIFontWeightSemibold]
                                      color:UIColor.labelColor];
    // Mode line: 15pt, at most 2 lines. At 16pt it wrapped mid-word
    // ("[沙盒 / 模式]") in the narrow green card on a real device (v2.1).
    self.statusModeLabel = [self makeLabel:@"<App Group> [沙盒模式]" font:[UIFont systemFontOfSize:15 weight:UIFontWeightMedium]
                                     color:UIColor.labelColor];
    self.statusModeLabel.numberOfLines = 2;
    self.statusVersionLabel = [self makeLabel:@"版本：0.2.2" font:[UIFont systemFontOfSize:15 weight:UIFontWeightRegular]
                                        color:UIColor.labelColor];
    UIStackView *statusTexts = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.statusTitleLabel, self.statusModeLabel, self.statusVersionLabel]];
    statusTexts.axis = UILayoutConstraintAxisVertical;
    statusTexts.spacing = 1;
    statusTexts.translatesAutoresizingMaskIntoConstraints = NO;
    [status addSubview:statusTexts];
    [NSLayoutConstraint activateConstraints:@[
        [statusTexts.leadingAnchor constraintEqualToAnchor:status.leadingAnchor constant:16],
        [statusTexts.trailingAnchor constraintEqualToAnchor:status.trailingAnchor constant:-16],
        [statusTexts.topAnchor constraintEqualToAnchor:status.topAnchor constant:14],
    ]];
    // Check circle, v2.2: FULLY INSIDE the green card, 88pt, 12pt inset from
    // the right and bottom edges. KSU's original (110pt, offset +27/+31
    // beyond the corner, HomeMiuix.kt) cannot work in this layout: the gap
    // between the green card and the right column is 13pt, so any rightward
    // overflow of 13pt or more intersects the white card — and the white
    // card is drawn on top, so the circle's right half disappears under it
    // (exactly what the v2.1 device screenshot showed). v2.1's 44pt gap
    // below the row only fixed the VERTICAL collision with the info card,
    // not this horizontal one. With the circle inside, its frame can never
    // intersect any other card; it is also brought to the front of the row.
    self.statusIconView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark.circle"]];
    self.statusIconView.contentMode = UIViewContentModeScaleAspectFit;
    self.statusIconView.translatesAutoresizingMaskIntoConstraints = NO;
    [status addSubview:self.statusIconView];
    [NSLayoutConstraint activateConstraints:@[
        [self.statusIconView.widthAnchor constraintEqualToConstant:88],
        [self.statusIconView.heightAnchor constraintEqualToConstant:88],
        [self.statusIconView.trailingAnchor constraintEqualToAnchor:status.trailingAnchor constant:-12],
        [self.statusIconView.bottomAnchor constraintEqualToAnchor:status.bottomAnchor constant:-12],
    ]];
    [status bringSubviewToFront:self.statusIconView];
    [status addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(statusCardTapped)]];

    self.appCountLabel = [UILabel new];
    self.reclaimableLabel = [UILabel new];
    UIView *appsCard = [self makeMiniCardWithTitle:@"应用" valueLabel:self.appCountLabel];
    UIView *cleanCard = [self makeMiniCardWithTitle:@"可清理" valueLabel:self.reclaimableLabel];
    UIStackView *rightColumn = [[UIStackView alloc] initWithArrangedSubviews:@[appsCard, cleanCard]];
    rightColumn.axis = UILayoutConstraintAxisVertical;
    rightColumn.spacing = 13;
    rightColumn.distribution = UIStackViewDistributionFillEqually;

    UIStackView *statusRow = [[UIStackView alloc] initWithArrangedSubviews:@[status, rightColumn]];
    statusRow.axis = UILayoutConstraintAxisHorizontal;
    statusRow.spacing = 13;
    statusRow.alignment = UIStackViewAlignmentFill;
    [NSLayoutConstraint activateConstraints:@[
        [status.widthAnchor constraintEqualToAnchor:statusRow.widthAnchor multiplier:0.55],
        // Minimum height: the three text lines end ~97pt from the top; the
        // 88pt circle starts at (height - 100). 212pt leaves 15pt between
        // the text and the circle. The row height is max(green, right
        // column), so both sides end at the same bottom edge.
        [status.heightAnchor constraintGreaterThanOrEqualToConstant:212],
    ]];
    [content addArrangedSubview:statusRow];
    [statusRow bringSubviewToFront:status];
    // v2.2: no overflow any more, so the gap below the row is the standard
    // 13pt (the v2.1 44pt was only there to clear the overflowing circle).
    [content setCustomSpacing:13 afterView:statusRow];

    // Info card: one white rounded card, icon + bold title + grey value.
    UIView *info = [UIView new];
    info.backgroundColor = UIColor.systemBackgroundColor;
    info.layer.cornerRadius = 28;
    NSString *version = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"0.2.2";
    NSString *build = NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] ?: @"1";
    self.groupStatusValueLabel = [UILabel new];
    NSArray<UIView *> *rows = @[
        [self makeInfoRowWithIcon:@"tag.fill" title:@"Cleaner 版本"
                       valueLabel:[self makeLabel:[NSString stringWithFormat:@"v%@ (%@)", version, build]
                                             font:[UIFont systemFontOfSize:15] color:UIColor.secondaryLabelColor]],
        [self makeInfoRowWithIcon:@"cpu" title:@"系统版本"
                       valueLabel:[self makeLabel:[@"iOS " stringByAppendingString:UIDevice.currentDevice.systemVersion]
                                             font:[UIFont systemFontOfSize:15] color:UIColor.secondaryLabelColor]],
        [self makeInfoRowWithIcon:@"iphone" title:@"设备型号"
                       valueLabel:[self makeLabel:cl_device_model()
                                             font:[UIFont systemFontOfSize:15] color:UIColor.secondaryLabelColor]],
        [self makeInfoRowWithIcon:@"shield.fill" title:@"沙盒技术"
                       valueLabel:[self makeLabel:@"worse_query · App Group"
                                             font:[UIFont systemFontOfSize:15] color:UIColor.secondaryLabelColor]],
        [self makeInfoRowWithIcon:@"lock.shield.fill" title:@"App Group 状态"
                       valueLabel:self.groupStatusValueLabel],
        [self makeInfoRowWithIcon:@"checkmark.shield.fill" title:@"支持范围"
                       valueLabel:[self makeLabel:@"iOS 26.0–26.7.2 / 27.2"
                                             font:[UIFont systemFontOfSize:15] color:UIColor.secondaryLabelColor]],
    ];
    UIStackView *infoStack = [[UIStackView alloc] initWithArrangedSubviews:rows];
    infoStack.axis = UILayoutConstraintAxisVertical;
    infoStack.spacing = 24;
    infoStack.translatesAutoresizingMaskIntoConstraints = NO;
    [info addSubview:infoStack];
    [NSLayoutConstraint activateConstraints:@[
        [infoStack.leadingAnchor constraintEqualToAnchor:info.leadingAnchor constant:16],
        [infoStack.trailingAnchor constraintEqualToAnchor:info.trailingAnchor constant:-16],
        [infoStack.topAnchor constraintEqualToAnchor:info.topAnchor constant:16],
        [infoStack.bottomAnchor constraintEqualToAnchor:info.bottomAnchor constant:-16],
    ]];
    [content addArrangedSubview:info];

    [self refreshStatus];
}

@end
