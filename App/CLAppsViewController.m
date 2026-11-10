//
//  CLAppsViewController.m
//  Cleaner v2 — WQAppsViewController transplanted from WQApps.m
//  (v0.1, commit 201591c8), renamed + Chinese strings. Backup/restore/
//  clear engine lives in Core/CLApp.m.
//

#import "CLAppsViewController.h"
#import "CLApp.h"
#import "CLGrant.h"
#import "CLScan.h"
#import "CLLaunchServices.h"
#import "CLUI.h"

@implementation CLAppsViewController {
    NSArray<CLAppItem *> *_apps;
    NSArray<CLAppItem *> *_visibleApps;
    NSString *_query;
    NSString *_status;
    BOOL _busy;
    CLScanCancellation *_scanCancellation;
    NSUInteger _scanGeneration;
    BOOL _scanning;
    NSTimeInterval _lastScanFinished;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"应用";
    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.placeholder = @"搜索应用";
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    self.tableView.tableHeaderView = cl_device_header(self.view.bounds.size.width);
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(userRefresh) forControlEvents:UIControlEventValueChanged];
    [self scan];
}

// Pull to refresh: rescan the containers instead of reusing the shared scan,
// and look for the app name database again if it wasn't found before.
- (void)userRefresh
{
    cl_enumerate_invalidate();
    cl_display_names_reset_miss();
    [self scan];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    if (_scanning || _busy) return;
    // Rescan when there is no finished scan yet (e.g. the previous one was
    // cancelled when the tab was left) or when the data is stale (> 60 s).
    // A backup/restore/clear already rescans when it finishes.
    if (_lastScanFinished <= 0 ||
        NSDate.date.timeIntervalSinceReferenceDate - _lastScanFinished > 60.0) {
        [self scan];
    }
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    if (_scanning) [_scanCancellation cancel];
}

- (void)setBusy:(BOOL)busy status:(NSString *)status
{
    _busy = busy;
    _status = status;
    [self.tableView reloadData];
}

// Watchdog for the app scan: each step records what it's doing; a timer logs
// any step that stays unchanged for 10 s, so a hang shows up in the Log.
static NSObject *gAppScanStepLock;
static NSString *gAppScanStep;
static CFAbsoluteTime gAppScanStepAt;
static NSUInteger gAppScanStepSerial;

static void CLAppScanStep(NSString *step)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gAppScanStepLock = [NSObject new]; });
    @synchronized (gAppScanStepLock) {
        gAppScanStep = [step copy];
        gAppScanStepAt = CFAbsoluteTimeGetCurrent();
        gAppScanStepSerial++;
    }
}

static void CLAppScanWatch(CLScanCancellation *cancellation, NSUInteger lastSerial, NSUInteger reported)
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *step = nil;
        NSUInteger serial = 0;
        double age = 0;
        @synchronized (gAppScanStepLock) {
            step = gAppScanStep;
            serial = gAppScanStepSerial;
            age = CFAbsoluteTimeGetCurrent() - gAppScanStepAt;
        }
        if (!step) return;   // scan finished
        NSUInteger nowReported = serial == lastSerial ? reported : 0;
        if (age >= 10 && nowReported < 6) {
            cl_log(@"app scan: still %@ after %.0f s%@", step, age, cancellation.isCancelled ? @" (screen left)" : @"");
            nowReported++;
        }
        CLAppScanWatch(cancellation, serial, nowReported);
    });
}

