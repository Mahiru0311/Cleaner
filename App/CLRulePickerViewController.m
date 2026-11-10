
//
//  CLRulePickerViewController.m
//  Cleaner v2.5 — directory picker for custom rules.
//
//  Flow: no app yet → app list (searchable, sorted by name). App chosen
//  → that app's container, folders first, files shown for context (tap a
//  file for read-only details, never opened). Tap a folder to drill deeper
//  (a new instance of this page). The scope section applies to the
//  directory on screen: 清空整个目录, or 按条件删 (extension list, file
//  name, age, size). 选择 (top right) validates and saves the rule.
//  A path can also be typed/pasted: an absolute path is resolved to its
//  app + relative path (the directory view's 复制路径 copies absolute
//  paths); a relative path resolves under the current app.
//
//  Safety: the listing never leaves the container (canonical path must
//  stay inside it, no symlink ancestry — same checks as the directory
//  view); 选择 refuses the container root, Documents and Library
//  themselves; a directory outside Library/Caches + tmp is allowed but
//  warns (user data) and needs an explicit second confirm. The engine
//  re-validates everything before deleting (Core).
//  v2.7 — the app list comes from the FILESYSTEM (cl_all_app_containers),
//  not from the scan store: adding a rule used to cover only what the
//  scanner found, so an app that was never scanned could not get a rule
//  at all. The list is enumerated on a background queue (the same cached
//  inode scan the Apps page uses) and cached for this page's lifetime;
//  the manual path resolves against the same full list.
//  No emoji; SF Symbols only.
//

#import "CLRulePickerViewController.h"
#import "CLCache.h"
#import "CLCustomClean.h"
#import "CLGrant.h"
#import "CLLaunchServices.h"
#import "CLSafety.h"
#import "CLUI.h"

// One listed entry: name, kind, size (files) or item count (folders).
@interface CLRuleDirEntry : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *path;
@property (nonatomic) BOOL isDirectory;
@property (nonatomic) BOOL isLink;
@property (nonatomic) unsigned long long size;
@property (nonatomic, strong, nullable) NSNumber *childCount;
@end

@implementation CLRuleDirEntry
@end

typedef NS_ENUM(NSInteger, CLRulePickerSection) {
    CLRulePickerSectionApp = 0,
    CLRulePickerSectionScope,
    CLRulePickerSectionEntries,
    CLRulePickerSectionManual,
    CLRulePickerSectionCount,
};

static BOOL cl_picker_path_inside_container(NSString *path, NSString *container)
{
    NSString *canonical = CLSafetyCanonicalPath(path);
    NSString *canonicalContainer = CLSafetyCanonicalPath(container);
    return [canonical isEqualToString:canonicalContainer] ||
           [canonical hasPrefix:[canonicalContainer stringByAppendingString:@"/"]];
}

@implementation CLRulePickerViewController {
    NSDictionary *_editingRule;      // nil = new rule
    CLCacheItem *_app;               // nil = app list mode
    NSString *_path;                 // absolute path of the directory shown
    NSArray<CLRuleDirEntry *> *_entries;
    BOOL _loading;
    NSString *_status;
    BOOL _scopeFiltered;             // NO = clear the whole directory
    UITextField *_extField;
    UITextField *_nameField;
    UITextField *_ageField;
    UITextField *_minField;
    UITextField *_maxField;
    UITextField *_manualField;
    UISearchBar *_searchBar;
    NSString *_appFilter;
    NSString *_pendingRelativePath;  // edit prefill: jump here once the app is chosen
    // v2.7: the app list is ALL containers from the filesystem, not just
    // the scanned ones (cl_all_app_containers). Enumerated once per page
    // on a background queue and cached for this page's lifetime.
    NSArray<CLCacheItem *> *_allApps;
    BOOL _appsLoaded;               // the full list was enumerated (even if empty/failed)
    BOOL _appsLoading;              // enumeration in flight
    NSString *_appsStatus;          // loading/empty status for the app list
    BOOL _pendingManualPathRetry;   // a pasted path is waiting for the full list
    NSString *_pendingEditBundleID; // edit prefill: the rule's app, not in the scan store
    // Filter prefill, computed once from the rule being edited. The text
    // fields must NOT be re-set on every cell display (that would wipe
    // what the user typed whenever the table reloads).
    NSString *_prefillExt;
    NSString *_prefillName;
    NSString *_prefillAge;
    NSString *_prefillMin;
    NSString *_prefillMax;
}

