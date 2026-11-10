//  CLCache.m
//  Cleaner v2 — measure/purge from WQAccess.m + cache model from WQCache.m
//  (v0.1, commit 201591c8), renamed.

#import "CLCache.h"
#import "CLGrant.h"
#import "CLScan.h"
#import "CLSafety.h"
#import "CLLaunchServices.h"
#import <dirent.h>
#import <errno.h>
#import <sys/stat.h>

CLMeasureResult cl_measure_tree(NSString *dir, CLScanCancellation *cancellation, unsigned long long *bytes)
{
    if (cancellation.isCancelled) return CLMeasureResultCancelled;
    struct stat st = {0};
    if (!cl_stat(dir, &st)) {
        struct stat direct = {0};
        if (lstat(dir.fileSystemRepresentation, &direct) != 0 &&
            (errno == ENOENT || errno == ENOTDIR)) return CLMeasureResultMissing;
        return CLMeasureResultLimited;
    }
    if (!S_ISDIR(st.st_mode)) return CLMeasureResultLimited;
    if (![NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil]) cl_grant(dir);

    NSURL *root = [NSURL fileURLWithPath:dir isDirectory:YES];
    NSArray<NSURLResourceKey> *keys = @[NSURLIsRegularFileKey, NSURLIsSymbolicLinkKey,
                                       NSURLFileSizeKey, NSURLIsDirectoryKey];
    __block BOOL limited = NO;
    NSDirectoryEnumerator<NSURL *> *enumerator = [NSFileManager.defaultManager
        enumeratorAtURL:root includingPropertiesForKeys:keys options:0
           errorHandler:^BOOL(NSURL *errorURL, NSError *error) {
        limited = YES;
        cl_log(@"measure: cannot enumerate %@ (%@)", errorURL.path, error.localizedDescription ?: @"unknown error");
        return YES;
    }];
    if (!enumerator) return CLMeasureResultLimited;

    unsigned long long total = 0;
    for (NSURL *item in enumerator) {
        if (cancellation.isCancelled) return CLMeasureResultCancelled;
        NSNumber *isLink = nil, *isRegular = nil, *size = nil;
        NSError *error = nil;
        if (![item getResourceValue:&isLink forKey:NSURLIsSymbolicLinkKey error:&error] ||
            ![item getResourceValue:&isRegular forKey:NSURLIsRegularFileKey error:&error]) {
            limited = YES;
            continue;
        }
        if (isLink.boolValue || !isRegular.boolValue) continue;
        if (![item getResourceValue:&size forKey:NSURLFileSizeKey error:&error]) {
            limited = YES;
            continue;
        }
        total += size.unsignedLongLongValue;
    }
    if (cancellation.isCancelled) return CLMeasureResultCancelled;
    if (bytes) *bytes = total;
    return limited ? CLMeasureResultLimited : CLMeasureResultKnown;
}

// Purge uses fd-relative removal, so the path is only a swap detector. One
// lstat is enough; reopening every ancestor for every child is needlessly
// expensive on large caches.
static BOOL cl_purge_root_matches(NSString *path, int fd)
{
    struct stat pathStat, fdStat;
    return lstat(path.fileSystemRepresentation, &pathStat) == 0 &&
           fstat(fd, &fdStat) == 0 && CLSameObject(&pathStat, &fdStat);
}

static BOOL cl_purge_fd(int fd, NSString *path, unsigned long long *freed, CLScanCancellation *cancellation)
{
    int listing = dup(fd);
    if (listing < 0) return NO;
    DIR *dir = fdopendir(listing);
    if (!dir) { close(listing); return NO; }
    BOOL ok = YES;
    for (;;) {
        if (cancellation.isCancelled) { ok = NO; break; }
        errno = 0;
        struct dirent *entry = readdir(dir);
        if (!entry) { if (errno) ok = NO; break; }
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        NSString *name = [NSFileManager.defaultManager stringWithFileSystemRepresentation:entry->d_name length:strlen(entry->d_name)];
        if (!name) { ok = NO; break; }
        CL_TREE_HOOK(@"purgeChild", path);
        // Fail closed on changed ancestry; all removal remains fd-relative even
        // in the final race window. Symlink children are unlinked, never followed.
        if (!cl_purge_root_matches(path, fd)) { ok = NO; break; }
        if (!cl_remove_entry(fd, name, [path stringByAppendingPathComponent:name], freed, cancellation)) ok = NO;
    }
    if (closedir(dir) != 0) ok = NO;
    return ok;
}