- (void)scan
{
    [_scanCancellation cancel];
    CLScanCancellation *cancellation = [CLScanCancellation new];
    _scanCancellation = cancellation;
    NSUInteger generation = ++_scanGeneration;
    _scanning = YES;
    [self setBusy:YES status:@"正在查找应用…"];
    NSString *home = [NSHomeDirectory() stringByResolvingSymlinksInPath];
    CLAppScanStep(@"finding app containers");
    CLAppScanWatch(cancellation, 0, 0);
    dispatch_async(cl_io(), ^{
        // Cancellation cleanup: reset the state on the main thread, but only
        // when no newer scan has started since (generation guard).
        void (^cancelled)(void) = ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != self->_scanGeneration) return;
                self->_scanning = NO;
                [self setBusy:NO status:@"扫描已取消。"];
            });
        };
        CFAbsoluteTime scanStarted = CFAbsoluteTimeGetCurrent();
        NSArray *containers = cl_enumerate(@"/private/var/mobile/Containers/Data/Application", 0, cancellation,
            ^(int64_t done, int64_t total, NSUInteger __unused f) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (generation != self->_scanGeneration || cancellation.isCancelled) return;
                    self->_status = [NSString stringWithFormat:@"正在查找应用… %lld%%", total ? (long long)(done * 100 / total) : 0];
                    [self.tableView reloadData];
                });
            });
        if (!cancellation.isCancelled && !cl_display_names_loaded()) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != self->_scanGeneration || cancellation.isCancelled) return;
                self->_status = @"正在读取应用名称…";
                [self.tableView reloadData];
            });
            CLAppScanStep(@"reading app names");
            CFAbsoluteTime namesStarted = CFAbsoluteTimeGetCurrent();
            cl_load_display_names();
            cl_log(@"app scan: app names %@ in %.1f s", cl_display_names_loaded() ? @"loaded" : @"not loaded",
                   CFAbsoluteTimeGetCurrent() - namesStarted);
        }
        if (containers) cl_log(@"app scan: %lu containers found in %.1f s; measuring", (unsigned long)containers.count,
                               CFAbsoluteTimeGetCurrent() - scanStarted);
        if (!containers && !cancellation.isCancelled) cl_log(@"app scan: container enumeration failed; see the preceding enumerate log");
        else if (containers && containers.count == 0) cl_log(@"app scan: enumeration returned no container paths; check the base path and inode bound");
        NSMutableArray<CLAppItem *> *apps = [NSMutableArray new];
        NSMutableArray<NSString *> *refused = [NSMutableArray new];
        NSUInteger i = 0, missingLabels = 0, limited = 0, sizeLimited = 0;
        for (NSString *c in containers) {
            if (cancellation.isCancelled) { CLAppScanStep(nil); cancelled(); return; }
            i++;
            if ([[c stringByResolvingSymlinksInPath] isEqualToString:home]) continue;  // ourselves
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != self->_scanGeneration || cancellation.isCancelled) return;
                self->_status = [NSString stringWithFormat:@"正在测量 %lu/%lu…", (unsigned long)i, (unsigned long)containers.count];
                [self.tableView reloadData];
            });
            NSString *shortName = c.lastPathComponent;
            CLAppScanStep([NSString stringWithFormat:@"getting access to %@ (%lu/%lu)", shortName, (unsigned long)i, (unsigned long)containers.count]);
            BOOL granted = cl_grant(c);
            if (!granted) {
                [refused addObject:[NSString stringWithFormat:@"%@ (%@)", c.lastPathComponent,
                                    cl_bundle_id_for_container(c) ?: @"unknown app"]];
            }
            CLAppScanStep([NSString stringWithFormat:@"reading the identifier of %@", shortName]);
            NSString *bid = cl_container_label(c);
            if (!bid.length) {
                missingLabels++;
                if (missingLabels <= 3) cl_log(@"app scan: no container identifier for %@", c);
            }
            struct stat identity;
            BOOL validBundle = CLAppSupportBundleIDValid(bid);
            BOOL hasIdentity = validBundle && cl_stat(c, &identity) && S_ISDIR(identity.st_mode);
            if (!granted || !validBundle || !hasIdentity) limited++;
            CLAppItem *app = [CLAppItem new];
            app.container = c;
            app.bundleID = bid;
            app.hasAccess = granted;
            app.hasIdentity = hasIdentity;
            app.containerDevice = hasIdentity ? identity.st_dev : 0;
            app.containerInode = hasIdentity ? identity.st_ino : 0;
            if (bid.length) (void)cl_app_icon(bid);   // warm the icon off the main thread
            app.name = bid.length ? (cl_display_name(bid) ?: bid)
                                  : [NSString stringWithFormat:@"Unknown container (%@)", c.lastPathComponent];
            app.bytes = 0;
            app.sizeKnown = NO;
            unsigned long long appSize = 0;
            BOOL sizeKnown = NO;
            CLAppScanStep([NSString stringWithFormat:@"measuring %@ (%@)", shortName, bid ?: @"no identifier"]);
            if (granted && hasIdentity && !cl_dir_size_cancellable(c, cancellation, &appSize, &sizeKnown)) { CLAppScanStep(nil); cancelled(); return; }
            app.bytes = appSize;
            app.sizeKnown = sizeKnown;
            if (granted && hasIdentity && !sizeKnown) sizeLimited++;
            app.backups = bid.length ? cl_app_backups(bid) : @[];
            [apps addObject:app];
        }
        CLAppScanStep(nil);
        if (cancellation.isCancelled) { cancelled(); return; }
        cl_log(@"app scan: %lu apps measured in %.1f s", (unsigned long)apps.count, CFAbsoluteTimeGetCurrent() - scanStarted);
        if (refused.count) cl_log(@"app scan: %lu containers refused access: %@", (unsigned long)refused.count,
                                  [refused componentsJoinedByString:@", "]);
        [apps sortUsingComparator:^NSComparisonResult(CLAppItem *a, CLAppItem *b) {
            return a.bytes > b.bytes ? NSOrderedAscending : (a.bytes < b.bytes ? NSOrderedDescending : NSOrderedSame);
        }];
        NSString *note = nil;
        if (!containers) note = @"容器枚举失败。详见日志。";
        else if (!containers.count) note = @"没有找到应用容器。请刷新，并查看日志。";
        else if (limited || sizeLimited) note = [NSString stringWithFormat:@"%lu 个容器 · %lu 个访问、身份、大小受限或没有标识。详见日志。",
                                                 (unsigned long)apps.count, (unsigned long)(limited + sizeLimited)];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_scanGeneration || cancellation.isCancelled) return;
            self->_scanning = NO;
            self->_lastScanFinished = NSDate.date.timeIntervalSinceReferenceDate;
            self->_apps = apps;
            [self rebuildVisibleApps];
            [self.refreshControl endRefreshing];
            [self setBusy:NO status:note];
        });
    });
}

