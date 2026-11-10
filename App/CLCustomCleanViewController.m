//
//  CLCustomCleanViewController.m
//  Cleaner v2.3 — user-defined cleaning rules, presets and excludes.
//
//  Rules: pick an app (or all apps) + a folder (relative path under the
//  container), a file extension, or a file-name substring. Presets add
//  ready-made rules. Excludes are never cleaned. Execution runs on a
//  background queue through cl_custom_clean_run (Core): folder rules purge
//  contents (never the container root, never Documents/Library themselves),
//  extension/name rules only touch Library/Caches + tmp. Deleting an app's
//  data stays the backup-first "清空数据" flow — custom rules never do it.
//

#import "CLCustomCleanViewController.h"
#import "CLCache.h"
#import "CLCustomClean.h"
#import "CLLaunchServices.h"
#import "CLRulePickerViewController.h"
#import "CLUI.h"

typedef NS_ENUM(NSInteger, CLCustomSection) {
    CLCustomSectionRules = 0,
    CLCustomSectionPresets,
    CLCustomSectionExcludes,
    CLCustomSectionCount,
};

@implementation CLCustomCleanViewController {
    NSArray<NSDictionary *> *_rules;
    NSArray<NSDictionary *> *_presets;
    NSArray<NSString *> *_excludedApps;
    NSArray<NSString *> *_excludedFolders;
    UILabel *_statusLabel;
    BOOL _running;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"自定义清理";
    _presets = cl_custom_clean_presets();
    [self reloadModel];
    UILabel *status = [UILabel new];
    status.font = [UIFont systemFontOfSize:14];
    status.textColor = UIColor.secondaryLabelColor;
    status.numberOfLines = 0;
    status.text = @"规则按添加顺序执行。文件夹规则只清理容器内的子文件夹；扩展名与文件名规则只清理 Library/Caches 与 tmp。";
    _statusLabel = status;
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 52)];
    status.frame = CGRectMake(20, 8, header.bounds.size.width - 40, 36);
    status.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [header addSubview:status];
    self.tableView.tableHeaderView = header;
    UIBarButtonItem *run = [[UIBarButtonItem alloc] initWithTitle:@"开始清理" style:cl_primary_button_style()
                                                           target:self action:@selector(runTapped)];
    self.navigationItem.rightBarButtonItem = run;
    [self updateRunButton];
}

- (void)reloadModel
{
    _rules = cl_custom_clean_rules();
    _excludedApps = cl_custom_clean_excluded_apps();
    _excludedFolders = cl_custom_clean_excluded_folders();
}