BOOL cl_remove_entry(int parent, NSString *name, NSString *path, unsigned long long *_Nullable freed,
                            CLScanCancellation *cancellation)
{
    if (cancellation.isCancelled) return NO;
    const char *item = name.fileSystemRepresentation;
    struct stat before, current;
    if (fstatat(parent, item, &before, AT_SYMLINK_NOFOLLOW) != 0) return errno == ENOENT;
    BOOL directory = S_ISDIR(before.st_mode);
    if (directory) {
        int child = openat(parent, item, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
        if (child < 0 && cl_is_denied(errno) && cl_grant(path))
            child = openat(parent, item, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
        if (child < 0) return NO;
        BOOL ok = fstat(child, &current) == 0 && CLSameObject(&before, &current) &&
            cl_purge_root_matches(path, child) && cl_purge_fd(child, path, freed, cancellation);
        close(child);
        if (!ok) return NO;
    }
    if (fstatat(parent, item, &current, AT_SYMLINK_NOFOLLOW) != 0 || !CLSameObject(&before, &current) ||
        (current.st_mode & S_IFMT) != (before.st_mode & S_IFMT)) return NO;
    int rc = unlinkat(parent, item, directory ? AT_REMOVEDIR : 0);
    if (rc != 0 && cl_is_denied(errno) && cl_grant(path.stringByDeletingLastPathComponent)) {
        if (fstatat(parent, item, &current, AT_SYMLINK_NOFOLLOW) != 0 || !CLSameObject(&before, &current)) return NO;
        rc = unlinkat(parent, item, directory ? AT_REMOVEDIR : 0);
    }
    if (rc == 0 && !directory && freed) *freed += (unsigned long long)before.st_size;
    if (rc != 0) cl_log(@"purge: %@ -> %@", path, cl_errno(errno));
    return rc == 0;
}

BOOL cl_purge_contents_cancellable(NSString *dir, unsigned long long *freed, CLScanCancellation *cancellation)
{
    if (cancellation.isCancelled) return NO;
    if (!CLAbsolutePathGrammar(CLCanonicalVarPath(dir))) return NO;
    int fd = cl_open_directory(dir);
    if (fd < 0) {
        if (errno == ENOENT) return YES;
        cl_log(@"purge: %@ -> unsafe ancestry or inaccessible (%@)", dir, cl_errno(errno));
        return NO;
    }
    BOOL ok = cl_purge_fd(fd, dir, freed, cancellation);
    close(fd);
    return ok;
}

BOOL cl_purge_contents(NSString *dir, unsigned long long *freed)
{
    return cl_purge_contents_cancellable(dir, freed, nil);
}

// Flush a completed staging tree without following any links or opening special
//
//  WQCache.m
//  Cleaner cache cleaner
//  GPL-3.0-or-later.
//







#pragma mark - Cache cleaner

NSString *const CLCrashLogsPath =
    @"/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.osanalytics/Library/Logs/CrashReporter";

@implementation CLCacheTargetRecord
@end

@implementation CLCacheItem
- (unsigned long long)bytes { return self.cacheBytes + self.tempBytes; }
@end

static CLCacheMeasurementState CLCacheMeasureDirectory(NSString *path,
                                                        CLScanCancellation *cancellation,
                                                        unsigned long long *bytes)
{
    unsigned long long total = 0;
    CLMeasureResult result = cl_measure_tree(path, cancellation, &total);
    switch (result) {
        case CLMeasureResultMissing:
            return CLCacheMeasurementMissing;
        case CLMeasureResultKnown:
            if (bytes) *bytes = total;
            return CLCacheMeasurementKnown;
        case CLMeasureResultCancelled:
            return CLCacheMeasurementCancelled;
        case CLMeasureResultLimited:
            cl_log(@"cache scan: limited tree measurement for %@", path);
            return CLCacheMeasurementLimited;
    }
    return CLCacheMeasurementLimited;
}

typedef NS_ENUM(NSInteger, CLCachePathState) {
    CLCachePathMissing,
    CLCachePathExisting,
    CLCachePathInaccessible,
};

static CLCachePathState CLCacheInspectPath(NSString *path, struct stat *st)
{
    if (cl_stat(path, st)) return CLCachePathExisting;
    struct stat direct = {0};
    if (lstat(path.fileSystemRepresentation, &direct) == 0) {
        if (st) *st = direct;
        return CLCachePathExisting;
    }
    if (errno == ENOENT || errno == ENOTDIR) return CLCachePathMissing;
    return CLCachePathInaccessible;
}

static CLCacheTargetRecord *CLCacheTargetRecordForPath(NSString *path, NSString *relativePath)
{
    CLCacheTargetRecord *record = [CLCacheTargetRecord new];
    record.path = path;
    record.relativePath = relativePath;
    struct stat st = {0};
    CLCachePathState state = CLCacheInspectPath(path, &st);
    if (state == CLCachePathExisting) {
        record.existed = YES;
        record.identityKnown = YES;
        record.device = st.st_dev;
        record.inode = st.st_ino;
        record.mode = st.st_mode & S_IFMT;
    }
    return record;
}

static void CLCacheCaptureContainerIdentity(CLCacheItem *item)
{
    struct stat st = {0};
    if (item.containerPath.length && cl_stat(item.containerPath, &st) && S_ISDIR(st.st_mode)) {
        item.containerIdentityKnown = YES;
        item.containerDevice = st.st_dev;
        item.containerInode = st.st_ino;
        item.containerMode = st.st_mode & S_IFMT;
    }
}

static BOOL CLCacheRecordIdentityMatches(CLCacheTargetRecord *record, NSString **reason)
{
    struct stat st = {0};
    CLCachePathState state = CLCacheInspectPath(record.path, &st);
    if (!record.existed) {
        if (state == CLCachePathMissing) return YES;
        if (reason) *reason = [NSString stringWithFormat:@"%@ 在扫描后出现", record.path];
        return NO;
    }
    if (state != CLCachePathExisting || !record.identityKnown ||
        st.st_dev != record.device || st.st_ino != record.inode ||
        (st.st_mode & S_IFMT) != record.mode) {
        if (reason) *reason = [NSString stringWithFormat:@"%@ 在扫描后发生了变化", record.path];
        return NO;
    }
    return YES;
}

static BOOL CLCacheCrashPathIsSafe(NSString *path)
{
    NSString *expected = [CLCrashLogsPath stringByStandardizingPath];
    return [[path stringByStandardizingPath] isEqualToString:expected] &&
           CLSafetyHasNoSymlinkAncestry(path, YES) &&
           [CLSafetyCanonicalPath(path) isEqualToString:expected];
}

BOOL CLCacheValidateItem(CLCacheItem *item, NSString **reason)
{
    if (item.limited) {
        if (reason) *reason = @"扫描时访问受限";
        return NO;
    }
    if (item.crashLogs) {
        if (item.targetRecords.count != 1 || !CLCacheCrashPathIsSafe(item.targets.firstObject)) {
            if (reason) *reason = @"崩溃日志目标不是预期的标准目录";
            return NO;
        }
        return CLCacheRecordIdentityMatches(item.targetRecords.firstObject, reason);
    }
    if (item.targetRecords.count != 2 || item.targets.count != 2 ||
        ![item.targets[0] isEqualToString:item.targetRecords[0].path] ||
        ![item.targets[1] isEqualToString:item.targetRecords[1].path]) {
        if (reason) *reason = @"扫描到的缓存目标不完整";
        return NO;
    }
    if (!item.containerIdentityKnown || !CLSafetyHasNoSymlinkAncestry(item.containerPath, NO)) {
        if (reason) *reason = @"应用容器身份或路径信息不可用";
        return NO;
    }
    struct stat container = {0};
    if (CLCacheInspectPath(item.containerPath, &container) != CLCachePathExisting ||
        !S_ISDIR(container.st_mode) || container.st_dev != item.containerDevice ||
        container.st_ino != item.containerInode || (container.st_mode & S_IFMT) != item.containerMode) {
        if (reason) *reason = [NSString stringWithFormat:@"%@ 在扫描后发生了变化", item.name];
        return NO;
    }
    NSString *label = cl_container_label(item.containerPath);
    if (!item.bundleID.length || ![label isEqualToString:item.bundleID]) {
        if (reason) *reason = [NSString stringWithFormat:@"%@ 不再是扫描时的容器身份", item.name];
        return NO;
    }
    for (CLCacheTargetRecord *record in item.targetRecords) {
        if (!CLSafetyTargetMatchesContainer(record.path, item.containerPath, record.relativePath)) {
            if (reason) *reason = [NSString stringWithFormat:@"%@ 的路径祖先不安全", record.path];
            return NO;
        }
        if (!CLCacheRecordIdentityMatches(record, reason)) return NO;
    }
    return YES;
}

// Row: selection circle, icon, name with "cache · temp" below, size in a
// fixed right-hand column so long names never push it out.

#pragma mark - Shared cache scanner + store
//
// The scan body is the v0.1 WQCacheCleanerViewController scan, moved here so
// Home can share one scan (app count + total reclaimable) with the Cleaner
// page. Progress/completion run off the main thread; the caller hops to main.

NSString *const CLCacheStoreDidUpdateNotification = @"CLCacheStoreDidUpdateNotification";

@interface CLCacheStore ()
@property (nonatomic, copy) NSArray<CLCacheItem *> *items;
@property (nonatomic) unsigned long long totalBytes;
@property (nonatomic) NSUInteger appCount;
@property (nonatomic) BOOL limited;
@property (nonatomic) NSTimeInterval lastScanFinished;
@end

@implementation CLCacheStore

+ (instancetype)shared
{
    static CLCacheStore *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [CLCacheStore new]; });
    return shared;
}

