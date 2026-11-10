
//
//  CLShortcutsGuideViewController.m
//  Cleaner v2.5 — Shortcuts guide: preconditions, live status, steps.
//  No emoji; SF Symbols only.
//

#import "CLShortcutsGuideViewController.h"
#import "CleanerIntents-Swift.h"
#import "CLUI.h"

@implementation CLShortcutsGuideViewController {
    NSArray<NSArray<NSDictionary *> *> *_sections;
    NSString *_statusFooter;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"快捷指令";

    // Live status, read from the real intent registration — not from a
    // hardcoded string. CLCleanerShortcutsInfo reads
    // CleanerShortcuts.appShortcuts and returns the titles: if the linker
    // ever strips the intent types again, this comes back empty and the
    // status below says so instead of pretending everything is fine.
    // (That is also what keeps the types linked: the titles flow to a
    // UIKit label, a data flow -dead_strip cannot delete.)
    NSArray<NSString *> *titles = [CLCleanerShortcutsInfo shortcutTitles];
    BOOL hasIntent = titles.count > 0;
    BOOL launchedOnce = [[NSUserDefaults standardUserDefaults] boolForKey:@"cl-ui-launched-once"];
    NSString *version = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"?";
    NSString *statusValue = hasIntent
        ? [NSString stringWithFormat:@"v%@（带快捷指令）", version]
        : [NSString stringWithFormat:@"v%@（不带快捷指令）", version];
    if (hasIntent && launchedOnce) {
        _statusFooter = @"都就绪了：现在去「快捷指令」里搜 Cleaner，就能看到「清理全部缓存」。搜不到就重启手机，系统重新索引后再试。";
    } else if (hasIntent && !launchedOnce) {
        _statusFooter = @"快捷指令已在包里，但系统要先看到 Cleaner 打开过一次才会索引它——你现在就在用它，退出后去「快捷指令」里搜就能看到。";
    } else {
        _statusFooter = @"这个版本里没有注册到快捷指令（可能是旧版）。请先装 0.2.5，再打开一次 Cleaner。";
    }
    _sections = @[
        @[
            @{@"title": @"当前版本", @"value": statusValue},
            @{@"title": @"已注册的快捷方式", @"value": hasIntent ? [titles componentsJoinedByString:@"、"] : @"无"},
            @{@"title": @"已打开过 Cleaner", @"value": launchedOnce ? @"是" : @"否"},
        ],
        @[
            @{@"title": @"1. 点下面「打开快捷指令」"},
            @{@"title": @"2. 点右上角 + 新建快捷指令"},
            @{@"title": @"3. 搜索「清理全部缓存」，或在 Cleaner 的操作里找到它"},
            @{@"title": @"4. 点完成；也可以添加到主屏幕、锁屏、操作按钮，或用 Siri 说「清理全部缓存」"},
            @{@"title": @"打开快捷指令", @"action": @"open-shortcuts"},
        ],
        @[
            @{@"title": @"复制 cleaner://clean（备用）", @"action": @"copy-clean"},
        ],
    ];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return (NSInteger)_sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (NSInteger)_sections[section].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == 0) return @"状态";
    if (section == 1) return @"添加步骤";
    return @"备用办法";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == 0) return _statusFooter;
    if (section == 1) return @"点一下快捷指令，就在后台清理全部缓存和已启用的自定义规则，不打开 Cleaner，不需要服务器。第一次用之前必须先装 0.2.5、打开一次 Cleaner——系统索引之后才能在「快捷指令」里搜到它。";
    return @"cleaner://clean 会打开应用并弹确认框（老办法）；cleaner://scan 是重新扫描。如果上面三步都对还搜不到，先重启手机再试：0.2.4 有个构建问题导致意图根本没进包，0.2.5 已修好并在构建时校验。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    static NSString *reuseID = @"CLShortcutsGuideCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:reuseID];
    NSDictionary *row = _sections[indexPath.section][indexPath.row];
    cell.textLabel.text = row[@"title"];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.text = row[@"value"];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    BOOL hasAction = row[@"action"] != nil;
    cell.accessoryType = hasAction ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    cell.selectionStyle = hasAction ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    if (indexPath.section == 1 && indexPath.row < 4) {
        // The numbered steps are text, not buttons.
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *row = _sections[indexPath.section][indexPath.row];
    NSString *action = row[@"action"];
    if ([action isEqualToString:@"open-shortcuts"]) {
        NSURL *url = [NSURL URLWithString:@"shortcuts://"];
        if (![[UIApplication sharedApplication] canOpenURL:url]) {
            cl_alert(self, @"打不开快捷指令", @"这台手机上没有「快捷指令」App。");
            return;
        }
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        return;
    }
    if ([action isEqualToString:@"copy-clean"]) {
        UIPasteboard.generalPasteboard.string = @"cleaner://clean";
        cl_alert(self, @"已复制", @"cleaner://clean");
    }
}

@end