- (void)updateRunButton
{
    BOOL anyEnabled = NO;
    for (NSDictionary *rule in _rules) if ([rule[CLCustomRuleEnabledKey] boolValue]) { anyEnabled = YES; break; }
    self.navigationItem.rightBarButtonItem.enabled = anyEnabled && !_running;
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return CLCustomSectionCount; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == CLCustomSectionRules) return (NSInteger)_rules.count + 1;  // + add row
    if (section == CLCustomSectionPresets) return (NSInteger)_presets.count;
    return (NSInteger)_excludedApps.count + (NSInteger)_excludedFolders.count + 1;  // + add row
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == CLCustomSectionRules) return @"规则";
    if (section == CLCustomSectionPresets) return @"预设";
    return @"排除（永不清理）";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == CLCustomSectionRules)
        return @"点一条规则可以预览它会删什么（匹配文件数 + 大小），确认后再清理。点「添加规则」打开目录选择页：选应用、进它的容器里选目录，再选「清空整个目录」或「按条件删」。目录规则不能指向容器根目录、Documents 或 Library 本身；非缓存目录会先警告一次。清理整个应用的数据请用应用页的「清空数据」（会先备份）。";
    if (section == CLCustomSectionPresets) return @"点一下把预设的规则加入规则列表。";
    return @"被排除的应用和文件夹不会被任何规则清理。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cc"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cc"];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    UIListContentConfiguration *c = cell.defaultContentConfiguration;
    if (indexPath.section == CLCustomSectionRules) {
        if ((NSUInteger)indexPath.row == _rules.count) {
            c.text = @"添加规则…";
            c.textProperties.color = UIColor.systemBlueColor;
            c.secondaryText = @"按文件夹 / 按文件类型 / 按文件名";
            cell.contentConfiguration = c;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return cell;
        }
        NSDictionary *rule = _rules[(NSUInteger)indexPath.row];
        c.text = cl_custom_clean_rule_summary(rule);
        c.secondaryText = [rule[CLCustomRuleEnabledKey] boolValue] ? @"已启用" : @"已停用";
        UISwitch *sw = [UISwitch new];
        sw.on = [rule[CLCustomRuleEnabledKey] boolValue];
        [sw addTarget:self action:@selector(ruleSwitchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        cell.contentConfiguration = c;
        return cell;
    }
    if (indexPath.section == CLCustomSectionPresets) {
        NSDictionary *preset = _presets[(NSUInteger)indexPath.row];
        c.text = preset[CLCustomPresetTitleKey];
        c.secondaryText = preset[CLCustomPresetDetailKey];
        c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
        cell.contentConfiguration = c;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }
    // Excludes: apps first, then folders, then the add row.
    if ((NSUInteger)indexPath.row < _excludedApps.count) {
        NSString *bid = _excludedApps[(NSUInteger)indexPath.row];
        c.text = cl_display_name(bid) ?: bid;
        c.secondaryText = [NSString stringWithFormat:@"应用 · %@", bid];
        c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
        cell.contentConfiguration = c;
        return cell;
    }
    NSUInteger folderRow = (NSUInteger)indexPath.row - _excludedApps.count;
    if (folderRow < _excludedFolders.count) {
        c.text = _excludedFolders[folderRow];
        c.secondaryText = @"文件夹";
        c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
        cell.contentConfiguration = c;
        return cell;
    }
    c.text = @"添加排除…";
    c.textProperties.color = UIColor.systemBlueColor;
    c.secondaryText = @"排除应用 / 排除文件夹";
    cell.contentConfiguration = c;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == CLCustomSectionRules) return (NSUInteger)indexPath.row < _rules.count;
    if (indexPath.section == CLCustomSectionExcludes) {
        return (NSUInteger)indexPath.row < _excludedApps.count + _excludedFolders.count;
    }
    return NO;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
    forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    if (indexPath.section == CLCustomSectionRules) {
        NSMutableArray *rules = [_rules mutableCopy];
        [rules removeObjectAtIndex:(NSUInteger)indexPath.row];
        cl_custom_clean_save_rules(rules);
        [self reloadModel];
        [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationFade];
        [self updateRunButton];
        return;
    }
    if (indexPath.section == CLCustomSectionExcludes) {
        if ((NSUInteger)indexPath.row < _excludedApps.count) {
            NSMutableArray *apps = [_excludedApps mutableCopy];
            [apps removeObjectAtIndex:(NSUInteger)indexPath.row];
            cl_custom_clean_save_excludes(apps, _excludedFolders);
        } else {
            NSMutableArray *folders = [_excludedFolders mutableCopy];
            [folders removeObjectAtIndex:(NSUInteger)indexPath.row - _excludedApps.count];
            cl_custom_clean_save_excludes(_excludedApps, folders);
        }
        [self reloadModel];
        [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationFade];
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == CLCustomSectionRules && (NSUInteger)indexPath.row < _rules.count) {
        // v2.4: tap a rule to preview it (dry-run), toggle it, or delete it.
        [self ruleActionSheetForRow:(NSUInteger)indexPath.row];
        return;
    }
    if (indexPath.section == CLCustomSectionRules && (NSUInteger)indexPath.row == _rules.count) {
        [self addRule];
        return;
    }
    if (indexPath.section == CLCustomSectionPresets) {
        [self addPreset:_presets[(NSUInteger)indexPath.row]];
        return;
    }
    if (indexPath.section == CLCustomSectionExcludes &&
        (NSUInteger)indexPath.row == _excludedApps.count + _excludedFolders.count) {
        [self addExcludeSheet];
    }
}

#pragma mark - Rule preview (v2.4 dry-run)