- (void)updateWithItems:(NSArray<CLCacheItem *> *)items limited:(BOOL)limited
{
    _items = [items copy];
    unsigned long long total = 0;
    NSUInteger apps = 0;
    for (CLCacheItem *it in items) {
        total += it.bytes;
        if (!it.crashLogs) apps++;
    }
    _totalBytes = total;
    _appCount = apps;
    _limited = limited;
    _scanning = NO;
    _lastScanFinished = NSDate.date.timeIntervalSinceReferenceDate;
    [[NSNotificationCenter defaultCenter] postNotificationName:CLCacheStoreDidUpdateNotification object:self];
}

- (void)invalidateScan
{
    cl_enumerate_invalidate();
    cl_display_names_reset_miss();
}

@end

@interface CLCacheScanner ()
@property (nonatomic, strong) CLScanCancellation *cancellation;
@end

@implementation CLCacheScanner

- (void)cancel
{
    [_cancellation cancel];
}

- (void)startWithProgress:(void (^_Nullable)(NSString *status))progress
               completion:(void (^)(NSArray<CLCacheItem *> *items, BOOL limited, NSString *note, BOOL cancelled))completion
{
    [self cancel];
    CLScanCancellation *cancellation = [CLScanCancellation new];
    _cancellation = cancellation;
#define CL_SCAN_CANCELLED() do { if (cancellation.isCancelled) { if (completion) completion(nil, scanLimited, @"扫描已取消。", YES); return; } } while (0)
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<CLCacheItem *> *items = [NSMutableArray new];
        NSMutableArray<NSString *> *emptyRoots = [NSMutableArray new];
        BOOL scanLimited = NO;
        NSUInteger failedEnumerations = 0;
        NSUInteger limitedContainers = 0;
        NSUInteger limitedMeasurements = 0;
        NSUInteger missingIdentities = 0;
        NSArray *roots = @[@"/private/var/mobile/Containers/Data/Application",
                           @"/private/var/mobile/Containers/Data/PluginKitPlugin"];
        for (NSString *root in roots) {
            CL_SCAN_CANCELLED();
            NSString *kind = [root.lastPathComponent isEqualToString:@"Application"] ? @"应用" : @"扩展";
            NSArray *containers = cl_enumerate(root, 0, cancellation, ^(int64_t done, int64_t total, NSUInteger __unused f) {
                if (progress) progress([NSString stringWithFormat:@"正在查找%@… %lld%%", kind, (long long)(done * 100 / (total ?: 1))]);
            });
            if (!containers) {
                CL_SCAN_CANCELLED();
                scanLimited = YES;
                failedEnumerations++;
                cl_log(@"cache scan: %@ container enumeration failed", kind);
                continue;
            }
            if (!cancellation.isCancelled && !cl_display_names_loaded()) {
                if (progress) progress(@"正在读取应用名称…");
                cl_load_display_names();
            }
            if (!containers.count) [emptyRoots addObject:kind];
            NSUInteger idx = 0;
            for (NSString *c in containers) {
                CL_SCAN_CANCELLED();
                idx++;
                if ((idx % 10 == 0 || idx == containers.count) && progress) {
                    progress([NSString stringWithFormat:@"正在测量%@ %lu/%lu…", kind,
                              (unsigned long)idx, (unsigned long)containers.count]);
                }
                BOOL safeContainer = CLSafetyHasNoSymlinkAncestry(c, NO);
                BOOL granted = safeContainer && cl_grant(c);  // one token for the whole container
                NSString *caches = [c stringByAppendingPathComponent:@"Library/Caches"];
                NSString *tmp = [c stringByAppendingPathComponent:@"tmp"];
                unsigned long long cacheBytes = 0, tempBytes = 0;
                BOOL safeCaches = safeContainer &&
                    CLSafetyTargetMatchesContainer(caches, c, @"Library/Caches");
                BOOL safeTmp = safeContainer &&
                    CLSafetyTargetMatchesContainer(tmp, c, @"tmp");
                CLCacheMeasurementState cacheState = granted && safeCaches
                    ? CLCacheMeasureDirectory(caches, cancellation, &cacheBytes)
                    : CLCacheMeasurementLimited;
                if (cacheState == CLCacheMeasurementCancelled) { if (completion) completion(nil, scanLimited, @"扫描已取消。", YES); return; }
                CLCacheMeasurementState tempState = granted && safeTmp
                    ? CLCacheMeasureDirectory(tmp, cancellation, &tempBytes)
                    : CLCacheMeasurementLimited;
                if (tempState == CLCacheMeasurementCancelled) { if (completion) completion(nil, scanLimited, @"扫描已取消。", YES); return; }
                if (!granted || !safeContainer) {
                    scanLimited = YES;
                    limitedContainers++;
                    cl_log(@"cache scan: %@ (%@) %@", c.lastPathComponent, cl_bundle_id_for_container(c) ?: @"未知应用",
                           safeContainer ? @"拒绝访问" : @"未通过路径安全检查");
                }
                if (cacheState == CLCacheMeasurementLimited || tempState == CLCacheMeasurementLimited) {
                    scanLimited = YES;
                    limitedMeasurements++;
                }
                BOOL cacheKnown = cacheState != CLCacheMeasurementLimited;
                BOOL tempKnown = tempState != CLCacheMeasurementLimited;
                if (cacheKnown && tempKnown && cacheBytes + tempBytes < 64 * 1024) continue;
                CLCacheItem *item = [CLCacheItem new];
                NSString *bid = granted ? cl_container_label(c) : nil;
                item.bundleID = bid;
                item.name = cl_display_name(bid) ?: bid ?: c.lastPathComponent;
                item.targets = @[caches, tmp];
                item.cacheBytes = cacheBytes;
                item.tempBytes = tempBytes;
                item.cacheKnown = cacheKnown;
                item.tempKnown = tempKnown;
                item.limited = !cacheKnown || !tempKnown;
                item.containerPath = c;
                item.targetRecords = @[
                    CLCacheTargetRecordForPath(caches, @"Library/Caches"),
                    CLCacheTargetRecordForPath(tmp, @"tmp"),
                ];
                CLCacheCaptureContainerIdentity(item);
                if (!bid.length || !item.containerIdentityKnown) {
                    item.limited = YES;
                    scanLimited = YES;
                    missingIdentities++;
                }
                item.selected = !item.limited;
                [items addObject:item];
            }
        }
        CL_SCAN_CANCELLED();
        unsigned long long crash = 0;
        // Crash logs are in a system group, which worse_query reaches on iOS 27
        // only. On iOS 26 the section is left out instead of reported as limited.
        BOOL crashReachable = cl_system_areas_reachable();
        BOOL safeCrashPath = crashReachable && CLCacheCrashPathIsSafe(CLCrashLogsPath);
        CLCacheMeasurementState crashState = !crashReachable ? CLCacheMeasurementMissing
            : safeCrashPath ? CLCacheMeasureDirectory(CLCrashLogsPath, cancellation, &crash)
                            : CLCacheMeasurementLimited;
        if (crashState == CLCacheMeasurementCancelled) { if (completion) completion(nil, scanLimited, @"扫描已取消。", YES); return; }
        if (crashState == CLCacheMeasurementLimited) {
            scanLimited = YES;
            limitedMeasurements++;
        }
        if (crashState == CLCacheMeasurementLimited || crash > 0) {
            CLCacheItem *logs = [CLCacheItem new];
            logs.name = @"崩溃日志";
            logs.targets = @[CLCrashLogsPath];
            logs.cacheBytes = crash;
            logs.cacheKnown = crashState != CLCacheMeasurementLimited;
            logs.crashLogs = YES;
            logs.limited = crashState == CLCacheMeasurementLimited;
            logs.targetRecords = @[CLCacheTargetRecordForPath(CLCrashLogsPath, nil)];
            logs.selected = !logs.limited;
            [items addObject:logs];
        }
        [items sortUsingComparator:^NSComparisonResult(CLCacheItem *a, CLCacheItem *b) {
            return a.bytes > b.bytes ? NSOrderedAscending : (a.bytes < b.bytes ? NSOrderedDescending : NSOrderedSame);
        }];
        NSMutableArray<NSString *> *notes = [NSMutableArray new];
        if (failedEnumerations) {
            [notes addObject:[NSString stringWithFormat:@"%lu 个容器枚举失败", (unsigned long)failedEnumerations]];
        }
        if (limitedContainers) {
            [notes addObject:[NSString stringWithFormat:@"%lu 个容器访问受限", (unsigned long)limitedContainers]];
        }
        if (limitedMeasurements) {
            [notes addObject:[NSString stringWithFormat:@"%lu 个缓存目录测量受限", (unsigned long)limitedMeasurements]];
        }
        if (missingIdentities) {
            [notes addObject:[NSString stringWithFormat:@"%lu 个容器没有标识或身份信息", (unsigned long)missingIdentities]];
        }
        NSString *note = nil;
        if (scanLimited) {
            [notes addObject:@"受限行已排除，其余行仍可清理"];
            note = [NSString stringWithFormat:@"扫描不完整：%@。详见日志。", [notes componentsJoinedByString:@"；"]];
        } else if (emptyRoots.count) {
            note = [NSString stringWithFormat:@"没有找到%@容器。", [emptyRoots componentsJoinedByString:@" 或 "]];
        }
        if (completion) completion(items, scanLimited, note, NO);
    });
#undef CL_SCAN_CANCELLED
}

@end
