
//
//  CLAppDirectoryViewController.m
//  Cleaner v2.2 — read-only drill-down into one app's container.
//  v2.3: folders get a swipe-to-clean action (purge contents only, with a
//  confirm dialog; the container itself, Documents and Library stay behind
//  the backup-first "清空数据" flow at the root level), and Caches
//  subdirectories show their measured size from the scan breakdown.
//
//  Safety: navigation only ever goes one listed entry deeper, and every
//  directory is checked before it is listed — canonical path must stay
//  inside the app container, no symlink ancestry, symlinks are shown but
//  never followed. Cleaning a folder goes through cl_purge_folder_contents
//  (Core, same fd-relative no-follow removal as the cache purge).
//

#import "CLAppDirectoryViewController.h"
#import "CLApp.h"
#import "CLAppActions.h"
#import "CLCache.h"
#import "CLGrant.h"
#import "CLSafety.h"
#import "CLUI.h"

// One listed entry: name, kind, size (files) or item count (folders).
@interface CLDirEntry : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *path;
@property (nonatomic) BOOL isDirectory;
@property (nonatomic) BOOL isLink;
@property (nonatomic) unsigned long long size;
@property (nonatomic, strong, nullable) NSNumber *childCount;
@end

@implementation CLDirEntry
@end

static BOOL cl_path_inside_container(NSString *path, NSString *container)
{
    NSString *canonical = CLSafetyCanonicalPath(path);
    NSString *canonicalContainer = CLSafetyCanonicalPath(container);
    return [canonical isEqualToString:canonicalContainer] ||
           [canonical hasPrefix:[canonicalContainer stringByAppendingString:@"/"]];
}

@implementation CLAppDirectoryViewController {
    CLAppItem *_app;
    NSString *_path;
    NSArray<CLDirEntry *> *_entries;
    BOOL _loading;
    BOOL _busy;
    NSString *_status;
}

- (instancetype)initWithApp:(CLAppItem *)app
{
    return [self initWithApp:app path:app.container];
}

- (instancetype)initWithApp:(CLAppItem *)app path:(NSString *)path
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _app = app;
        _path = [path copy];
    }
    return self;
}

- (BOOL)isRoot
{
    return [_path isEqualToString:_app.container];
}

- (NSString *)relativePath
{
    if (self.isRoot) return @"容器根目录";
    NSString *container = [_app.container stringByStandardizingPath];
    NSString *path = [_path stringByStandardizingPath];
    if ([path hasPrefix:[container stringByAppendingString:@"/"]])
        return [path substringFromIndex:container.length + 1];
    return _path.lastPathComponent;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = self.isRoot ? _app.name : _path.lastPathComponent;
    [self rebuildNavButtons];
    [self reloadListing];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    // Backups may have been made since this view loaded (e.g. from the
    // Apps list behind it): the nav buttons must reflect the current list.
    if (!self.isRoot) return;
    [self rebuildNavButtons];
}

#pragma mark - Nav-bar actions (root level only)