- (NSArray<CLAppItem *> *)visibleApps
{
    return _visibleApps ?: @[];
}

- (void)rebuildVisibleApps
{
    if (!_query.length) {
        _visibleApps = _apps;
        return;
    }
    _visibleApps = [_apps filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(CLAppItem *a, NSDictionary *__unused b) {
        return [a.name localizedCaseInsensitiveContainsString:self->_query] ||
               [a.bundleID localizedCaseInsensitiveContainsString:self->_query];
    }]];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    _query = [searchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    [self rebuildVisibleApps];
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (_busy && !_apps.count) ? 1 : (NSInteger)self.visibleApps.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (_status) return _status;
    unsigned long long total = 0;
    for (CLAppItem *a in _apps) total += a.bytes;
    if (_query.length) return [NSString stringWithFormat:@"%lu / %lu 个应用", (unsigned long)self.visibleApps.count, (unsigned long)_apps.count];
    return [NSString stringWithFormat:@"%lu 个应用 · %@ 应用数据", (unsigned long)_apps.count, cl_size_text(total)];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    return @"点一个应用可备份、恢复或清空它的 Documents 和 Library。请先关闭该应用（在应用切换器里划掉它）；运行时操作可能不一致。备份存在 Cleaner/AppBackups，在文件 App 里可见。tmp 清空时不备份、不恢复。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"app"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"app"];
    UIListContentConfiguration *c = cell.defaultContentConfiguration;
    if (_busy && !_apps.count) {
        c.text = @"正在扫描…";
        cell.contentConfiguration = c;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }
    CLAppItem *app = self.visibleApps[(NSUInteger)indexPath.row];
    c.text = app.name;
    NSString *identifier = app.bundleID.length ? app.bundleID : app.container.lastPathComponent;
    BOOL hasBackup = app.backups.count > 0;
    if (!app.hasAccess) {
        c.secondaryText = [NSString stringWithFormat:@"访问不可用 · %@", identifier];
    } else if (!app.bundleID.length) {
        c.secondaryText = [NSString stringWithFormat:@"%@ · %@ · 没有标识", cl_size_text(app.bytes), identifier];
    } else if (!app.hasIdentity) {
        c.secondaryText = [NSString stringWithFormat:@"%@ · %@ · 容器身份不可用", cl_size_text(app.bytes), app.bundleID];
    } else if (!app.sizeKnown) {
        c.secondaryText = [NSString stringWithFormat:@"大小未知 · %@%@", app.bundleID, hasBackup ? @" · 已备份" : @""];
    } else {
        c.secondaryText = [NSString stringWithFormat:@"%@ · %@%@", cl_size_text(app.bytes), app.bundleID, hasBackup ? @" · 已备份" : @""];
    }
    c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    c.image = cl_app_icon(app.bundleID) ?: [UIImage systemImageNamed:@"app.dashed"];
    c.imageProperties.maximumSize = CGSizeMake(36, 36);
    cell.contentConfiguration = c;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_busy || !self.visibleApps.count) return;
    CLAppItem *app = self.visibleApps[(NSUInteger)indexPath.row];
    if (!app.hasAccess || !app.bundleID.length || !app.hasIdentity) {
        NSString *why = app.hasAccess && app.bundleID.length && !app.hasIdentity
            ? @"容器身份不可用或已变化。备份、恢复和清空对此条目不可用。"
            : app.hasAccess
            ? @"容器标识不可用。备份、恢复和清空对此条目不可用。"
            : @"沙盒访问不可用。请检查 App Group 并查看日志；只能复制容器路径。";
        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:app.name
            message:[NSString stringWithFormat:@"%@\n\n%@", app.container, why]
            preferredStyle:UIAlertControllerStyleActionSheet];
        [sheet addAction:[UIAlertAction actionWithTitle:@"复制容器路径" style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused a) {
            UIPasteboard.generalPasteboard.string = app.container;
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        sheet.popoverPresentationController.sourceView = cell ?: self.view;
        sheet.popoverPresentationController.sourceRect = (cell ?: self.view).bounds;
        [self presentViewController:sheet animated:YES completion:nil];
        return;
    }
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:app.name
        message:[NSString stringWithFormat:@"%@\n%@", app.bundleID,
                 app.sizeKnown ? [NSString stringWithFormat:@"%@ 数据", cl_size_text(app.bytes)] : @"大小未知"]
        preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"备份数据" style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused a) {
        [self backUp:app then:nil];
    }]];
    NSArray *backups = app.backups;
    NSString *latest = backups.firstObject[@"path"];
    if (latest) {
        NSString *title = backups.count == 1 ? [NSString stringWithFormat:@"恢复备份（%@）", cl_backup_label(backups.firstObject)]
                                             : [NSString stringWithFormat:@"恢复备份…（%lu）", (unsigned long)backups.count];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused a) {
            [self pickBackupToRestore:app from:[tableView cellForRowAtIndexPath:indexPath]];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"清空数据…" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
        [self confirmClear:app];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    sheet.popoverPresentationController.sourceView = cell ?: self.view;
    sheet.popoverPresentationController.sourceRect = (cell ?: self.view).bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)finish:(NSString *)title message:(NSString *)message
{
    [self setBusy:NO status:nil];
    cl_alert(self, title, message);
    [self scan];
}

