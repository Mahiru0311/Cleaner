//
//  CLCleanerViewController.m
//  Cleaner v2 — WQCacheCleanerViewController transplanted from WQCache.m
//  (v0.1, commit 201591c8), renamed + Chinese strings. The scan body lives
//  in CLCacheScanner (Core/CLCache.m) so Home can share it.
//

#import "CLCleanerViewController.h"
#import "CLCache.h"
#import "CLCustomCleanViewController.h"
#import "CLGrant.h"
#import "CLScan.h"
#import "CLUI.h"

// Scan progress fraction from a progress string like
// "正在测量应用 23/114…". -1 when the string carries no N/M (e.g. the
// "正在查找应用… 42%" phase), so the bar falls back to the selected share.
static CGFloat CLCacheScanFraction(NSString *status)
{
    NSScanner *sc = [NSScanner scannerWithString:status ?: @""];
    NSInteger done = 0, total = 0;
    if (![sc scanUpToCharactersFromSet:NSCharacterSet.decimalDigitCharacterSet intoString:nil]) return -1;
    if (![sc scanInteger:&done]) return -1;
    if (![sc scanString:@"/" intoString:nil]) return -1;
    if (![sc scanInteger:&total] || total <= 0) return -1;
    return (CGFloat)done / (CGFloat)total;
}

// Merge key for a row (v2.8): bundle id for apps (one app can own
// several containers, but the scan emits one row per app), the target
// path for the crash-logs row (no bundle id), container path as a
// fallback.
static NSString *CLCacheItemMergeKey(CLCacheItem *item)
{
    if (item.crashLogs) return item.targets.firstObject ?: @"crash-logs";
    if (item.bundleID.length) return item.bundleID;
    return item.containerPath ?: @"";
}

static void CLCacheSelectionCategories(NSArray<CLCacheItem *> *items,
                                       BOOL *hasApps,
                                       BOOL *hasCrashLogs,
                                       NSUInteger *appCount)
{
    BOOL apps = NO, crashLogs = NO;
    NSUInteger count = 0;
    for (CLCacheItem *item in items) {
        if (item.crashLogs) {
            crashLogs = YES;
        } else {
            apps = YES;
            count++;
        }
    }
    if (hasApps) *hasApps = apps;
    if (hasCrashLogs) *hasCrashLogs = crashLogs;
    if (appCount) *appCount = count;
}

static NSString *CLCacheConfirmationScope(NSArray<CLCacheItem *> *items)
{
    BOOL hasApps = NO, hasCrashLogs = NO;
    NSUInteger appCount = 0;
    CLCacheSelectionCategories(items, &hasApps, &hasCrashLogs, &appCount);
    if (hasApps && hasCrashLogs) {
        return [NSString stringWithFormat:@"删除 %lu 个应用的 Library/Caches 和 tmp，并删除崩溃日志",
                (unsigned long)appCount];
    }
    if (hasApps) {
        return [NSString stringWithFormat:@"删除 %lu 个应用的 Library/Caches 和 tmp",
                (unsigned long)appCount];
    }
    if (hasCrashLogs) return @"删除崩溃日志";
    return @"删除选中的缓存目标";
}

static NSString *CLCacheFooterScope(NSArray<CLCacheItem *> *items)
{
    BOOL hasApps = NO, hasCrashLogs = NO;
    CLCacheSelectionCategories(items, &hasApps, &hasCrashLogs, NULL);
    if (hasApps && hasCrashLogs) {
        return @"清理选中应用的 Library/Caches 和 tmp，并删除选中的崩溃日志。应用会在使用时重建缓存，部分离线内容（音乐、地图、下载）清掉后会重新下载。不保留备份。";
    }
    if (hasApps) {
        return @"清理选中应用的 Library/Caches 和 tmp。应用会在使用时重建缓存，部分离线内容（音乐、地图、下载）清掉后会重新下载。不保留备份。";
    }
    if (hasCrashLogs) return @"删除选中的崩溃日志。无法撤销，不保留备份。";
    return @"选择应用缓存或崩溃日志以查看删除范围。不保留备份。";
}

@interface CLCleanerCell : UITableViewCell
@property (nonatomic, strong) UIImageView *checkView, *iconView;
@property (nonatomic, strong) UILabel *nameLabel, *detailLabel, *sizeLabel;
// Spinner shown while this row is being cleaned (v2.3); it occupies the
// check's slot so the row does not shift when the state changes.
@property (nonatomic, strong) UIActivityIndicatorView *cleanSpinner;
@end