- (void)rebuildNavButtons
{
    if (!self.isRoot) {
        self.navigationItem.rightBarButtonItems = nil;
        return;
    }
    if (_busy) {
        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc]
            initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [spinner startAnimating];
        self.navigationItem.rightBarButtonItems = @[[[UIBarButtonItem alloc] initWithCustomView:spinner]];
        return;
    }
    __weak typeof(self) weakSelf = self;
    void (^after)(void) = ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_busy = NO;
        [strongSelf rebuildNavButtons];
        [strongSelf reloadListing];
        if (strongSelf.onDataChanged) strongSelf.onDataChanged();
    };
    UIBarButtonItem *backup = [[UIBarButtonItem alloc] initWithTitle:@"备份" style:UIBarButtonItemStylePlain
                                                               target:self action:@selector(backupTapped)];
    // UIAction has no actionWithTitle:image:attributes:handler: — the
    // destructive attribute is set on the action after creation.
    UIAction *clear = [UIAction actionWithTitle:@"清空数据…" image:[UIImage systemImageNamed:@"trash"]
                                    identifier:nil handler:^(UIAction *__unused a) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_busy = YES;
        [strongSelf rebuildNavButtons];
        [CLAppActions confirmClearApp:strongSelf->_app from:strongSelf completion:after];
    }];
    clear.attributes = UIMenuElementAttributesDestructive;
    NSArray *backups = cl_app_backups(_app.bundleID);
    UIMenu *more = nil;
    if (backups.count) {
        NSString *title = backups.count == 1
            ? [NSString stringWithFormat:@"恢复备份（%@）", cl_backup_label(backups.firstObject)]
            : [NSString stringWithFormat:@"恢复备份…（%lu）", (unsigned long)backups.count];
        UIAction *restore = [UIAction actionWithTitle:title image:[UIImage systemImageNamed:@"arrow.uturn.backward"]
                                  identifier:nil handler:^(UIAction *__unused a) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf->_busy = YES;
            [strongSelf rebuildNavButtons];
            [CLAppActions restoreApp:strongSelf->_app from:strongSelf sourceView:nil completion:after];
        }];
        more = [UIMenu menuWithChildren:@[restore, clear]];
    } else {
        more = [UIMenu menuWithChildren:@[clear]];
    }
    UIBarButtonItem *moreButton = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"]
                                                                     menu:more];
    self.navigationItem.rightBarButtonItems = @[backup, moreButton];
}

- (void)backupTapped
{
    _busy = YES;
    [self rebuildNavButtons];
    __weak typeof(self) weakSelf = self;
    [CLAppActions backupApp:_app from:self completion:^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_busy = NO;
        [strongSelf rebuildNavButtons];
        [strongSelf reloadListing];
        if (strongSelf.onDataChanged) strongSelf.onDataChanged();
    }];
}

#pragma mark - Listing

- (void)reloadListing
{
    _loading = YES;
    _status = @"正在读取目录…";
    [self.tableView reloadData];
    NSString *path = _path;
    NSString *container = _app.container;
    // Caches subdirectory sizes from the last scan (v2.3): the scanner
    // measures the top-5 Caches subdirectories, so this listing can show a
    // folder's size without a second walk. Captured on the main thread —
    // the store's items are replaced on the main thread too.
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
        NSMutableArray<CLDirEntry *> *entries = [NSMutableArray new];
        NSString *error = nil;
        // Containment first: a directory outside the container (or reached
        // through a link) is never listed, even if the token would allow it.
        if (!cl_path_inside_container(path, container) || !CLSafetyHasNoSymlinkAncestry(path, NO)) {
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
                CLDirEntry *entry = [CLDirEntry new];
                entry.name = name;
                entry.path = full;
                entry.isLink = S_ISLNK(st.st_mode);
                entry.isDirectory = S_ISDIR(st.st_mode) && !entry.isLink;
                entry.size = S_ISREG(st.st_mode) ? (unsigned long long)st.st_size : 0;
                if (entry.isDirectory) {
                    NSArray *children = cl_list(full, NULL);
                    entry.childCount = children ? @(children.count) : nil;
                    // The scan's Caches breakdown, when this is the folder.
                    NSNumber *measured = subdirSizes[name];
                    if (measured) entry.size = measured.unsignedLongLongValue;
                }
                [entries addObject:entry];
            }
            [entries sortUsingComparator:^NSComparisonResult(CLDirEntry *a, CLDirEntry *b) {
                if (a.isDirectory != b.isDirectory) return a.isDirectory ? NSOrderedAscending : NSOrderedDescending;
                return [a.name localizedStandardCompare:b.name];
            }];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![path isEqualToString:self->_path]) return;  // a newer load owns the view now
            self->_loading = NO;
            self->_entries = entries;
            self->_status = error;
            [self.tableView reloadData];
        });
    });
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (_loading || _status) ? 1 : (NSInteger)_entries.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return [self relativePath];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (_loading || _status || !_entries.count) return nil;
    return @"点文件夹进入，点文件查看详情；左滑文件夹可清空其内容。备份、恢复、清空数据在根目录的导航栏里。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"dir"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"dir"];
    UIListContentConfiguration *c = cell.defaultContentConfiguration;
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
    CLDirEntry *entry = _entries[(NSUInteger)indexPath.row];
    c.text = entry.name;
    if (entry.isDirectory) {
        c.image = [UIImage systemImageNamed:@"folder.fill"];
        c.imageProperties.tintColor = UIColor.systemBlueColor;
        // A Caches subdirectory shows its scanned size (v2.3); other
        // folders show the item count.
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

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_loading || _status || !_entries.count) return;
    CLDirEntry *entry = _entries[(NSUInteger)indexPath.row];
    if (entry.isDirectory) {
        CLAppDirectoryViewController *next = [[CLAppDirectoryViewController alloc] initWithApp:_app path:entry.path];
        next.onDataChanged = self.onDataChanged;
        [self.navigationController pushViewController:next animated:YES];
        return;
    }
    // Files and links: read-only info, never opened or followed.
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
}