- (void)backUp:(CLAppItem *)app then:(void (^)(BOOL ok))next
{
    [self setBusy:YES status:[NSString stringWithFormat:@"正在备份 %@…", app.name]];
    dispatch_async(cl_io(), ^{
        NSString *error = nil;
        NSString *dest = cl_make_app_backup(app.bundleID, app.container, app.containerDevice,
                                             app.containerInode, nil, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (next) { next(dest != nil); return; }
            [self finish:dest ? @"已备份" : @"备份失败"
                 message:dest ? [NSString stringWithFormat:@"已保存到 AppBackups/%@/%@", app.bundleID, dest.lastPathComponent]
                              : [NSString stringWithFormat:@"什么都没保存：%@", error ?: @"详见日志"]];
        });
    });
}

// The clear itself lives in Core (cl_clear_app_data): validate the container
// before every part, purge + verify each part, validate again at the end.
// The VC only shows progress and the result.
- (void)clear:(CLAppItem *)app
{
    [self setBusy:YES status:[NSString stringWithFormat:@"正在清理 %@…", app.name]];
    dispatch_async(cl_io(), ^{
        unsigned long long freed = 0;
        NSString *error = nil;
        BOOL ok = cl_clear_app_data(app, &freed, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self finish:ok ? @"数据已清空" : @"部分清空"
                 message:[NSString stringWithFormat:@"已释放约 %@。%@打开 %@ 重新开始。", cl_size_text(freed),
                          ok ? @"" : [NSString stringWithFormat:@" %@。请保持应用关闭再试一次。", error ?: @"部分项目未能删除（详见日志）"], app.name]];
        });
    });
}