@implementation CLCleanerCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        _checkView = [UIImageView new];
        _checkView.contentMode = UIViewContentModeScaleAspectFit;
        _cleanSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        _cleanSpinner.hidesWhenStopped = YES;
        _iconView = [UIImageView new];
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.layer.cornerRadius = 8;
        _iconView.layer.cornerCurve = kCACornerCurveContinuous;
        _iconView.clipsToBounds = YES;
        _nameLabel = [UILabel new];
        _nameLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        _nameLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        _detailLabel = [UILabel new];
        _detailLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        _detailLabel.textColor = UIColor.secondaryLabelColor;
        _detailLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        _sizeLabel = [UILabel new];
        _sizeLabel.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightSemibold];
        _sizeLabel.textAlignment = NSTextAlignmentRight;
        for (UIView *v in @[_checkView, _cleanSpinner, _iconView, _nameLabel, _detailLabel, _sizeLabel]) {
            v.translatesAutoresizingMaskIntoConstraints = NO;
            [self.contentView addSubview:v];
        }
        [_sizeLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [_sizeLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        UILayoutGuide *m = self.contentView.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[
            [_checkView.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
            [_checkView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_checkView.widthAnchor constraintEqualToConstant:24],
            [_checkView.heightAnchor constraintEqualToConstant:24],
            [_cleanSpinner.centerXAnchor constraintEqualToAnchor:_checkView.centerXAnchor],
            [_cleanSpinner.centerYAnchor constraintEqualToAnchor:_checkView.centerYAnchor],
            [_iconView.leadingAnchor constraintEqualToAnchor:_checkView.trailingAnchor constant:12],
            [_iconView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_iconView.widthAnchor constraintEqualToConstant:36],
            [_iconView.heightAnchor constraintEqualToConstant:36],
            [_sizeLabel.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
            [_sizeLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_sizeLabel.widthAnchor constraintGreaterThanOrEqualToConstant:76],
            [_nameLabel.leadingAnchor constraintEqualToAnchor:_iconView.trailingAnchor constant:12],
            [_nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_sizeLabel.leadingAnchor constant:-8],
            [_nameLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:11],
            [_detailLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
            [_detailLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_sizeLabel.leadingAnchor constant:-8],
            [_detailLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:2],
            [_detailLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-11],
        ]];
    }
    return self;
}

@end

// Summary card: reclaimable total, a bar for the selected share, status.
// doneView (v2.3) is the green check that springs in when a clean finishes.
@interface CLSummaryCell : UITableViewCell
@property (nonatomic, strong) UILabel *captionLabel, *totalLabel, *statusLabel;
@property (nonatomic, strong) UIProgressView *bar;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIImageView *doneView;
@end

@implementation CLSummaryCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        _captionLabel = [UILabel new];
        _captionLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        _captionLabel.textColor = UIColor.secondaryLabelColor;
        _totalLabel = [UILabel new];
        _totalLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleLargeTitle]
                            scaledFontForFont:[UIFont systemFontOfSize:34 weight:UIFontWeightBold]];
        _totalLabel.adjustsFontForContentSizeCategory = YES;
        _bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
        _bar.progressTintColor = UIColor.systemBlueColor;
        _statusLabel = [UILabel new];
        _statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        _statusLabel.textColor = UIColor.secondaryLabelColor;
        _statusLabel.numberOfLines = 0;
        _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        _spinner.hidesWhenStopped = YES;
        _doneView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark.circle.fill"]];
        _doneView.tintColor = UIColor.systemGreenColor;
        _doneView.contentMode = UIViewContentModeScaleAspectFit;
        _doneView.hidden = YES;
        _doneView.translatesAutoresizingMaskIntoConstraints = NO;
        [NSLayoutConstraint activateConstraints:@[
            [_doneView.widthAnchor constraintEqualToConstant:28],
            [_doneView.heightAnchor constraintEqualToConstant:28],
        ]];
        UIStackView *captionRow = [[UIStackView alloc] initWithArrangedSubviews:@[_captionLabel, _doneView, _spinner]];
        captionRow.spacing = 8;
        captionRow.alignment = UIStackViewAlignmentCenter;
        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[captionRow, _totalLabel, _bar, _statusLabel]];
        stack.axis = UILayoutConstraintAxisVertical;
        stack.spacing = 6;
        [stack setCustomSpacing:10 afterView:_totalLabel];
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:stack];
        UILayoutGuide *m = self.contentView.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
            [stack.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
            [stack.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:14],
            [stack.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-14],
        ]];
    }
    return self;
}

@end