#pragma mark - Per-folder cleaning (v2.3)

// Swipe a folder to empty it. Files and links get no action (files stay
// read-only; links are never followed). The folder itself stays — only its
// contents are removed, through cl_purge_folder_contents (containment +
// no-symlink-ancestry validated in Core). Documents / Library subfolders
// get an extra user-data warning; wiping an app's data entirely stays the
// backup-first "清空数据" flow at the root level.
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (_loading || _status || !_entries.count || _busy) return nil;
    CLDirEntry *entry = _entries[(NSUInteger)indexPath.row];
    if (!entry.isDirectory) return nil;
    __weak typeof(self) weakSelf = self;
    UIContextualAction *clean = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
        title:@"清空" handler:^(UIContextualAction *__unused action, UIView *__unused view,
                               void (^completionHandler)(BOOL)) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) { completionHandler(NO); return; }
        [strongSelf confirmCleanFolder:entry];
        completionHandler(YES);
    }];
    clean.image = [UIImage systemImageNamed:@"trash"];
    return [UISwipeActionsConfiguration configurationWithActions:@[clean]];
}

- (void)confirmCleanFolder:(CLDirEntry *)entry
{
    NSString *rel = [self relativePathForEntry:entry];
    BOOL userData = [rel isEqualToString:@"Documents"] || [rel isEqualToString:@"Library"] ||
                    [rel hasPrefix:@"Documents/"] || [rel hasPrefix:@"Library/"];
    NSString *message = userData
        ? [NSString stringWithFormat:@"删除「%@」里的全部内容。注意：这不是缓存目录，可能包含用户数据（聊天记录、下载、设置等），无法恢复。建议先在根目录备份。", entry.name]
        : [NSString stringWithFormat:@"删除「%@」里的全部内容（文件夹本身保留）。无法撤销。", entry.name];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"清空文件夹？" message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"清空" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_busy = YES;
        [strongSelf rebuildNavButtons];
        NSString *path = entry.path;
        NSString *container = strongSelf->_app.container;
        dispatch_async(cl_io(), ^{
            unsigned long long freed = 0;
            NSString *reason = nil;
            BOOL ok = cl_purge_folder_contents(path, container, &freed, &reason);
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) innerSelf = weakSelf;
                if (!innerSelf) return;
                innerSelf->_busy = NO;
                [innerSelf rebuildNavButtons];
                [innerSelf reloadListing];
                if (innerSelf.onDataChanged) innerSelf.onDataChanged();
                cl_alert(innerSelf, ok ? @"已清空" : @"清空失败",
                         ok ? [NSString stringWithFormat:@"已释放 %@。", cl_size_text(freed)]
                            : (reason ?: @"无法清空该文件夹。"));
            });
        });
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

// Container-relative path of an entry (for the user-data warning).
- (NSString *)relativePathForEntry:(CLDirEntry *)entry
{
    NSString *container = [_app.container stringByStandardizingPath];
    NSString *path = [entry.path stringByStandardizingPath];
    if ([path hasPrefix:[container stringByAppendingString:@"/"]])
        return [path substringFromIndex:container.length + 1];
    return entry.name;
}

@end