- (instancetype)init
{
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (instancetype)initWithApp:(CLCacheItem *)app path:(NSString *)path
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _app = app;
        _path = path;
    }
    return self;
}

- (instancetype)initWithRule:(NSDictionary *)rule
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _editingRule = [rule copy];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"选择目录";
    if (_editingRule) {
        // Prefill the scope + filters from the rule being edited.
        _scopeFiltered = [_editingRule[CLCustomRuleScopeKey] isEqualToString:CLCustomRuleScopeFiltered] ||
            [_editingRule[CLCustomRuleKindKey] isEqualToString:@"extension"] ||
            [_editingRule[CLCustomRuleKindKey] isEqualToString:@"name"];
        // Filter prefill, computed once here (never re-applied on display).
        _prefillExt = _editingRule[CLCustomRuleExtensionsKey] ?: @"";
        _prefillName = _editingRule[CLCustomRuleNameKey] ?: @"";
        NSNumber *age = _editingRule[CLCustomRuleMinAgeDaysKey];
        _prefillAge = age ? [NSString stringWithFormat:@"%@", age] : @"";
        NSNumber *min = _editingRule[CLCustomRuleMinSizeKey];
        _prefillMin = min ? [NSString stringWithFormat:@"%.0f", min.doubleValue / 1024.0] : @"";
        NSNumber *max = _editingRule[CLCustomRuleMaxSizeKey];
        _prefillMax = max ? [NSString stringWithFormat:@"%.0f", max.doubleValue / 1024.0] : @"";
        NSString *bid = _editingRule[CLCustomRuleBundleIDKey];
        for (CLCacheItem *it in [CLCacheStore shared].items) {
            if (!it.crashLogs && [it.bundleID isEqualToString:bid]) { _app = it; break; }
        }
        if (_app) {
            _pendingRelativePath = _editingRule[CLCustomRulePatternKey];
        } else if (bid.length) {
            // v2.7: the rule's app was never scanned — look it up in the
            // full container list once it is enumerated (loadAllApps).
            _pendingEditBundleID = bid;
        }
    }
    [self reloadForCurrentState];
}

#pragma mark - State

- (BOOL)isAppListMode { return _app == nil; }

- (NSString *)relativePath
{
    if (!_app || !_path.length) return @"";
    NSString *container = [_app.containerPath stringByStandardizingPath];
    NSString *path = [_path stringByStandardizingPath];
    if ([path isEqualToString:container]) return @"";
    if ([path hasPrefix:[container stringByAppendingString:@"/"]])
        return [path substringFromIndex:container.length + 1];
    return _path.lastPathComponent;
}

- (NSArray<CLCacheItem *> *)allApps
{
    NSMutableArray<CLCacheItem *> *apps = [NSMutableArray new];
    for (CLCacheItem *it in _allApps) {
        if (_appFilter.length) {
            NSString *hay = [[NSString stringWithFormat:@"%@ %@", it.name, it.bundleID] lowercaseString];
            if (![hay containsString:_appFilter.lowercaseString]) continue;
        }
        [apps addObject:it];
    }
    return apps;
}

