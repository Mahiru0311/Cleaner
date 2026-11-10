//
//  CLSettingsViewController.m
//  Cleaner v2 — Settings: about, attribution, log.
//  No emoji; SF Symbols only. App mark (beige + black trash) is the AppIcon.
//

#import "CLSettingsViewController.h"
#import "CLLogViewController.h"
#import "CLShortcutsGuideViewController.h"

@interface CLSettingsViewController ()
@property (nonatomic, strong) NSArray<NSArray<NSDictionary *> *> *sections;
@end

@implementation CLSettingsViewController

- (instancetype)init
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) self.title = @"设置";
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    NSString *version = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"0.2.3";
    NSString *build = NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] ?: @"1";
    self.sections = @[
        @[
            @{@"title": @"Cleaner 版本", @"value": [NSString stringWithFormat:@"v%@ (%@)", version, build]},
            @{@"title": @"Bundle ID", @"value": @"com.mahiru.cleaner"},
            @{@"title": @"App Group", @"value": @"group.com.mahiru.cleaner"},
            @{@"title": @"沙盒技术", @"value": @"worse_query"},
        ],
        @[
            @{@"title": @"快捷指令", @"action": @"shortcuts-guide"},
        ],
        @[
            @{@"title": @"沙盒 worse_query", @"value": @"Taj C (forcequit)"},
            @{@"title": @"容器枚举 fsgetpath", @"value": @"KAMUI (murk-sus)"},
            @{@"title": @"缓存清理界面", @"value": @"WQFiles (kolbicz)"},
            @{@"title": @"首页界面", @"value": @"KernelSU Manager (tiann)"},
            @{@"title": @"图标风格", @"value": @"huamidev/GestaltX"},
            @{@"title": @"fd 遍历与清理记账", @"value": @"YangJiiii/3105"},
            @{@"title": @"目录选择器（自定义清理）", @"value": @"BleachBit / SD Maid SE / Filza"},
            @{@"title": @"快捷指令保活", @"value": @"AppIntents 真实数据流 (v2.5)"},
        ],
        @[
            @{@"title": @"日志", @"action": @"log"},
        ],
    ];

    // About header: app mark + name + version.
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, 120)];
    UIImageView *iconView = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"AppIcon60x60"]];
    iconView.layer.cornerRadius = 16;
    iconView.layer.masksToBounds = YES;
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:iconView];
    UILabel *nameLabel = [UILabel new];
    nameLabel.text = @"Cleaner";
    nameLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    nameLabel.textAlignment = NSTextAlignmentCenter;
    nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:nameLabel];
    UILabel *versionLabel = [UILabel new];
    versionLabel.text = [NSString stringWithFormat:@"版本 %@ (%@)", version, build];
    versionLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
    versionLabel.textColor = UIColor.secondaryLabelColor;
    versionLabel.textAlignment = NSTextAlignmentCenter;
    versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:versionLabel];
    [NSLayoutConstraint activateConstraints:@[
        [iconView.widthAnchor constraintEqualToConstant:64],
        [iconView.heightAnchor constraintEqualToConstant:64],
        [iconView.centerXAnchor constraintEqualToAnchor:header.centerXAnchor],
        [iconView.topAnchor constraintEqualToAnchor:header.topAnchor constant:8],
        [nameLabel.topAnchor constraintEqualToAnchor:iconView.bottomAnchor constant:8],
        [nameLabel.centerXAnchor constraintEqualToAnchor:header.centerXAnchor],
        [versionLabel.topAnchor constraintEqualToAnchor:nameLabel.bottomAnchor constant:2],
        [versionLabel.centerXAnchor constraintEqualToAnchor:header.centerXAnchor],
    ]];
    self.tableView.tableHeaderView = header;
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return (NSInteger)self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (NSInteger)self.sections[section].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == 0) return @"关于";
    if (section == 1) return @"快捷指令";
    if (section == 2) return @"来源与协议";
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == 1) {
        NSString *version = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"?";
        return [NSString stringWithFormat:@"点一下就在后台清理，不打开应用：装好 %@ 后打开一次 Cleaner，再去「快捷指令」里搜 Cleaner 就会出现「清理全部缓存」。从旧版升级要先把 Cleaner 整个删掉再装，直接覆盖装可能搜不到。点进「快捷指令」看状态、步骤和上次运行记录。", version];
    }
    if (section == 2) return @"图标风格参考 huamidev/GestaltX（GPL-3.0）；fd 遍历与清理记账参考 YangJiiii/3105（GPL-3.0）。Cleaner 是 GPL-3.0-or-later 开源软件。";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    static NSString *reuseID = @"CLSettingsCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:reuseID];
    NSDictionary *row = self.sections[indexPath.section][indexPath.row];
    cell.textLabel.text = row[@"title"];
    cell.detailTextLabel.text = row[@"value"];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    BOOL hasAction = row[@"action"] != nil;
    cell.accessoryType = hasAction ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    cell.selectionStyle = hasAction ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *row = self.sections[indexPath.section][indexPath.row];
    NSString *action = row[@"action"];
    if ([action isEqualToString:@"log"]) {
        [self.navigationController pushViewController:[CLLogViewController new] animated:YES];
        return;
    }
    if ([action isEqualToString:@"shortcuts-guide"]) {
        // v2.5: a real guide page with live status (does this build carry
        // the intent? has this phone launched the app once?) instead of
        // the old alert — the user could not find the shortcut at all.
        // v2.6: the guide also shows the last intent run. The cleaner://
        // copy buttons are gone: cleaner://clean opens the app by design,
        // and offering it here is what made the user tap it and land on
        // the clean page. The scheme stays registered for deep links.
        [self.navigationController pushViewController:[CLShortcutsGuideViewController new] animated:YES];
        return;
    }
}

@end