- (void)ruleActionSheetForRow:(NSUInteger)row
{
    NSDictionary *rule = _rules[row];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:cl_custom_clean_rule_summary(rule)
        message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"预览匹配" style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused a) {
        [weakSelf previewRule:rule];
    }]];
    BOOL enabled = [rule[CLCustomRuleEnabledKey] boolValue];
    // v2.5: directory/folder rules can be edited in the picker (prefilled);
    // extension/name rules keep preview/toggle/delete only.
    NSString *kind = rule[CLCustomRuleKindKey];
    if ([kind isEqualToString:@"directory"] || [kind isEqualToString:@"folder"]) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"编辑这条规则" style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused a) {
            [weakSelf editRule:rule];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:enabled ? @"停用这条规则" : @"启用这条规则"
                                              style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused a) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        NSMutableArray *rules = [strongSelf->_rules mutableCopy];
        NSMutableDictionary *r = [rules[row] mutableCopy];
        r[CLCustomRuleEnabledKey] = @(!enabled);
        rules[row] = r;
        cl_custom_clean_save_rules(rules);
        [strongSelf reloadModel];
        [strongSelf.tableView reloadData];
        [strongSelf updateRunButton];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"删除这条规则" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        NSMutableArray *rules = [strongSelf->_rules mutableCopy];
        [rules removeObjectAtIndex:row];
        cl_custom_clean_save_rules(rules);
        [strongSelf reloadModel];
        [strongSelf.tableView reloadData];
        [strongSelf updateRunButton];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:
                             [NSIndexPath indexPathForRow:row inSection:CLCustomSectionRules]];
    sheet.popoverPresentationController.sourceView = cell ?: self.view;
    sheet.popoverPresentationController.sourceRect = (cell ?: self.view).bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

// Dry-run: show what the rule would delete, then confirm before running it.
- (void)previewRule:(NSDictionary *)rule
{
    NSArray<CLCacheItem *> *apps = [CLCacheStore shared].items;
    if (!apps.count) {
        cl_alert(self, @"没有已扫描的应用", @"请先去清理页扫描一次，再回来预览。");
        return;
    }
    _statusLabel.text = @"正在预览…";
    __weak typeof(self) weakSelf = self;
    cl_custom_clean_dry_run(apps, rule, ^(NSString *status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (strongSelf) strongSelf->_statusLabel.text = status;
        });
    }, ^(NSDictionary *result) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            NSUInteger matched = [result[@"matched"] unsignedIntegerValue];
            unsigned long long bytes = [result[@"bytes"] unsignedLongLongValue];
            NSUInteger skipped = [result[@"skipped"] unsignedIntegerValue];
            NSUInteger appsHit = [result[@"apps"] unsignedIntegerValue];
            NSArray *sample = result[@"sample"];
            NSString *reason = result[@"reason"];
            if (reason.length) {
                strongSelf->_statusLabel.text = reason;
                cl_alert(strongSelf, @"无法预览", reason);
                return;
            }
            NSMutableString *text = [NSMutableString stringWithFormat:
                @"这条规则会删 %lu 个文件，共 %@，涉及 %lu 个应用。", (unsigned long)matched,
                cl_size_text(bytes), (unsigned long)appsHit];
            if (skipped) [text appendFormat:@"\n另有 %lu 个文件因太新或大小不符而跳过。", (unsigned long)skipped];
            NSArray *shown = [sample subarrayWithRange:NSMakeRange(0, MIN(sample.count, 10))];
            if (shown.count) [text appendFormat:@"\n\n%@", [shown componentsJoinedByString:@"\n"]];
            if (sample.count > shown.count)
                [text appendFormat:@"\n…等 %lu 个", (unsigned long)(sample.count - shown.count)];
            strongSelf->_statusLabel.text = [NSString stringWithFormat:@"预览：%lu 个文件，%@。",
                                             (unsigned long)matched, cl_size_text(bytes)];
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"预览匹配"
                message:text preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
            if (matched) {
                [alert addAction:[UIAlertAction actionWithTitle:@"清理这些文件"
                                                          style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
                    [weakSelf runOneRule:rule];
                }]];
            }
            [strongSelf presentViewController:alert animated:YES completion:nil];
        });
    });
}