@implementation CLCleanerViewController {
    NSArray<CLCacheItem *> *_items;
    NSArray<CLCacheItem *> *_visibleItems;
    NSString *_query;
    NSString *_status;   // scan / clean progress, nil when idle
    NSString *_result;   // last clean result
    BOOL _scanning, _cleaning, _scanLimited;
    CLScanCancellation *_cleanCancellation;
    CLCacheScanner *_scanner;
    NSUInteger _scanGeneration;
    NSTimeInterval _lastScanFinished;
    // v2.3 animations: scan progress fraction (-1 = no N/M in the status),
    // the row being cleaned, rows already cleaned, and the total-countdown
    // display-link state. _pendingShortcutAction is a shortcut (cleaner://)
    // that arrived while a scan was running.
    CGFloat _scanFraction;
    CLCacheItem *_cleaningItem;
    NSMutableSet<CLCacheItem *> *_cleanedItems;
    CADisplayLink *_totalDisplayLink;
    unsigned long long _displayedTotal;
    unsigned long long _totalAnimFrom;
    unsigned long long _totalAnimTarget;
    NSTimeInterval _totalAnimStart;
    BOOL _lastCleanSucceeded;
    NSString *_pendingShortcutAction;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"缓存清理";
    // v2.3: no device/model-id strip under the search field (user: the
    // iPhone17 (iPhone18,3) line is noise). The search bar is the header.
    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.placeholder = @"搜索应用";
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(userRefresh) forControlEvents:UIControlEventValueChanged];
    // v2.8: paint the last scan instantly (cached first paint). A cold
    // launch used to show an empty spinner until the first measurement
    // batch arrived; the persisted list is on screen immediately, and
    // the refresh scan below replaces its rows with fresh measurements
    // as they arrive (merge-by-key in the batch handler). The rows are
    // display-only — they carry no target records, so they can never be
    // cleaned — and the clean button stays hidden while refreshing.
    NSArray<CLCacheItem *> *cached = cl_cache_load_items(NULL);
    if (cached.count) {
        _items = cached;
        [self rebuildVisibleItems];
        [self.tableView reloadData];
    }
    [self scan];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    if (_scanning || _cleaning) return;
    // Rescan when there is no finished scan yet (e.g. the previous one was
    // cancelled when the tab was left) or when the data is stale (> 60 s).
    // A clean that failed validation already rescans by itself.
    if (_lastScanFinished <= 0 ||
        NSDate.date.timeIntervalSinceReferenceDate - _lastScanFinished > 60.0) {
        [self scan];
    }
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    if (_scanning) [_scanner cancel];
    if (_cleaning) [_cleanCancellation cancel];
    [self.refreshControl endRefreshing];
}

- (NSArray<CLCacheItem *> *)visibleItems
{
    return _visibleItems ?: @[];
}

- (void)rebuildVisibleItems
{
    if (!_query.length) {
        _visibleItems = _items;
        return;
    }
    _visibleItems = [_items filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(CLCacheItem *it, NSDictionary *__unused b) {
        return [it.name localizedCaseInsensitiveContainsString:self->_query] ||
               (it.bundleID && [it.bundleID localizedCaseInsensitiveContainsString:self->_query]);
    }]];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    _query = [searchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    [self rebuildVisibleItems];
    [self.tableView reloadData];
    [self updateButtons];
}

