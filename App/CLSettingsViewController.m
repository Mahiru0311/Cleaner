//
//  CLSettingsViewController.m
//  Cleaner v2 — Settings: about, attribution, log.
//  No emoji; SF Symbols only. App mark (beige + black trash) is the AppIcon.
//

#import "CLSettingsViewController.h"
#import "CLLogViewController.h"

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
    NSString *version = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"0.2.1";
    NSString *build = NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] ?: @"1";
    self.sections = @[
        @[
            @{@"title": @"Cleaner 版本", @"value": [NSString stringWithFormat:@"v%@ (%@)", version, build]},
            @{@"title": @"Bundle ID", @"value": @"com.mahiru.cleaner"},
            @{@"title": @"App Group", @"value": @"group.com.mahiru.cleaner"},
            @{@"title": @"沙盒技术", @"value": @"worse_query"},
        ],
        @[
            @{@"title": @"沙盒 worse_query", @"value": @"Taj C (forcequit)"},
            @{@"title": @"容器枚举 fsgetpath", @"value": @"KAMUI (murk-sus)"},
            @{@"title": @"缓存清理界面", @"value": @"WQFiles (kolbicz)"},
            @{@"title": @"首页界面", @"value": @"KernelSU Manager (tiann)"},
            @{@"title": @"图标风格", @"value": @"huamidev/GestaltX"},
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
    return section == 0 ? @"关于" : section == 1 ? @"来源与协议" : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == 1) return @"图标风格参考 huamidev/GestaltX（GPL-3.0）。Cleaner 是 GPL-3.0-or-later 开源软件。";
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
    if ([row[@"action"] isEqualToString:@"log"]) {
        [self.navigationController pushViewController:[CLLogViewController new] animated:YES];
    }
}

@end