- (void)runOneRule:(NSDictionary *)rule
{
    NSArray<CLCacheItem *> *apps = [CLCacheStore shared].items;
    _running = YES;
    [self updateRunButton];
    _statusLabel.text = @"正在清理…";
    __weak typeof(self) weakSelf = self;
    cl_custom_clean_run_one_rule(apps, rule, ^(NSString *status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (strongSelf) strongSelf->_statusLabel.text = status;
        });
    }, ^(NSDictionary *result) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf->_running = NO;
            [strongSelf updateRunButton];
            unsigned long long freed = [result[@"freed"] unsignedLongLongValue];
            NSUInteger failed = [result[@"failed"] unsignedIntegerValue];
            NSUInteger skipped = [result[@"skipped"] unsignedIntegerValue];
            NSString *text = [NSString stringWithFormat:@"已释放 %@。", cl_size_text(freed)];
            if (skipped) text = [text stringByAppendingFormat:@"跳过 %lu 个（太新/大小不符）。", (unsigned long)skipped];
            if (failed) text = [text stringByAppendingFormat:@"%lu 项失败（详见日志）。", (unsigned long)failed];
            strongSelf->_statusLabel.text = text;
            cl_alert(strongSelf, @"自定义清理完成", text);
        });
    });
}

#pragma mark - Rules

- (void)ruleSwitchChanged:(UISwitch *)sw
{
    // Find the row from the cell, not from a tag: after a rule is deleted
    // the rows below it shift, and a stored tag would point at the wrong
    // rule (v2.3 fix before first device test).
    UIView *v = sw;
    while (v && ![v isKindOfClass:UITableViewCell.class]) v = v.superview;
    NSIndexPath *ip = [self.tableView indexPathForCell:(UITableViewCell *)v];
    if (!ip || (NSUInteger)ip.row >= _rules.count) return;
    NSMutableArray *rules = [_rules mutableCopy];
    NSMutableDictionary *rule = [rules[(NSUInteger)ip.row] mutableCopy];
    rule[CLCustomRuleEnabledKey] = @(sw.on);
    rules[(NSUInteger)ip.row] = rule;
    cl_custom_clean_save_rules(rules);
    [self reloadModel];
    [self updateRunButton];
    [self.tableView reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
}

// Scanned apps for the app picker (bundleID + name), from the shared store.
- (NSArray<CLCacheItem *> *)scannedApps
{
    NSMutableArray<CLCacheItem *> *apps = [NSMutableArray new];
    for (CLCacheItem *it in [CLCacheStore shared].items) {
        if (!it.crashLogs && it.bundleID.length) [apps addObject:it];
    }
    [apps sortUsingComparator:^NSComparisonResult(CLCacheItem *a, CLCacheItem *b) {
        return [a.name localizedStandardCompare:b.name];
    }];
    return apps;
}

// v2.5: 添加规则 opens the directory picker (a NEW page), not the old
// alert chain. The picker lets the user pick an app, drill into its
// container, choose the scope (clear the whole directory, or delete by
// conditions), and confirm with 选择 — the rule joins future cleaning.
- (void)addRule
{
    if (![CLCacheStore shared].items.count) {
        cl_alert(self, @"没有已扫描的应用", @"请先去清理页扫描一次，再回来添加规则。");
        return;
    }
    CLRulePickerViewController *picker = [[CLRulePickerViewController alloc] init];
    __weak typeof(self) weakSelf = self;
    picker.onSaved = ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf reloadModel];
        [strongSelf.tableView reloadData];
        [strongSelf updateRunButton];
    };
    [self.navigationController pushViewController:picker animated:YES];
}

// v2.5: edit a directory/folder rule in the picker, prefilled. Saving
// replaces the rule in place (same UUID, same enabled state). The rule's
// app must be scanned — otherwise the prefill has nowhere to go.
- (void)editRule:(NSDictionary *)rule
{
    NSString *bid = rule[CLCustomRuleBundleIDKey];
    BOOL scanned = NO;
    for (CLCacheItem *app in [self scannedApps]) {
        if ([app.bundleID isEqualToString:bid]) { scanned = YES; break; }
    }
    if (!scanned) {
        cl_alert(self, @"找不到这个应用", @"这条规则的应用没有扫描结果，请先去清理页扫描一次，再回来编辑。");
        return;
    }
    CLRulePickerViewController *picker = [[CLRulePickerViewController alloc] initWithRule:rule];
    __weak typeof(self) weakSelf = self;
    picker.onSaved = ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf reloadModel];
        [strongSelf.tableView reloadData];
        [strongSelf updateRunButton];
    };
    [self.navigationController pushViewController:picker animated:YES];
}

#pragma mark - Presets