- (void)setStatus:(NSString *)status
{
    _status = status;
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)updateButtons
{
    if (_scanning) {
        self.navigationItem.rightBarButtonItems = nil;
        return;
    }
    if (_cleaning) {
        UIBarButtonItem *stop = [[UIBarButtonItem alloc] initWithTitle:@"停止" style:UIBarButtonItemStylePlain
                                                                 target:self action:@selector(stopClean)];
        self.navigationItem.rightBarButtonItems = @[stop];
        return;
    }
    NSUInteger n = 0;
    unsigned long long _selBytes = 0;
    for (CLCacheItem *it in _items) if (it.selected) { n++; _selBytes += it.bytes; }
    NSString *_cleanTitle = _selBytes > 0 ? [NSString stringWithFormat:@"清理（%@）", cl_size_text(_selBytes)] : @"清理";
    UIBarButtonItem *clean = [[UIBarButtonItem alloc] initWithTitle:_cleanTitle style:cl_primary_button_style()
                                                             target:self action:@selector(confirmClean)];
    clean.enabled = n > 0;
    NSArray *visible = self.visibleItems;
    BOOL allVisible = visible.count > 0;
    for (CLCacheItem *it in visible) if (it.limited || !it.selected) { allVisible = NO; break; }
    __weak typeof(self) weakSelf = self;
    UIAction *__unused all = [UIAction actionWithTitle:@"全选" image:[UIImage systemImageNamed:@"checkmark.circle"]
                                   identifier:nil handler:^(UIAction *__unused a) { [weakSelf selectWhere:^BOOL(CLCacheItem *__unused it) { return YES; }]; }];
    UIAction *none = [UIAction actionWithTitle:@"全不选" image:[UIImage systemImageNamed:@"circle"]
                                    identifier:nil handler:^(UIAction *__unused a) { [weakSelf selectWhere:^BOOL(CLCacheItem *__unused it) { return NO; }]; }];
    UIAction *large = [UIAction actionWithTitle:@"只选大缓存（50 MB+）" image:[UIImage systemImageNamed:@"arrow.up.circle"]
                                     identifier:nil handler:^(UIAction *__unused a) {
        [weakSelf selectWhere:^BOOL(CLCacheItem *__unused it) { return it.bytes >= 50ull * 1000 * 1000; }];
    }];
    // v2.3: custom cleaning — user-defined rules, presets and excludes.
    UIAction *custom = [UIAction actionWithTitle:@"自定义清理…" image:[UIImage systemImageNamed:@"slider.horizontal.3"]
                                     identifier:nil handler:^(UIAction *__unused a) {
        [weakSelf.navigationController pushViewController:[CLCustomCleanViewController new] animated:YES];
    }];
    all.state = allVisible ? UIMenuElementStateOn : UIMenuElementStateOff;
    UIBarButtonItem *select = [[UIBarButtonItem alloc] initWithTitle:@"选择"
                                                                menu:[UIMenu menuWithChildren:@[all, none, large, custom]]];
    select.enabled = visible.count > 0;
    self.navigationItem.rightBarButtonItems = @[clean, select];
}

// Pull to refresh: rescan the containers instead of reusing the shared scan,
// and look for the app name database again if it wasn't found before.

- (void)userRefresh
{
    [[CLCacheStore shared] invalidateScan];
    [self scan];
}

