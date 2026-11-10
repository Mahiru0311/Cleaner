
//
//  CLAppDirectoryViewController.m
//  Cleaner v2.2 — read-only drill-down into one app's container.
//
//  Safety: navigation only ever goes one listed entry deeper, and every
//  directory is checked before it is listed — canonical path must stay
//  inside the app container, no symlink ancestry, symlinks are shown but
//  never followed. Nothing here writes: backup / restore / clear go through
//  CLAppActions (Core, with their own validation) from the root level only.
//

#import "CLAppDirectoryViewController.h"
#import "CLApp.h"
#import "CLAppActions.h"
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
    return @"只读浏览：点文件夹进入，点文件查看详情。备份、恢复、清空在根目录的导航栏里。";
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
        c.secondaryText = entry.childCount ? [NSString stringWithFormat:@"%@ 项", entry.childCount] : @"文件夹";
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

@end