- (void)addPreset:(NSDictionary *)preset
{
    NSArray<NSDictionary *> *presetRules = preset[CLCustomPresetRulesKey];
    NSMutableArray *rules = [cl_custom_clean_rules() mutableCopy];
    NSUInteger added = 0;
    for (NSDictionary *candidate in presetRules) {
        BOOL exists = NO;
        for (NSDictionary *rule in rules) {
            if ([rule[CLCustomRuleBundleIDKey] isEqualToString:candidate[CLCustomRuleBundleIDKey]] &&
                [rule[CLCustomRuleKindKey] isEqualToString:candidate[CLCustomRuleKindKey]] &&
                [rule[CLCustomRulePatternKey] isEqualToString:candidate[CLCustomRulePatternKey]]) {
                exists = YES;
                break;
            }
        }
        if (!exists) { [rules addObject:candidate]; added++; }
    }
    cl_custom_clean_save_rules(rules);
    [self reloadModel];
    [self.tableView reloadData];
    [self updateRunButton];
    _statusLabel.text = added ? [NSString stringWithFormat:@"已加入 %lu 条规则：%@。", (unsigned long)added, preset[CLCustomPresetTitleKey]]
                              : @"这些规则已经在列表里了。";
}

#pragma mark - Excludes

- (void)addExcludeSheet
{
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"添加排除" message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"排除应用" style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused a) {
        [weakSelf pickAppToExclude];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"排除文件夹" style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused a) {
        [weakSelf askFolderToExclude];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)pickAppToExclude
{
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"排除应用" message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    for (CLCacheItem *app in [self scannedApps]) {
        if ([_excludedApps containsObject:app.bundleID]) continue;
        [sheet addAction:[UIAlertAction actionWithTitle:app.name style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused a) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            NSMutableArray *apps = [cl_custom_clean_excluded_apps() mutableCopy];
            [apps addObject:app.bundleID];
            cl_custom_clean_save_excludes(apps, cl_custom_clean_excluded_folders());
            [strongSelf reloadModel];
            [strongSelf.tableView reloadData];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)askFolderToExclude
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"排除文件夹"
        message:@"容器内的相对路径，例如 Library/Caches/xxx。被排除的文件夹不会被任何规则清理。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Library/Caches/xxx";
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"添加" style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused a) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        NSString *pattern = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:
                             NSCharacterSet.whitespaceCharacterSet];
        if (!pattern.length || pattern.isAbsolutePath) return;
        NSMutableArray *folders = [cl_custom_clean_excluded_folders() mutableCopy];
        if (![folders containsObject:pattern]) [folders addObject:pattern];
        cl_custom_clean_save_excludes(cl_custom_clean_excluded_apps(), folders);
        [strongSelf reloadModel];
        [strongSelf.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Run

- (void)runTapped
{
    NSArray<CLCacheItem *> *apps = [CLCacheStore shared].items;
    if (!apps.count) {
        cl_alert(self, @"没有已扫描的应用", @"请先去清理页扫描一次，再回来运行自定义清理。");
        return;
    }
    _running = YES;
    [self updateRunButton];
    _statusLabel.text = @"正在清理…";
    __weak typeof(self) weakSelf = self;
    cl_custom_clean_run(apps, ^(NSString *status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (strongSelf) strongSelf->_statusLabel.text = status;
        });
    }, ^(NSDictionary *result) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf->_running = NO;
            [strongSelf updateRunButton];
            unsigned long long freed = [result[@"freed"] unsignedLongLongValue];
            NSUInteger failed = [result[@"failed"] unsignedIntegerValue];
            NSUInteger skipped = [result[@"skipped"] unsignedIntegerValue];
            NSArray *warnings = result[@"warnings"];
            NSString *text = [NSString stringWithFormat:@"已释放 %@。", cl_size_text(freed)];
            if (skipped) text = [text stringByAppendingFormat:@"跳过 %lu 个（太新/大小不符）。", (unsigned long)skipped];
            if (failed) text = [text stringByAppendingFormat:@"%lu 项失败（详见日志）。", (unsigned long)failed];
            if (warnings.count) text = [text stringByAppendingFormat:@"\n%@", [warnings componentsJoinedByString:@"\n"]];
            strongSelf->_statusLabel.text = text;
            cl_alert(strongSelf, @"自定义清理完成", text);
        });
    });
}

@end
