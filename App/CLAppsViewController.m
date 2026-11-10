//
//  CLAppsViewController.m
//  Cleaner v2 — WQAppsViewController transplanted from WQApps.m
//  (v0.1, commit 201591c8), renamed + Chinese strings. Backup/restore/
//  clear engine lives in Core/CLApp.m.
//

#import "CLAppsViewController.h"
#import "CLApp.h"
#import "CLAppDirectoryViewController.h"
#import "CLAppSupport.h"
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
    // v2.3: no device/model-id strip under the search field (user: the
    // iPhone17 (iPhone18,3) line is noise). The search bar is the header.
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
    return @"点一个应用进入它的目录，可在目录里备份、恢复或清空它的 Documents 和 Library。请先关闭该应用（在应用切换器里划掉它）；运行时操作可能不一致。备份存在 Cleaner/AppBackups，在文件 App 里可见。tmp 清空时不备份、不恢复。";
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

// v2.2: tap an app and go straight into its container directory.
// Backup / restore / clear live inside the directory view (nav-bar actions
// on the root level), not behind a sheet here. The old sheet (备份数据 /
// 恢复备份 / 清空数据…) and its handlers moved to CLAppActions, which both
// screens share.
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
    CLAppDirectoryViewController *dir = [[CLAppDirectoryViewController alloc] initWithApp:app];
    __weak typeof(self) weakSelf = self;
    dir.onDataChanged = ^{
        [weakSelf scan];
    };
    [self.navigationController pushViewController:dir animated:YES];
}
@end