- (void)scan
{
    if (!_scanner) _scanner = [CLCacheScanner new];
    NSUInteger generation = ++_scanGeneration;
    _scanning = YES;
    _scanLimited = NO;
    _result = nil;
    _scanFraction = -1;
    _cleaningItem = nil;
    _cleanedItems = nil;
    _lastCleanSucceeded = NO;
    [_totalDisplayLink invalidate];
    _totalDisplayLink = nil;
    // Tell Home not to start a second scan while this one runs.
    [[CLCacheStore shared] setScanning:YES];
    [self updateButtons];
    [self setStatus:@"正在查找应用…"];
    __weak typeof(self) weakSelf = self;
    // v2.2: incremental results — finished rows appear in batches of 8
    // while the scan runs (merged, re-sorted, reloaded); the final
    // completion below still delivers the complete list as authoritative.
    // v2.3: batches insert with a fade instead of reloadData, and the
    // progress bar shows the real scan fraction (N/M) while scanning.
    [_scanner startWithProgress:^(NSString *status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || generation != strongSelf->_scanGeneration) return;
            strongSelf->_scanFraction = CLCacheScanFraction(status);
            [strongSelf setStatus:status];
        });
    } itemsUpdate:^(NSArray<CLCacheItem *> *newItems) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || generation != strongSelf->_scanGeneration || strongSelf->_cleaning) return;
            // v2.8: merge by key, not append. The list may start as the
            // persisted (display-only) rows; a fresh measurement for the
            // same app REPLACES its cached row in place (carrying the
            // user's selection over), so the list never shows the same
            // app twice and the total stays stable as rows refresh.
            NSMutableArray<CLCacheItem *> *merged = [(strongSelf->_items ?: @[]) mutableCopy];
            NSMutableSet<CLCacheItem *> *replaced = [NSMutableSet new];
            for (CLCacheItem *fresh in newItems) {
                NSString *key = CLCacheItemMergeKey(fresh);
                NSUInteger existing = [merged indexOfObjectPassingTest:^BOOL(CLCacheItem *it, NSUInteger __unused i, BOOL * __unused s) {
                    return [CLCacheItemMergeKey(it) isEqualToString:key];
                }];
                if (existing != NSNotFound) {
                    fresh.selected = merged[existing].selected;
                    merged[existing] = fresh;
                    [replaced addObject:fresh];
                } else {
                    [merged addObject:fresh];
                }
            }
            strongSelf->_items = [merged sortedArrayUsingComparator:^NSComparisonResult(CLCacheItem *a, CLCacheItem *b) {
                return a.bytes > b.bytes ? NSOrderedAscending : (a.bytes < b.bytes ? NSOrderedDescending : NSOrderedSame);
            }];
            [strongSelf rebuildVisibleItems];
            // Insert the new rows with a fade (v2.3) instead of reloading
            // the whole table — the list visibly grows while scanning.
            // A replaced cached row is RELOADED, not inserted: inserting
            // a row that already exists crashes the table update.
            // While searching the visible list is filtered, so fall back
            // to a plain reload there.
            if (!strongSelf->_query.length) {
                NSMutableArray<NSIndexPath *> *insertPaths = [NSMutableArray new];
                NSMutableArray<NSIndexPath *> *reloadPaths = [NSMutableArray new];
                for (CLCacheItem *item in newItems) {
                    NSUInteger row = [strongSelf->_items indexOfObjectIdenticalTo:item];
                    if (row == NSNotFound) continue;
                    NSIndexPath *path = [NSIndexPath indexPathForRow:row inSection:1];
                    if ([replaced containsObject:item]) [reloadPaths addObject:path];
                    else [insertPaths addObject:path];
                }
                if (insertPaths.count || reloadPaths.count) {
                    [strongSelf.tableView beginUpdates];
                    if (insertPaths.count) [strongSelf.tableView insertRowsAtIndexPaths:insertPaths withRowAnimation:UITableViewRowAnimationFade];
                    if (reloadPaths.count) [strongSelf.tableView reloadRowsAtIndexPaths:reloadPaths withRowAnimation:UITableViewRowAnimationFade];
                    [strongSelf.tableView endUpdates];
                    // insertRows does not refresh the section header count.
                    UITableViewHeaderFooterView *header = [strongSelf.tableView headerViewForSection:1];
                    if (header) header.textLabel.text = [strongSelf tableView:strongSelf.tableView titleForHeaderInSection:1];
                }
            } else {
                [strongSelf.tableView reloadData];
            }
            [strongSelf updateButtons];
        });
    } completion:^(NSArray<CLCacheItem *> *items, BOOL limited, NSString *note, BOOL cancelled, NSUInteger totalApps) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || generation != strongSelf->_scanGeneration) return;
            if (cancelled) {
                // The scan was cancelled (tab left, or a new scan started).
                // Keep the old list; reset the state so the page rescans on
                // appear instead of staying stuck on "scanning".
                strongSelf->_scanning = NO;
                strongSelf->_status = note;
                strongSelf->_scanFraction = -1;
                [strongSelf.refreshControl endRefreshing];
                [strongSelf.tableView reloadData];
                [strongSelf updateButtons];
                [[CLCacheStore shared] setScanning:NO];
                return;
            }
            strongSelf->_items = items;
            [strongSelf rebuildVisibleItems];
            strongSelf->_scanning = NO;
            strongSelf->_scanLimited = limited;
            strongSelf->_status = note;
            strongSelf->_scanFraction = -1;
            strongSelf->_lastScanFinished = NSDate.date.timeIntervalSinceReferenceDate;
            [strongSelf.refreshControl endRefreshing];
            [strongSelf.tableView reloadData];
            [strongSelf updateButtons];
            [[CLCacheStore shared] updateWithItems:items limited:limited totalApps:totalApps];
            // A shortcut (cleaner://) that arrived mid-scan runs now.
            if (strongSelf->_pendingShortcutAction) {
                NSString *action = strongSelf->_pendingShortcutAction;
                strongSelf->_pendingShortcutAction = nil;
                [strongSelf startShortcutAction:action];
            }
            // The previous clean succeeded: spring the green check into
            // the summary card (v2.3) with a success haptic.
            if (strongSelf->_lastCleanSucceeded) {
                strongSelf->_lastCleanSucceeded = NO;
                CLSummaryCell *cell = (CLSummaryCell *)[strongSelf.tableView cellForRowAtIndexPath:
                                                        [NSIndexPath indexPathForRow:0 inSection:0]];
                if (cell) {
                    cell.doneView.hidden = NO;
                    cell.doneView.transform = CGAffineTransformMakeScale(0.3, 0.3);
                    cell.doneView.alpha = 0;
                    [UIView animateWithDuration:0.5 delay:0 usingSpringWithDamping:0.6
                              initialSpringVelocity:0 options:0 animations:^{
                        cell.doneView.transform = CGAffineTransformIdentity;
                        cell.doneView.alpha = 1;
                    } completion:nil];
                    [UINotificationFeedbackGenerator.new notificationOccurred:UINotificationFeedbackTypeSuccess];
                }
            }
        });
    }];
}