// v2.7: enumerates ALL app containers from the filesystem (not just the
// scanned ones) on a background queue, then caches the list for this
// page's lifetime. The inode enumeration itself is shared-cached for
// 10 minutes (cl_enumerate), so re-opening the picker is cheap.
- (void)loadAllApps
{
    if (_appsLoaded || _appsLoading) return;
    _appsLoading = YES;
    _appsStatus = @"正在查找应用…";
    if (self.isAppListMode) [self.tableView reloadData];
    __weak typeof(self) weakSelf = self;
    dispatch_async(cl_io(), ^{
        CLScanCancellation *cancel = [CLScanCancellation new];
        NSArray<CLCacheItem *> *apps = cl_all_app_containers(cancel, ^(int64_t done, int64_t total, NSUInteger __unused f) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf || !strongSelf->_appsLoading) return;
                strongSelf->_appsStatus = [NSString stringWithFormat:@"正在查找应用… %lld%%",
                                           total ? (long long)(done * 100 / total) : 0];
                if (strongSelf.isAppListMode) [strongSelf.tableView reloadData];
            });
        });
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf->_appsLoading = NO;
            strongSelf->_appsLoaded = YES;
            strongSelf->_allApps = apps ?: @[];
            strongSelf->_appsStatus = apps ? nil : @"没有找到应用容器。";
            // Edit prefill: the rule's app was not in the scan store —
            // look it up in the full container list now.
            if (strongSelf->_pendingEditBundleID.length) {
                NSString *bid = strongSelf->_pendingEditBundleID;
                strongSelf->_pendingEditBundleID = nil;
                for (CLCacheItem *it in strongSelf->_allApps) {
                    if ([it.bundleID isEqualToString:bid]) {
                        strongSelf->_app = it;
                        strongSelf->_pendingRelativePath = strongSelf->_editingRule[CLCustomRulePatternKey];
                        break;
                    }
                }
                if (!strongSelf->_app)
                    cl_alert(strongSelf, @"找不到这个应用",
                             @"这个规则的应用不在手机上了（可能已卸载），请重新选一个应用。");
            }
            BOOL retriedManualPath = NO;
            if (strongSelf->_pendingManualPathRetry) {
                strongSelf->_pendingManualPathRetry = NO;
                [strongSelf goToManualPath];
                retriedManualPath = YES;
            }
            if (!retriedManualPath) [strongSelf reloadForCurrentState];
        });
    });
}

- (void)reloadForCurrentState
{
    if (self.isAppListMode) {
        self.navigationItem.rightBarButtonItem = nil;
        [self loadAllApps];
        if (!_searchBar) {
            UISearchBar *bar = [[UISearchBar alloc] init];
            bar.placeholder = @"搜索应用";
            bar.delegate = self;
            _searchBar = bar;
        }
        self.tableView.tableHeaderView = _searchBar;
        [self.tableView reloadData];
        return;
    }
    self.tableView.tableHeaderView = nil;
    UIBarButtonItem *confirm = [[UIBarButtonItem alloc] initWithTitle:@"选择" style:UIBarButtonItemStylePlain
                                                                target:self action:@selector(confirmTapped)];
    self.navigationItem.rightBarButtonItem = confirm;
    if (!_path.length) _path = _app.containerPath;
    // Edit prefill: jump to the rule's directory once the app is known.
    if (_pendingRelativePath.length) {
        NSString *target = [_app.containerPath stringByAppendingPathComponent:_pendingRelativePath];
        _path = target;
        _pendingRelativePath = nil;
    }
    [self reloadListing];
}

#pragma mark - Listing (same safety as the directory view)

