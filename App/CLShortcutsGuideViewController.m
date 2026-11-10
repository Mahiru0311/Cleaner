
//
//  CLShortcutsGuideViewController.m
//  Cleaner v2.5 — Shortcuts guide: preconditions, live status, steps.
//  v2.6: shows the last intent run (from the App Group diagnostics) and
//  states the force-quit caveat honestly. The cleaner:// copy button is
//  GONE: cleaner://clean opens the app by design, and promoting it as a
//  shortcut is exactly what made the user tap it and land on the clean
//  page. The URL scheme stays registered for deep links, but it is no
//  longer offered here. No emoji; SF Symbols only.
//

#import "CLShortcutsGuideViewController.h"
#import "CleanerIntents-Swift.h"
#import "CLBackgroundClean.h"
#import "CLUI.h"

@implementation CLShortcutsGuideViewController {
    NSArray<NSArray<NSDictionary *> *> *_sections;
    NSString *_statusFooter;
    NSString *_lastRunFooter;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (NSString *)lastRunLine:(NSDictionary *)run
{
    NSDate *date = run[@"date"];
    NSString *time = @"";
    if ([date isKindOfClass:NSDate.class]) {
        NSDateFormatter *f = [NSDateFormatter new];
        f.dateFormat = @"MM-dd HH:mm";
        time = [f stringFromDate:date];
    }
    unsigned long long freed = [run[@"freed"] unsignedLongLongValue] +
        [run[@"customFreed"] unsignedLongLongValue];
    NSInteger cleaned = [run[@"appsCleaned"] integerValue];
    NSInteger remaining = [run[@"appsRemaining"] integerValue];
    BOOL headless = [run[@"headless"] boolValue];
    NSString *how = headless ? @"后台运行，未打开应用" : @"应用已在后台时运行";
    if ([run[@"error"] isKindOfClass:NSString.class] && [run[@"error"] length]) {
        return [NSString stringWithFormat:@"%@ · 清理失败：%@", time, run[@"error"]];
    }
    NSMutableString *s = [NSMutableString stringWithFormat:@"%@ · 已释放 %@ · 清理了 %ld 个应用",
                          time, cl_size_text(freed), (long)cleaned];
    if (remaining > 0) [s appendFormat:@" · 还有 %ld 个未清理", (long)remaining];
    if ([run[@"timedOut"] boolValue]) [s appendString:@" · 超时（部分完成）"];
    else if ([run[@"partial"] boolValue]) [s appendString:@" · 部分完成"];
    [s appendFormat:@" · %@", how];
    return [s copy];
}

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
        _statusFooter = @"这个版本里没有注册到快捷指令（可能是旧版）。请先装 0.2.6，再打开一次 Cleaner。";
    }

    // Last intent run, from the App Group diagnostics (v2.6): what the
    // shortcut actually did last time — including whether the app was
    // opened for it. "It jumped to the clean page" was the cleaner://
    // URL scheme, not the intent; a headless intent run shows up here
    // as "后台运行，未打开应用".
    NSDictionary *lastRun = cl_intent_last_run();
    NSArray<NSDictionary *> *lastRunRows;
    if (lastRun) {
        lastRunRows = @[
            @{@"title": @"上次运行", @"value": [self lastRunLine:lastRun]},
            @{@"title": @"运行次数", @"value": [NSString stringWithFormat:@"%lu 次",
                                                (unsigned long)[lastRun[@"runCount"] unsignedIntegerValue]]},
        ];
        _lastRunFooter = @"每次点快捷指令都会记一笔：时间、释放了多少、清了几个应用、有没有打开应用。";
    } else {
        lastRunRows = @[@{@"title": @"上次运行", @"value": @"还没有运行过"}];
        _lastRunFooter = @"点一次「清理全部缓存」之后，这里会显示它实际做了什么（有没有打开应用、释放了多少）。";
    }

    _sections = @[
        @[
            @{@"title": @"当前版本", @"value": statusValue},
            @{@"title": @"已注册的快捷方式", @"value": hasIntent ? [titles componentsJoinedByString:@"、"] : @"无"},
            @{@"title": @"已打开过 Cleaner", @"value": launchedOnce ? @"是" : @"否"},
        ],
        lastRunRows,
        @[
            @{@"title": @"1. 点下面「打开快捷指令」"},
            @{@"title": @"2. 点右上角 + 新建快捷指令"},
            @{@"title": @"3. 搜索「清理全部缓存」，或在 Cleaner 的操作里找到它"},
            @{@"title": @"4. 点完成；也可以添加到主屏幕、锁屏、操作按钮，或用 Siri 说「清理全部缓存」"},
            @{@"title": @"打开快捷指令", @"action": @"open-shortcuts"},
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
    if (section == 1) return @"上次运行";
    return @"添加步骤";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == 0) return _statusFooter;
    if (section == 1) return _lastRunFooter;
    // v2.6: the 0.2.4 sentence is corrected — the cause of 0.2.4's missing
    // shortcut was never established (the types WERE in the package,
    // proven by the __swift5_types descriptors); 0.2.5/0.2.6 register
    // the same way, and this page now shows the live status and the last
    // run instead of asserting a fix. The force-quit caveat is an honest
    // platform limit: a force-quit tells iOS to leave the app alone
    // until it is opened again; normal suspended background is fine.
    return @"点一下快捷指令，就在后台清理全部缓存和已启用的自定义规则，不打开 Cleaner，不需要服务器。第一次用之前必须先装 0.2.6、打开一次 Cleaner——系统索引之后才能在「快捷指令」里搜到它。如果把 Cleaner 从应用切换器里划掉（彻底退出），系统在下次打开它之前不会在后台启动它；平时留在后台（挂起）没关系，不需要管它。";
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
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    BOOL hasAction = row[@"action"] != nil;
    cell.accessoryType = hasAction ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    cell.selectionStyle = hasAction ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    if (indexPath.section == 2 && indexPath.row < 4) {
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
}

@end