#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return section == 0 ? 1 : (NSInteger)self.visibleItems.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == 0 || !_items.count) return nil;
    NSUInteger shown = self.visibleItems.count;
    NSUInteger appCount = 0;
    for (CLCacheItem *item in _items) if (!item.crashLogs) appCount++;
    if (!appCount) return @"崩溃日志";
    return _query.length ? [NSString stringWithFormat:@"%lu / %lu", (unsigned long)shown, (unsigned long)_items.count]
                         : [NSString stringWithFormat:@"%lu 个应用与扩展", (unsigned long)appCount];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == 0 || !_items.count) return nil;
    NSArray<CLCacheItem *> *selected = [_items filteredArrayUsingPredicate:
        [NSPredicate predicateWithFormat:@"selected == YES"]];
    return [CLCacheFooterScope(selected) stringByAppendingString:@" 请先关闭正在运行的应用。"];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 0) {
        CLSummaryCell *cell = [tableView dequeueReusableCellWithIdentifier:@"summary"]
            ?: [[CLSummaryCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"summary"];
        unsigned long long total = 0, selected = 0;
        NSUInteger n = 0;
        for (CLCacheItem *it in _items) { total += it.bytes; if (it.selected) { selected += it.bytes; n++; } }
        BOOL busy = _scanning || _cleaning;
        cell.captionLabel.text = busy ? (_cleaning ? @"正在清理…" : @"正在扫描…") : @"可清理";
        if (busy) [cell.spinner startAnimating]; else [cell.spinner stopAnimating];
        // The success check is transient: a reused cell always starts hidden;
        // the spring animation after a successful clean unhides the visible one.
        cell.doneView.hidden = YES;
        // While cleaning, the big total is the animated countdown value
        // (v2.3); otherwise it is the live total.
        cell.totalLabel.text = (_scanning && !_items.count) ? @"–"
            : cl_size_text(_cleaning ? _displayedTotal : total);
        // While scanning, the bar is the real scan fraction (N/M) when the
        // status carries one; otherwise the selected share as before.
        cell.bar.progress = _scanning && _scanFraction >= 0 ? (float)_scanFraction
            : (total ? (float)((double)selected / (double)total) : 0);
        cell.bar.hidden = _scanning && !_items.count;
        cell.statusLabel.text = _status ?: _result
            ?: [NSString stringWithFormat:@"已选 %@ · %lu 个应用", cl_size_text(selected), (unsigned long)n];
        return cell;
    }
    CLCleanerCell *cell = [tableView dequeueReusableCellWithIdentifier:@"item"]
        ?: [[CLCleanerCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"item"];
    CLCacheItem *item = self.visibleItems[(NSUInteger)indexPath.row];
    cell.nameLabel.text = item.name;
    if (item.crashLogs) {
        cell.detailLabel.text = item.cacheKnown ? @"崩溃日志 · osanalytics" : @"崩溃日志 · 访问受限";
    } else {
        NSString *cache = item.cacheKnown ? cl_size_text(item.cacheBytes) : @"未知";
        NSString *temp = item.tempKnown ? cl_size_text(item.tempBytes) : @"未知";
        cell.detailLabel.text = [NSString stringWithFormat:@"缓存 %@ · 临时 %@%@", cache, temp,
                                 item.limited ? @" · 访问受限" : @""];
    }
    cell.sizeLabel.text = cl_size_text(item.bytes);
    cell.iconView.image = cl_app_icon(item.bundleID)
        ?: [UIImage systemImageNamed:item.bundleID ? @"app.dashed" : @"exclamationmark.triangle"];
    cell.iconView.tintColor = UIColor.secondaryLabelColor;
    // v2.3 cleaning states: the row being cleaned shows a spinner in the
    // check's slot; a cleaned row shows a green check; otherwise the
    // selection check as before.
    if (item == _cleaningItem) {
        cell.checkView.hidden = YES;
        [cell.cleanSpinner startAnimating];
    } else if ([_cleanedItems containsObject:item]) {
        [cell.cleanSpinner stopAnimating];
        cell.checkView.hidden = NO;
        cell.checkView.image = [UIImage systemImageNamed:@"checkmark.circle.fill"];
        cell.checkView.tintColor = UIColor.systemGreenColor;
    } else {
        [cell.cleanSpinner stopAnimating];
        cell.checkView.hidden = NO;
        cell.checkView.image = [UIImage systemImageNamed:item.selected ? @"checkmark.circle.fill" : @"circle"];
        cell.checkView.tintColor = item.selected ? UIColor.systemBlueColor : UIColor.tertiaryLabelColor;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0 || _scanning || _cleaning) return;
    CLCacheItem *item = self.visibleItems[(NSUInteger)indexPath.row];
    if (item.limited) {
        cl_alert(self, @"无法清理",
                 @"这一行访问或身份信息不完整。请关闭该应用后重新扫描。");
        return;
    }
    item.selected = !item.selected;
    [tableView reloadRowsAtIndexPaths:@[indexPath, [NSIndexPath indexPathForRow:0 inSection:0]]
                     withRowAnimation:UITableViewRowAnimationNone];
    [self updateButtons];
}

#pragma mark Actions

// v2.3: animate the big total from its current value down to `target`
// over 0.4 s (ease-out) with a display link, so the number visibly counts
// down as cache is freed instead of jumping. Writes straight into the
// visible summary cell; cellForRow keeps _displayedTotal as the source
// while cleaning, so a section reload mid-animation cannot jump it.
- (void)animateTotalTo:(unsigned long long)target
{
    [_totalDisplayLink invalidate];
    _totalAnimFrom = _displayedTotal;
    _totalAnimTarget = target;
    _totalAnimStart = CACurrentMediaTime();
    _totalDisplayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(totalAnimTick)];
    [_totalDisplayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)totalAnimTick
{
    NSTimeInterval t = (CACurrentMediaTime() - _totalAnimStart) / 0.4;
    if (t >= 1) {
        [_totalDisplayLink invalidate];
        _totalDisplayLink = nil;
        _displayedTotal = _totalAnimTarget;
    } else {
        CGFloat e = 1 - pow(1 - t, 3);
        _displayedTotal = _totalAnimFrom + (unsigned long long)((double)(_totalAnimTarget - _totalAnimFrom) * (double)e);
    }
    CLSummaryCell *cell = (CLSummaryCell *)[self.tableView cellForRowAtIndexPath:
                                            [NSIndexPath indexPathForRow:0 inSection:0]];
    if (cell) cell.totalLabel.text = cl_size_text(_displayedTotal);
}

- (unsigned long long)currentTotalBytes
{
    unsigned long long total = 0;
    for (CLCacheItem *it in _items) total += it.bytes;
    return total;
}

// iPhone Shortcuts (cleaner://clean, cleaner://scan). clean selects all
// cleanable rows and shows the usual confirm dialog — the shortcut never
// deletes without the user confirming in the app.
- (void)startShortcutAction:(NSString *)action
{
    if (_cleaning) return;
    if (_scanning) {
        _pendingShortcutAction = action;
        return;
    }
    if ([action isEqualToString:@"scan"]) {
        [self userRefresh];
        return;
    }
    if (![action isEqualToString:@"clean"]) return;
    [self selectWhere:^BOOL(CLCacheItem *__unused it) { return YES; }];
    [self confirmClean];
}

// Applies to the rows the current search shows.
- (void)selectWhere:(BOOL (^)(CLCacheItem *item))rule
{
    for (CLCacheItem *it in self.visibleItems) it.selected = !it.limited && rule(it);
    [self.tableView reloadData];
    [self updateButtons];
}

- (void)stopClean
{
    [_cleanCancellation cancel];
    [self setStatus:@"当前项完成后停止…"];
}

- (void)confirmClean
{
    NSMutableArray<CLCacheItem *> *selected = [NSMutableArray new];
    unsigned long long sel = 0;
    for (CLCacheItem *item in _items) {
        if (!item.selected) continue;
        [selected addObject:item];
        sel += item.bytes;
    }
    if (!selected.count) return;
    NSString *msg = [NSString stringWithFormat:@"%@，共约 %@。无法撤销，不保留备份。请先关闭选中的应用；清理中可在应用间停止。",
                     CLCacheConfirmationScope(selected), cl_size_text(sel)];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"清理缓存？" message:msg
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"清理" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
        [self clean];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)clean
{
    NSArray<CLCacheItem *> *selected = [_items filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"selected == YES"]];
    CLScanCancellation *cancellation = [CLScanCancellation new];
    _cleanCancellation = cancellation;
    _cleaning = YES;
    _cleanedItems = [NSMutableSet new];
    _cleaningItem = nil;
    // The countdown starts at the current total; each finished item moves
    // it down by exactly what was freed (v2.3, before/after accounting).
    unsigned long long startTotal = [self currentTotalBytes];
    _displayedTotal = startTotal;
    [self updateButtons];
    [self setStatus:@"正在清理…"];
    dispatch_async(cl_io(), ^{
        unsigned long long freed = 0;
        BOOL allOk = YES;
        BOOL cancelled = NO;
        NSUInteger failedItems = 0;
        NSString *validationFailure = nil;
        for (CLCacheItem *item in selected) {
            if (cancellation.isCancelled) { cancelled = YES; break; }
            NSString *reason = nil;
            if (!CLCacheValidateItem(item, &reason)) {
                allOk = NO;
                validationFailure = validationFailure ?: [NSString stringWithFormat:@"%@ (%@)", item.name, reason ?: @"身份已变化"];
                cl_log(@"clean: refusing %@ because %@", item.name, reason ?: @"身份校验失败");
            }
        }
        if (validationFailure) {
            // Nothing was touched: refuse the whole clean and rescan, so the
            // list (and the clean button) reflects the current containers.
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_cleaning = NO;
                self->_cleanCancellation = nil;
                self->_scanLimited = YES;
                self->_status = nil;
                [self scan];
                self->_result = [NSString stringWithFormat:@"清理已取消：%@。已重新扫描。", validationFailure];
            });
            return;
        }
        NSUInteger i = 0;
        for (CLCacheItem *item in selected) {
            if (cancellation.isCancelled) { cancelled = YES; break; }
            i++;
            dispatch_async(dispatch_get_main_queue(), ^{
                // Per-row progress (v2.3): spinner in the check's slot.
                self->_cleaningItem = item;
                NSUInteger row = [self.visibleItems indexOfObjectIdenticalTo:item];
                if (row != NSNotFound) {
                    [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:row inSection:1]]
                                          withRowAnimation:UITableViewRowAnimationNone];
                }
                [self setStatus:[NSString stringWithFormat:@"正在清理第 %lu / %lu 个：%@",
                                 (unsigned long)i, (unsigned long)selected.count, item.name]];
            });
            unsigned long long beforeItem = freed;
            BOOL itemOk = YES;
            for (CLCacheTargetRecord *record in item.targetRecords) {
                if (cancellation.isCancelled) { cancelled = YES; break; }
                NSString *reason = nil;
                if (!CLCacheValidateItem(item, &reason)) {
                    allOk = NO;
                    itemOk = NO;
                    validationFailure = [NSString stringWithFormat:@"%@ (%@)", item.name, reason ?: @"身份已变化"];
                    cl_log(@"clean: stopped before %@ because %@", record.path, reason ?: @"身份校验失败");
                    break;
                }
                if (!cl_purge_contents_cancellable(record.path, &freed, cancellation)) {
                    allOk = NO;
                    itemOk = NO;
                    if (cancellation.isCancelled) { cancelled = YES; break; }
                }
            }
            unsigned long long itemFreed = freed - beforeItem;
            cl_log(@"clean: %@ freed %llu bytes", item.name, itemFreed);
            if (!itemOk) failedItems++;
            // Per-row result + total countdown (v2.3). A fully cleaned row
            // zeroes its size and gets a green check; a failed row keeps
            // its size (the rescan after the clean corrects any remainder).
            unsigned long long freedSoFar = freed;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (itemOk) {
                    [self->_cleanedItems addObject:item];
                    item.cacheBytes = 0;
                    item.tempBytes = 0;
                }
                self->_cleaningItem = nil;
                NSUInteger row = [self.visibleItems indexOfObjectIdenticalTo:item];
                if (row != NSNotFound) {
                    [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:row inSection:1]]
                                          withRowAnimation:UITableViewRowAnimationFade];
                }
                [self animateTotalTo:startTotal >= freedSoFar ? startTotal - freedSoFar : 0];
            });
            if (validationFailure || cancelled) break;
        }
        cl_log(@"clean: freed %llu bytes, allOk=%d cancelled=%d failedItems=%lu",
               freed, allOk, cancelled, (unsigned long)failedItems);
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_cleaning = NO;
            self->_cleanCancellation = nil;
            if (cancelled) {
                self->_status = nil;
                [self scan];
                self->_result = [NSString stringWithFormat:@"已停止。已释放 %@。%@", cl_size_text(freed),
                                 allOk ? @"" : @" 部分项目未能删除（详见日志）。"];
                return;
            }
            if (validationFailure) {
                self->_scanLimited = YES;
                self->_status = nil;
                [self scan];
                self->_result = [NSString stringWithFormat:@"清理已停止：%@。已重新扫描。", validationFailure];
            } else {
                self->_status = nil;
                [self scan];
                // The post-clean scan springs the green check + haptic.
                self->_lastCleanSucceeded = YES;
                self->_result = [NSString stringWithFormat:@"已释放 %@。%@", cl_size_text(freed),
                                 failedItems ? [NSString stringWithFormat:@"%lu 个项目未能完全删除（详见日志）。",
                                              (unsigned long)failedItems] : @""];
            }
        });
    });
}

@end