- (void)reloadListing
{
    _loading = YES;
    _status = @"正在读取目录…";
    [self.tableView reloadData];
    NSString *path = _path;
    NSString *container = _app.containerPath;
    NSDictionary<NSString *, NSNumber *> *subdirSizes = nil;
    if ([path isEqualToString:[container stringByAppendingPathComponent:@"Library/Caches"]]) {
        for (CLCacheItem *it in [CLCacheStore shared].items) {
            if ([it.bundleID isEqualToString:_app.bundleID] && it.cacheSubdirs.count) {
                NSMutableDictionary *m = [NSMutableDictionary new];
                for (NSDictionary *d in it.cacheSubdirs) {
                    if (d[@"name"] && d[@"bytes"]) m[d[@"name"]] = d[@"bytes"];
                }
                subdirSizes = m;
                break;
            }
        }
    }
    dispatch_async(cl_io(), ^{
        NSMutableArray<CLRuleDirEntry *> *entries = [NSMutableArray new];
        NSString *error = nil;
        if (!cl_picker_path_inside_container(path, container) || !CLSafetyHasNoSymlinkAncestry(path, NO)) {
            error = @"该目录不在应用容器内，或路径不安全。";
        }
        NSArray<NSString *> *names = nil;
        if (!error) {
            names = cl_list(path, &error);
            if (!names && !error) error = @"无法读取该目录。";
        }
        if (names) {
            for (NSString *name in names) {
                NSString *full = [path stringByAppendingPathComponent:name];
                struct stat st = {0};
                if (!cl_stat(full, &st)) continue;
                CLRuleDirEntry *entry = [CLRuleDirEntry new];
                entry.name = name;
                entry.path = full;
                entry.isLink = S_ISLNK(st.st_mode);
                entry.isDirectory = S_ISDIR(st.st_mode) && !entry.isLink;
                entry.size = S_ISREG(st.st_mode) ? (unsigned long long)st.st_size : 0;
                if (entry.isDirectory) {
                    NSArray *children = cl_list(full, NULL);
                    entry.childCount = children ? @(children.count) : nil;
                    NSNumber *measured = subdirSizes[name];
                    if (measured) entry.size = measured.unsignedLongLongValue;
                }
                [entries addObject:entry];
            }
            [entries sortUsingComparator:^NSComparisonResult(CLRuleDirEntry *a, CLRuleDirEntry *b) {
                if (a.isDirectory != b.isDirectory) return a.isDirectory ? NSOrderedAscending : NSOrderedDescending;
                return [a.name localizedStandardCompare:b.name];
            }];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![path isEqualToString:self->_path]) return;
            self->_loading = NO;
            self->_entries = entries;
            self->_status = error;
            // v2.6: the listing fades in (system cross-dissolve) instead
            // of popping in when a directory loads.
            [UIView transitionWithView:self.tableView duration:0.25
                               options:UIViewAnimationOptionTransitionCrossDissolve
                            animations:^{ [self.tableView reloadData]; }
                            completion:nil];
        });
    });
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return self.isAppListMode ? 1 : CLRulePickerSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (self.isAppListMode) {
        NSArray *apps = [self allApps];
        return apps.count ?: 1;
    }
    switch (section) {
        case CLRulePickerSectionApp: return 2;  // v2.6: app row + current-directory row
        case CLRulePickerSectionScope: return _scopeFiltered ? 7 : 2;
        // v2.6: an empty directory shows one empty-state row instead of
        // a blank section, so it is clear the directory is empty (and not
        // still loading or broken).
        case CLRulePickerSectionEntries: return (_loading || _status) ? 1 : MAX((NSInteger)_entries.count, 1);
        default: return 2;  // manual path field + go row
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (self.isAppListMode) return @"选择应用";
    switch (section) {
        case CLRulePickerSectionApp: return @"应用";
        case CLRulePickerSectionScope: {
            NSString *rel = [self relativePath];
            return rel.length ? [NSString stringWithFormat:@"当前目录：%@", rel] : @"当前目录：容器根目录";
        }
        case CLRulePickerSectionEntries: return @"目录内容";
        default: return @"手动输入路径";
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (self.isAppListMode) {
        if (!_appsLoaded) return _appsStatus ?: @"正在查找应用…";
        if (!_allApps.count) return _appsStatus ?: @"没有找到应用容器。";
        return @"先选一个应用，再进它的容器里选目录。";
    }
    if (section == CLRulePickerSectionScope) {
        NSString *rel = [self relativePath];
        BOOL userData = rel.length && ![rel hasPrefix:@"Library/Caches"] && ![rel isEqualToString:@"tmp"] &&
                        ![rel hasPrefix:@"tmp/"];
        if (_scopeFiltered)
            return @"只删这个目录里符合条件的文件（扩展名、文件名、年龄、大小，至少填一个）。点右上角「选择」确认的是当前这个目录。";
        if (userData)
            return @"注意：这个目录不是缓存目录，可能包含用户数据（聊天记录、下载、设置等）。「选择」时会再问一次确认。";
        return @"删除这个目录里的全部内容（目录本身保留）。点右上角「选择」确认的是当前这个目录。";
    }
    if (section == CLRulePickerSectionEntries)
        return @"点文件夹进入下一级；点文件只看详情。右上角「选择」确认的是当前这个目录。";
    return @"也可以直接粘贴一条目录路径（相对路径如 Library/Caches/xxx，或从目录页复制的完整路径），点「前往」跳过去。";
}

// v2.6: filter fields are labelled (label on the left, field on the
// right) instead of bare placeholders — a half-filled form must still
// say what each row is.
- (UITableViewCell *)cellWithTextField:(NSString *)reuseID label:(nullable NSString *)label
                           placeholder:(NSString *)placeholder
                              keyboard:(UIKeyboardType)keyboard field:(UITextField **)out prefill:(NSString *)prefill
{
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:reuseID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseID];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        CGFloat x = 16;
        if (label.length) {
            UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(16, 0, 76, 44)];
            lb.text = label;
            lb.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
            lb.autoresizingMask = UIViewAutoresizingFlexibleHeight;
            [cell.contentView addSubview:lb];
            x = 100;
        }
        UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(x, 0, cell.contentView.bounds.size.width - x - 16, 44)];
        tf.placeholder = placeholder;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        tf.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        tf.text = prefill;  // set once, at creation — never again on display
        [cell.contentView addSubview:tf];
        *out = tf;
    }
    UITextField *tf = *out;
    tf.keyboardType = keyboard;
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (self.isAppListMode) {
        NSArray<CLCacheItem *> *apps = [self allApps];
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"app"]
            ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"app"];
        UIListContentConfiguration *c = cell.defaultContentConfiguration;
        if (!apps.count) {
            c.text = _appsLoading ? @"正在查找应用…" : @"没有找到应用";
            c.secondaryText = _appsStatus ?: (_appsLoading ? @"正在枚举全部应用容器…"
                                                           : @"没有找到任何应用容器。");
            c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
            cell.contentConfiguration = c;
            cell.accessoryType = UITableViewCellAccessoryNone;
            return cell;
        }
        CLCacheItem *app = apps[(NSUInteger)indexPath.row];
        c.text = app.name;
        c.secondaryText = app.bundleID;
        c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
        cell.contentConfiguration = c;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }
    UITableViewCell *cell = nil;
    UIListContentConfiguration *c = nil;
    switch (indexPath.section) {
        case CLRulePickerSectionApp: {
            if (indexPath.row == 0) {
                cell = [tableView dequeueReusableCellWithIdentifier:@"pickapp"]
                    ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"pickapp"];
                c = cell.defaultContentConfiguration;
                c.text = _app.name;
                c.secondaryText = _app.bundleID;
                c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
                cell.contentConfiguration = c;
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                return cell;
            }
            // v2.6: the picked directory, unmistakable — the row shows
            // the directory itself (not just the app), with a checkmark:
            // this is the directory the top-right 选择 will confirm.
            cell = [tableView dequeueReusableCellWithIdentifier:@"pickdir"]
                ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"pickdir"];
            c = cell.defaultContentConfiguration;
            NSString *rel = [self relativePath];
            c.text = rel.length ? rel : @"容器根目录";
            c.secondaryText = @"当前目录 · 点右上角「选择」确认的就是它";
            c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
            c.image = [UIImage systemImageNamed:@"folder.fill"];
            c.imageProperties.tintColor = UIColor.systemBlueColor;
            cell.contentConfiguration = c;
            cell.accessoryType = UITableViewCellAccessoryCheckmark;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            return cell;
        }
        case CLRulePickerSectionScope: {
            if (indexPath.row == 0 || indexPath.row == 1) {
                cell = [tableView dequeueReusableCellWithIdentifier:@"scope"]
                    ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"scope"];
                c = cell.defaultContentConfiguration;
                BOOL filteredRow = indexPath.row == 1;
                c.text = filteredRow ? @"按条件删" : @"清空整个目录";
                cell.contentConfiguration = c;
                cell.accessoryType = (filteredRow == _scopeFiltered)
                    ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
                return cell;
            }
            // Filter rows (only when 按条件删): extension, name, age, min, max.
            switch (indexPath.row) {
                case 2: {
                    UITextField *field = nil;
                    UITableViewCell *fc = [self cellWithTextField:@"filter-ext" label:@"扩展名" placeholder:@"如 .mp4,.mov"
                                                         keyboard:UIKeyboardTypeDefault field:&field prefill:_prefillExt];
                    if (field) _extField = field;
                    return fc;
                }
                case 3: {
                    UITextField *field = nil;
                    UITableViewCell *fc = [self cellWithTextField:@"filter-name" label:@"文件名" placeholder:@"包含，如 thumb"
                                                         keyboard:UIKeyboardTypeDefault field:&field prefill:_prefillName];
                    if (field) _nameField = field;
                    return fc;
                }
                case 4: {
                    UITextField *field = nil;
                    UITableViewCell *fc = [self cellWithTextField:@"filter-age" label:@"保留天数" placeholder:@"仅删 N 天前的文件"
                                                         keyboard:UIKeyboardTypeDecimalPad field:&field prefill:_prefillAge];
                    if (field) _ageField = field;
                    return fc;
                }
                case 5: {
                    UITextField *field = nil;
                    UITableViewCell *fc = [self cellWithTextField:@"filter-min" label:@"最小大小" placeholder:@"仅删大于 N KB 的文件"
                                                         keyboard:UIKeyboardTypeDecimalPad field:&field prefill:_prefillMin];
                    if (field) _minField = field;
                    return fc;
                }
                default: {
                    UITextField *field = nil;
                    UITableViewCell *fc = [self cellWithTextField:@"filter-max" label:@"最大大小" placeholder:@"仅删小于 N KB 的文件"
                                                         keyboard:UIKeyboardTypeDecimalPad field:&field prefill:_prefillMax];
                    if (field) _maxField = field;
                    return fc;
                }
            }
        }
        case CLRulePickerSectionEntries: {
            cell = [tableView dequeueReusableCellWithIdentifier:@"entry"]
                ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"entry"];
            c = cell.defaultContentConfiguration;
            if (_loading) {
                c.text = @"正在读取目录…";
                cell.contentConfiguration = c;
                cell.accessoryType = UITableViewCellAccessoryNone;
                return cell;
            }
            if (_status) {
                c.text = _status;
                c.secondaryText = @"返回上一级，或回到应用列表重新进入。";
                c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
                cell.contentConfiguration = c;
                cell.accessoryType = UITableViewCellAccessoryNone;
                return cell;
            }
            if (!_entries.count) {
                // v2.6: empty-state row — the directory is genuinely empty.
                c.text = @"这个目录是空的";
                c.secondaryText = @"没有文件也没有子目录。";
                c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
                cell.contentConfiguration = c;
                cell.accessoryType = UITableViewCellAccessoryNone;
                return cell;
            }
            CLRuleDirEntry *entry = _entries[(NSUInteger)indexPath.row];
            c.text = entry.name;
            if (entry.isDirectory) {
                c.image = [UIImage systemImageNamed:@"folder.fill"];
                c.imageProperties.tintColor = UIColor.systemBlueColor;
                if (entry.size > 0 && entry.childCount) {
                    c.secondaryText = [NSString stringWithFormat:@"%@ · %@ 项", cl_size_text(entry.size), entry.childCount];
                } else if (entry.size > 0) {
                    c.secondaryText = cl_size_text(entry.size);
                } else {
                    c.secondaryText = entry.childCount ? [NSString stringWithFormat:@"%@ 项", entry.childCount] : @"文件夹";
                }
            } else if (entry.isLink) {
                c.image = [UIImage systemImageNamed:@"link"];
                c.imageProperties.tintColor = UIColor.secondaryLabelColor;
                c.secondaryText = @"链接（不跟随）";
            } else {
                c.image = [UIImage systemImageNamed:@"doc.fill"];
                c.imageProperties.tintColor = UIColor.secondaryLabelColor;
                c.secondaryText = cl_size_text(entry.size);
            }
            c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
            cell.contentConfiguration = c;
            cell.accessoryType = entry.isDirectory ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
            return cell;
        }
        default: {
            if (indexPath.row == 0) {
                UITextField *field = nil;
                UITableViewCell *fc = [self cellWithTextField:@"manual-path" label:@"路径"
                                                  placeholder:@"Library/Caches/xxx 或完整路径"
                                                     keyboard:UIKeyboardTypeDefault field:&field prefill:@""];
                if (field) _manualField = field;
                return fc;
            }
            cell = [tableView dequeueReusableCellWithIdentifier:@"go"]
                ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"go"];
            c = cell.defaultContentConfiguration;
            c.text = @"前往";
            c.textProperties.color = UIColor.systemBlueColor;
            cell.contentConfiguration = c;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return cell;
        }
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.isAppListMode) {
        NSArray<CLCacheItem *> *apps = [self allApps];
        if (!apps.count || (NSUInteger)indexPath.row >= apps.count) return;
        _app = apps[(NSUInteger)indexPath.row];
        _path = nil;
        [self reloadForCurrentState];
        return;
    }
    switch (indexPath.section) {
        case CLRulePickerSectionApp:
            // v2.6: row 0 changes the app; row 1 is the picked directory
            // (unmistakable, with a checkmark) and is not tappable.
            if (indexPath.row != 0) return;
            _app = nil;
            _path = nil;
            [self reloadForCurrentState];
            return;
        case CLRulePickerSectionScope: {
            if (indexPath.row > 1) return;
            _scopeFiltered = indexPath.row == 1;
            [tableView reloadSections:[NSIndexSet indexSetWithIndex:CLRulePickerSectionScope]
                     withRowAnimation:UITableViewRowAnimationAutomatic];
            return;
        }
        case CLRulePickerSectionEntries: {
            if (_loading || _status || !_entries.count) return;
            CLRuleDirEntry *entry = _entries[(NSUInteger)indexPath.row];
            if (entry.isDirectory) {
                CLRulePickerViewController *next = [[CLRulePickerViewController alloc] initWithApp:_app path:entry.path];
                next.onSaved = self.onSaved;
                [self.navigationController pushViewController:next animated:YES];
                return;
            }
            NSString *detail = entry.isLink ? @"符号链接，不跟随打开。"
                : [NSString stringWithFormat:@"大小：%@", cl_size_text(entry.size)];
            UIAlertController *sheet = [UIAlertController alertControllerWithTitle:entry.name
                message:[NSString stringWithFormat:@"%@\n\n%@", detail, entry.path]
                preferredStyle:UIAlertControllerStyleActionSheet];
            [sheet addAction:[UIAlertAction actionWithTitle:@"复制路径" style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused a) {
                UIPasteboard.generalPasteboard.string = entry.path;
            }]];
            [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
            UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
            sheet.popoverPresentationController.sourceView = cell ?: self.view;
            sheet.popoverPresentationController.sourceRect = (cell ?: self.view).bounds;
            [self presentViewController:sheet animated:YES completion:nil];
            return;
        }
        default: {
            if (indexPath.row == 1) [self goToManualPath];
            return;
        }
    }
}