- (void)confirmClear:(CLAppItem *)app
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"清空 %@？", app.name]
        message:@"删除该应用 Documents、Library 和 tmp 里的全部内容，如同刚安装。可选备份只包含 Documents 和 Library；tmp 丢弃后无法恢复。登录信息、设置和离线内容都会丢失。请先关闭该应用。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"先备份再清空" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
        [self backUp:app then:^(BOOL ok) {
            if (ok) [self clear:app];
            else [self finish:@"未清空" message:@"备份未完成，什么都没删。"];
        }];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"直接清空，不备份" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
        [self clear:app];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)pickBackupToRestore:(CLAppItem *)app from:(UIView *)source
{
    NSArray *backups = app.backups;
    if (backups.count == 1) { [self confirmRestore:app from:backups.firstObject]; return; }
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"恢复哪个备份？" message:app.name
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *__unused b in backups) {
        [sheet addAction:[UIAlertAction actionWithTitle:cl_backup_label(b) style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *__unused a) { [self confirmRestore:app from:b]; }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = source ?: self.view;
    sheet.popoverPresentationController.sourceRect = (source ?: self.view).bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)confirmRestore:(CLAppItem *)app from:(NSDictionary *)backup
{
    NSString *path = backup[@"path"];
    NSString *warning = [backup[@"verified"] boolValue] ? @""
        : [NSString stringWithFormat:@"\n\n该备份未验证（%@）。Cleaner 会在修改前重新检查它的内容。",
           backup[@"reason"] ?: @"没有类型化清单"];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"恢复 %@？", app.name]
        message:[NSString stringWithFormat:@"用 %@ 的备份替换该应用当前的 Documents 和 Library；tmp 不动。当前数据会先备份，失败时放回。请先关闭该应用：运行中的应用可能导致操作不一致。%@",
                 cl_backup_label(backup), warning]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"恢复" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
        [self setBusy:YES status:[NSString stringWithFormat:@"正在恢复 %@…", app.name]];
        dispatch_async(cl_io(), ^{
            NSString *title = nil, *message = nil;
            cl_restore_app(app, path, &title, &message);
            dispatch_async(dispatch_get_main_queue(), ^{ [self finish:title message:message]; });
        });
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end