#pragma mark - Manual path

- (void)goToManualPath
{
    NSString *text = [_manualField.text stringByTrimmingCharactersInSet:
                      NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!text.length) {
        cl_alert(self, @"路径为空", @"先输入或粘贴一条目录路径。");
        return;
    }
    NSString *bid = nil, *rel = nil, *reason = nil;
    // v2.7: the pasted path resolves against ALL containers, not just
    // the scanned ones — load the full list first, then retry.
    if (!_appsLoaded) {
        _pendingManualPathRetry = YES;
        [self loadAllApps];
        return;
    }
    if (!cl_custom_clean_resolve_pasted_path(text, _allApps, _app.bundleID, &bid, &rel, &reason)) {
        cl_alert(self, @"路径不对", reason ?: @"无法解析这条路径。");
        return;
    }
    CLCacheItem *target = nil;
    for (CLCacheItem *it in _allApps) {
        if ([it.bundleID isEqualToString:bid]) { target = it; break; }
    }
    if (!target) {
        cl_alert(self, @"找不到应用", @"这条路径的应用没有容器。");
        return;
    }
    _app = target;
    _path = [target.containerPath stringByAppendingPathComponent:rel];
    _manualField.text = nil;
    [self reloadForCurrentState];
}

#pragma mark - Confirm (top-right 选择)

- (void)confirmTapped
{
    NSString *rel = [self relativePath];
    if (!rel.length) {
        cl_alert(self, @"请选择一个子目录", @"不能直接选容器根目录，请点进一个文件夹再确认。");
        return;
    }
    NSString *reason = nil;
    if (!cl_custom_clean_validate_folder_pattern(rel, &reason)) {
        cl_alert(self, @"不能添加", reason);
        return;
    }
    NSString *exts = [_extField.text stringByTrimmingCharactersInSet:
                      NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *name = [_nameField.text stringByTrimmingCharactersInSet:
                      NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *ageText = [_ageField.text stringByTrimmingCharactersInSet:
                         NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *minText = [_minField.text stringByTrimmingCharactersInSet:
                         NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *maxText = [_maxField.text stringByTrimmingCharactersInSet:
                         NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSNumber *age = (_scopeFiltered && ageText.length) ? @(ageText.doubleValue) : nil;
    NSNumber *minSize = (_scopeFiltered && minText.length) ? @(minText.doubleValue * 1024) : nil;
    NSNumber *maxSize = (_scopeFiltered && maxText.length) ? @(maxText.doubleValue * 1024) : nil;
    NSDictionary *rule = cl_custom_clean_make_directory_rule(
        _app.bundleID, rel, _scopeFiltered ? CLCustomRuleScopeFiltered : CLCustomRuleScopeAll,
        (_scopeFiltered && exts.length) ? exts : nil,
        (_scopeFiltered && name.length) ? name : nil, age, minSize, maxSize);
    if (!cl_custom_clean_validate_rule(rule, &reason)) {
        cl_alert(self, @"不能添加", reason);
        return;
    }
    // Outside Caches/tmp this may be user data (BleachBit's protected-path
    // warning): allowed, but only with an explicit second confirm.
    BOOL userData = ![rel hasPrefix:@"Library/Caches"] && ![rel isEqualToString:@"tmp"] &&
                    ![rel hasPrefix:@"tmp/"];
    if (userData) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"这个目录不是缓存目录"
            message:[NSString stringWithFormat:@"「%@」可能包含用户数据（聊天记录、下载、设置等），清理后无法恢复。确定要把它加进自定义清理吗？", rel]
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        __weak typeof(self) weakSelf = self;
        [alert addAction:[UIAlertAction actionWithTitle:@"仍要添加" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
            [weakSelf saveRule:rule];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    [self saveRule:rule];
}

- (void)saveRule:(NSDictionary *)rule
{
    NSMutableArray *rules = [cl_custom_clean_rules() mutableCopy];
    if (_editingRule) {
        // Replace in place, keeping the rule's UUID and enabled state.
        NSMutableDictionary *saved = [rule mutableCopy];
        saved[CLCustomRuleIDKey] = _editingRule[CLCustomRuleIDKey];
        saved[CLCustomRuleEnabledKey] = _editingRule[CLCustomRuleEnabledKey];
        NSUInteger idx = [rules indexOfObjectPassingTest:^BOOL(NSDictionary *r, NSUInteger __unused i, BOOL * __unused stop) {
            return [r[CLCustomRuleIDKey] isEqualToString:_editingRule[CLCustomRuleIDKey]];
        }];
        if (idx != NSNotFound) rules[idx] = [saved copy];
        else [rules addObject:[saved copy]];
    } else {
        [rules addObject:rule];
    }
    cl_custom_clean_save_rules(rules);
    if (self.onSaved) self.onSaved();
    [self.navigationController popViewControllerAnimated:YES];
}

#pragma mark - UISearchBarDelegate (app list search)

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText
{
    _appFilter = [searchText stringByTrimmingCharactersInSet:
                  NSCharacterSet.whitespaceAndNewlineCharacterSet];
    [self.tableView reloadData];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar
{
    [searchBar resignFirstResponder];
}

@end
