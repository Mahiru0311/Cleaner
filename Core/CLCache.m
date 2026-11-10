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
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>

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
    // Cheap access probe: one open() instead of a full top-level listing.
    // The old contentsOfDirectoryAtPath call ran a whole readdir pass and
    // allocated a string per entry just to test whether the directory is
    // readable — pure waste on every measured tree (v2.2).
    int probe = open(dir.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_CLOEXEC);
    if (probe < 0 && cl_grant(dir))
        probe = open(dir.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_CLOEXEC);
    if (probe >= 0) close(probe);

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

// Same record, built from a stat the caller already took (the scanner stats
// each target once for the measure cache, so re-statting here would be a
// second identical stat per target per scan — v2.2).
static CLCacheTargetRecord *CLCacheTargetRecordForPathWithStat(NSString *path, NSString *relativePath,
                                                               CLCachePathState state, const struct stat *st)
{
    CLCacheTargetRecord *record = [CLCacheTargetRecord new];
    record.path = path;
    record.relativePath = relativePath;
    if (state == CLCachePathExisting && st) {
        record.existed = YES;
        record.identityKnown = YES;
        record.device = st->st_dev;
        record.inode = st->st_ino;
        record.mode = st->st_mode & S_IFMT;
    }
    return record;
}

#pragma mark - Persistent measurement cache (v2.2)
//
// A rescan re-measures every container's Caches + tmp trees from scratch,
// even when nothing changed — that full walk is most of the scan time. The
// cache remembers each container's measured sizes, keyed by the container
// identity and the two directories' (mtime, size): a directory's mtime and
// size change whenever entries are added, removed or renamed inside it, so
// an unchanged pair means the tree is unchanged and the stored sizes are
// still right. Entries expire after 24 h. The sizes are display-only: the
// clean-time validation (CLCacheValidateItem) re-checks every identity
// before anything is deleted, so a stale cached size can never cause a
// wrong delete — at worst the list shows yesterday's number for an idle app.

static const NSTimeInterval kCLMeasureCacheTTL = 24 * 3600;

static NSString *cl_measure_cache_path(void)
{
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    return dir.length ? [dir stringByAppendingPathComponent:@"cl-cache-measure.plist"] : nil;
}

static BOOL cl_measure_cache_lookup(NSDictionary *cache, NSString *container,
                                    const struct stat *containerStat,
                                    const struct stat *cachesStat, const struct stat *tmpStat,
                                    unsigned long long *cacheBytes, unsigned long long *tempBytes,
                                    BOOL *cacheKnown, BOOL *tempKnown)
{
    NSDictionary *e = cache[container];
    if (![e isKindOfClass:NSDictionary.class]) return NO;
    NSTimeInterval savedAt = [e[@"savedAt"] doubleValue];
    if (savedAt <= 0 || NSDate.date.timeIntervalSinceReferenceDate - savedAt > kCLMeasureCacheTTL) return NO;
    if ([e[@"device"] longLongValue] != (long long)containerStat->st_dev ||
        [e[@"inode"] unsignedLongLongValue] != containerStat->st_ino) return NO;
    if ([e[@"cachesMtime"] longLongValue] != (long long)cachesStat->st_mtimespec.tv_sec ||
        [e[@"cachesMtimeNs"] longValue] != cachesStat->st_mtimespec.tv_nsec ||
        [e[@"cachesSize"] longLongValue] != (long long)cachesStat->st_size) return NO;
    if ([e[@"tmpMtime"] longLongValue] != (long long)tmpStat->st_mtimespec.tv_sec ||
        [e[@"tmpMtimeNs"] longValue] != tmpStat->st_mtimespec.tv_nsec ||
        [e[@"tmpSize"] longLongValue] != (long long)tmpStat->st_size) return NO;
    *cacheBytes = [e[@"cacheBytes"] unsignedLongLongValue];
    *tempBytes = [e[@"tempBytes"] unsignedLongLongValue];
    *cacheKnown = [e[@"cacheKnown"] boolValue];
    *tempKnown = [e[@"tempKnown"] boolValue];
    // Only fully-known measurements are ever stored (see the store call):
    // a limited measurement must be retried next time, not replayed.
    if (!*cacheKnown || !*tempKnown) return NO;
    return YES;
}

static void cl_measure_cache_store(NSMutableDictionary *store, NSString *container,
                                   const struct stat *containerStat,
                                   const struct stat *cachesStat, const struct stat *tmpStat,
                                   unsigned long long cacheBytes, unsigned long long tempBytes,
                                   BOOL cacheKnown, BOOL tempKnown)
{
    store[container] = @{ @"device": @(containerStat->st_dev), @"inode": @(containerStat->st_ino),
        @"cachesMtime": @(cachesStat->st_mtimespec.tv_sec), @"cachesMtimeNs": @(cachesStat->st_mtimespec.tv_nsec),
        @"cachesSize": @(cachesStat->st_size),
        @"tmpMtime": @(tmpStat->st_mtimespec.tv_sec), @"tmpMtimeNs": @(tmpStat->st_mtimespec.tv_nsec),
        @"tmpSize": @(tmpStat->st_size),
        @"cacheBytes": @(cacheBytes), @"tempBytes": @(tempBytes),
        @"cacheKnown": @(cacheKnown), @"tempKnown": @(tempKnown),
        @"savedAt": @(NSDate.date.timeIntervalSinceReferenceDate) };
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
    // Mark the store's last scan as stale, or Home's ensureScan (which
    // skips scanning when lastScanFinished > 0) would never start a new
    // scan after a refresh — the old power menu's "rescan" silently did
    // nothing once any scan had finished (v2.2). `scanning` is left alone:
    // a scan that is still running must still block a second one.
    _lastScanFinished = 0;
}

@end

@interface CLCacheScanner ()
@property (nonatomic, strong) CLScanCancellation *cancellation;
@end

// Shared state for one scan's parallel workers. The lock guards the items
// list, the counters and the incremental-delivery bookkeeping; the measure
// cache is loaded once (read-only) and new entries go through the same lock.
@interface CLCacheScanContext : NSObject
@property (nonatomic, strong) CLScanCancellation *cancellation;
@property (nonatomic, copy) NSDictionary *measureCache;
@property (nonatomic, strong) NSMutableDictionary *measureStore;
@property (nonatomic, strong) NSLock *lock;
@property (nonatomic, strong) NSMutableArray<CLCacheItem *> *items;
@property (nonatomic) NSUInteger completedCount;
@property (nonatomic) NSUInteger deliveredItemCount;
@property (nonatomic) BOOL scanLimited;
@property (nonatomic) NSUInteger limitedContainers;
@property (nonatomic) NSUInteger limitedMeasurements;
@property (nonatomic) NSUInteger missingIdentities;
@property (nonatomic) NSUInteger measureCacheHits;
@end

@implementation CLCacheScanContext
@end

@implementation CLCacheScanner

- (void)cancel
{
    [_cancellation cancel];
}

- (void)startWithProgress:(void (^_Nullable)(NSString *status))progress
               completion:(void (^)(NSArray<CLCacheItem *> *items, BOOL limited, NSString *note, BOOL cancelled))completion
{
    [self startWithProgress:progress itemsUpdate:nil completion:completion];
}

// Measures one container (grant + Caches/tmp sizes + identity). Returns the
// item, or nil when it is too small to list (both known, under 64 KB) or the
// scan was cancelled. Updates the context counters under the context lock.
// Runs on one of the scan's 4 worker threads; every call it makes is
// thread-safe (cl_grant takes the grant lock, the name lookups take the LS
// lock, the safety checks are pure stat calls, the measure cache is
// read-only here and new entries are stored under the lock).
- (CLCacheItem *)scanOneContainer:(NSString *)c context:(CLCacheScanContext *)ctx
{
    CLScanCancellation *cancellation = ctx.cancellation;
    if (cancellation.isCancelled) return nil;
    NSString *caches = [c stringByAppendingPathComponent:@"Library/Caches"];
    NSString *tmp = [c stringByAppendingPathComponent:@"tmp"];
    // One ancestry walk for the container + both targets (v2.2), instead of
    // the three walks the two single-target checks used to do.
    BOOL safeCaches = NO, safeTmp = NO;
    BOOL safeContainer = CLSafetyContainerTargetsSafe(c, caches, @"Library/Caches", &safeCaches,
                                                         tmp, @"tmp", &safeTmp);
    BOOL granted = safeContainer && cl_grant(c);  // one token for the whole container
    // Stat everything once up front: the container identity, both targets
    // (for the measure cache and the target records) — no re-stat later.
    struct stat containerStat = {0};
    BOOL containerKnown = cl_stat(c, &containerStat) && S_ISDIR(containerStat.st_mode);
    struct stat cachesStat = {0}, tmpStat = {0};
    CLCachePathState cachesState = CLCacheInspectPath(caches, &cachesStat);
    CLCachePathState tmpState = CLCacheInspectPath(tmp, &tmpStat);
    unsigned long long cacheBytes = 0, tempBytes = 0;
    BOOL cacheKnown = NO, tempKnown = NO;
    BOOL fromCache = NO;
    if (containerKnown && cachesState == CLCachePathExisting && tmpState == CLCachePathExisting) {
        fromCache = cl_measure_cache_lookup(ctx.measureCache, c, &containerStat, &cachesStat, &tmpStat,
                                            &cacheBytes, &tempBytes, &cacheKnown, &tempKnown);
    }
    CLCacheMeasurementState cacheState, tempState;
    if (fromCache) {
        cacheState = CLCacheMeasurementKnown;
        tempState = CLCacheMeasurementKnown;
        [ctx.lock lock];
        ctx.measureCacheHits++;
        [ctx.lock unlock];
    } else {
        cacheState = granted && safeCaches
            ? CLCacheMeasureDirectory(caches, cancellation, &cacheBytes)
            : CLCacheMeasurementLimited;
        if (cacheState == CLCacheMeasurementCancelled) return nil;
        tempState = granted && safeTmp
            ? CLCacheMeasureDirectory(tmp, cancellation, &tempBytes)
            : CLCacheMeasurementLimited;
        if (tempState == CLCacheMeasurementCancelled) return nil;
        cacheKnown = cacheState != CLCacheMeasurementLimited;
        tempKnown = tempState != CLCacheMeasurementLimited;
        // Only fully-known measurements are cached: a limited one must be
        // retried on the next scan, not replayed from the cache.
        if (cacheKnown && tempKnown && containerKnown &&
            cachesState == CLCachePathExisting && tmpState == CLCachePathExisting) {
            [ctx.lock lock];
            cl_measure_cache_store(ctx.measureStore, c, &containerStat, &cachesStat, &tmpStat,
                                   cacheBytes, tempBytes, cacheKnown, tempKnown);
            [ctx.lock unlock];
        }
    }
    [ctx.lock lock];
    if (!granted || !safeContainer) {
        ctx.scanLimited = YES;
        ctx.limitedContainers++;
        cl_log(@"cache scan: %@ (%@) %@", c.lastPathComponent, cl_bundle_id_for_container(c) ?: @"未知应用",
               safeContainer ? @"拒绝访问" : @"未通过路径安全检查");
    }
    if (!cacheKnown || !tempKnown) {
        ctx.scanLimited = YES;
        ctx.limitedMeasurements++;
    }
    [ctx.lock unlock];
    if (cacheKnown && tempKnown && cacheBytes + tempBytes < 64 * 1024) return nil;
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
        CLCacheTargetRecordForPathWithStat(caches, @"Library/Caches", cachesState, &cachesStat),
        CLCacheTargetRecordForPathWithStat(tmp, @"tmp", tmpState, &tmpStat),
    ];
    if (containerKnown) {
        item.containerIdentityKnown = YES;
        item.containerDevice = containerStat.st_dev;
        item.containerInode = containerStat.st_ino;
        item.containerMode = containerStat.st_mode & S_IFMT;
    }
    if (!bid.length || !item.containerIdentityKnown) {
        item.limited = YES;
        [ctx.lock lock];
        ctx.scanLimited = YES;
        ctx.missingIdentities++;
        [ctx.lock unlock];
    }
    item.selected = !item.limited;
    return item;
}

- (void)startWithProgress:(void (^_Nullable)(NSString *status))progress
              itemsUpdate:(void (^_Nullable)(NSArray<CLCacheItem *> *newItems))itemsUpdate
               completion:(void (^)(NSArray<CLCacheItem *> *items, BOOL limited, NSString *note, BOOL cancelled))completion
{
    [self cancel];
    CLScanCancellation *cancellation = [CLScanCancellation new];
    _cancellation = cancellation;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        CLCacheScanContext *ctx = [CLCacheScanContext new];
        ctx.cancellation = cancellation;
        ctx.lock = [NSLock new];
        ctx.items = [NSMutableArray new];
        ctx.measureStore = [NSMutableDictionary new];
        NSString *cachePath = cl_measure_cache_path();
        NSDictionary *loaded = cachePath ? [NSDictionary dictionaryWithContentsOfFile:cachePath] : nil;
        ctx.measureCache = [loaded isKindOfClass:NSDictionary.class] ? loaded : @{};
        NSMutableArray<NSString *> *emptyRoots = [NSMutableArray new];
        NSUInteger failedEnumerations = 0;
        CFAbsoluteTime scanStarted = CFAbsoluteTimeGetCurrent();
        NSArray *roots = @[@"/private/var/mobile/Containers/Data/Application",
                           @"/private/var/mobile/Containers/Data/PluginKitPlugin"];
        for (NSString *root in roots) {
            if (cancellation.isCancelled) { if (completion) completion(nil, ctx.scanLimited, @"扫描已取消。", YES); return; }
            NSString *kind = [root.lastPathComponent isEqualToString:@"Application"] ? @"应用" : @"扩展";
            NSArray *containers = cl_enumerate(root, 0, cancellation, ^(int64_t done, int64_t total, NSUInteger __unused f) {
                if (progress) progress([NSString stringWithFormat:@"正在查找%@… %lld%%", kind, (long long)(done * 100 / (total ?: 1))]);
            });
            if (!containers) {
                if (cancellation.isCancelled) { if (completion) completion(nil, ctx.scanLimited, @"扫描已取消。", YES); return; }
                ctx.scanLimited = YES;
                failedEnumerations++;
                cl_log(@"cache scan: %@ container enumeration failed", kind);
                continue;
            }
            if (!cancellation.isCancelled && !cl_display_names_loaded()) {
                if (progress) progress(@"正在读取应用名称…");
                cl_load_display_names();
            }
            if (!containers.count) [emptyRoots addObject:kind];
            // Parallel measurement (v2.2): 4 strided workers, not one
            // container at a time. dispatch_apply(4, ...) bounds the
            // concurrency — a plain dispatch_apply over all containers
            // would happily run 114 threads. Each worker measures its
            // slice (grant + two tree walks, or a measurement-cache hit)
            // and appends finished items under the context lock.
            NSUInteger total = containers.count;
            NSUInteger baseCompleted = ctx.completedCount;
            // Per-root delivery counter (doneInRoot restarts at 1 for the
            // second root, so this must restart too — otherwise the
            // subtraction below underflows and every item delivers a batch).
            __block NSUInteger deliveredCompleted = 0;
            dispatch_apply(4, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t w) {
                for (NSUInteger idx = w; idx < total; idx += 4) {
                    if (cancellation.isCancelled) return;
                    CLCacheItem *item = [self scanOneContainer:containers[idx] context:ctx];
                    NSArray<CLCacheItem *> *batch = nil;
                    [ctx.lock lock];
                    if (item) [ctx.items addObject:item];
                    ctx.completedCount++;
                    NSUInteger doneInRoot = ctx.completedCount - baseCompleted;
                    // Deliver finished rows in batches of 8 (sorted by
                    // size inside the batch) so the list fills in while
                    // the scan runs; the final completion re-sorts all.
                    if (itemsUpdate && ctx.items.count > ctx.deliveredItemCount &&
                        (doneInRoot - deliveredCompleted >= 8 || doneInRoot == total)) {
                        batch = [[ctx.items subarrayWithRange:NSMakeRange(ctx.deliveredItemCount,
                                                                          ctx.items.count - ctx.deliveredItemCount)]
                                 sortedArrayUsingComparator:^NSComparisonResult(CLCacheItem *a, CLCacheItem *b) {
                            return a.bytes > b.bytes ? NSOrderedAscending : (a.bytes < b.bytes ? NSOrderedDescending : NSOrderedSame);
                        }];
                        ctx.deliveredItemCount = ctx.items.count;
                        deliveredCompleted = doneInRoot;
                    }
                    [ctx.lock unlock];
                    if (batch.count) itemsUpdate(batch);
                    if (progress && (doneInRoot % 10 == 0 || doneInRoot == total)) {
                        progress([NSString stringWithFormat:@"正在测量%@ %lu/%lu…", kind,
                                  (unsigned long)doneInRoot, (unsigned long)total]);
                    }
                }
            });
            if (cancellation.isCancelled) { if (completion) completion(nil, ctx.scanLimited, @"扫描已取消。", YES); return; }
        }
        unsigned long long crash = 0;
        // Crash logs are in a system group, which worse_query reaches on iOS 27
        // only. On iOS 26 the section is left out instead of reported as limited.
        BOOL crashReachable = cl_system_areas_reachable();
        BOOL safeCrashPath = crashReachable && CLCacheCrashPathIsSafe(CLCrashLogsPath);
        CLCacheMeasurementState crashState = !crashReachable ? CLCacheMeasurementMissing
            : safeCrashPath ? CLCacheMeasureDirectory(CLCrashLogsPath, cancellation, &crash)
                            : CLCacheMeasurementLimited;
        if (crashState == CLCacheMeasurementCancelled) { if (completion) completion(nil, ctx.scanLimited, @"扫描已取消。", YES); return; }
        if (crashState == CLCacheMeasurementLimited) {
            ctx.scanLimited = YES;
            ctx.limitedMeasurements++;
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
            [ctx.items addObject:logs];
        }
        [ctx.items sortUsingComparator:^NSComparisonResult(CLCacheItem *a, CLCacheItem *b) {
            return a.bytes > b.bytes ? NSOrderedAscending : (a.bytes < b.bytes ? NSOrderedDescending : NSOrderedSame);
        }];
        NSMutableArray<NSString *> *notes = [NSMutableArray new];
        if (failedEnumerations) {
            [notes addObject:[NSString stringWithFormat:@"%lu 个容器枚举失败", (unsigned long)failedEnumerations]];
        }
        if (ctx.limitedContainers) {
            [notes addObject:[NSString stringWithFormat:@"%lu 个容器访问受限", (unsigned long)ctx.limitedContainers]];
        }
        if (ctx.limitedMeasurements) {
            [notes addObject:[NSString stringWithFormat:@"%lu 个缓存目录测量受限", (unsigned long)ctx.limitedMeasurements]];
        }
        if (ctx.missingIdentities) {
            [notes addObject:[NSString stringWithFormat:@"%lu 个容器没有标识或身份信息", (unsigned long)ctx.missingIdentities]];
        }
        NSString *note = nil;
        if (ctx.scanLimited) {
            [notes addObject:@"受限行已排除，其余行仍可清理"];
            note = [NSString stringWithFormat:@"扫描不完整：%@。详见日志。", [notes componentsJoinedByString:@"；"]];
        } else if (emptyRoots.count) {
            note = [NSString stringWithFormat:@"没有找到%@容器。", [emptyRoots componentsJoinedByString:@" 或 "]];
        }
        // Persist the new measurements for the next scan (only the entries
        // measured this time; the file is capped so it never grows without
        // bound — over the cap only this scan's entries are kept).
        if (ctx.measureStore.count && cachePath) {
            NSMutableDictionary *merged = [ctx.measureCache mutableCopy] ?: [NSMutableDictionary new];
            [merged addEntriesFromDictionary:ctx.measureStore];
            if (merged.count > 1024) merged = [ctx.measureStore mutableCopy];
            if (![merged writeToFile:cachePath atomically:YES])
                cl_log(@"cache scan: cannot save the measurement cache to %@", cachePath);
        }
        cl_log(@"cache scan: %lu items in %.1f s (%lu from the measurement cache)",
               (unsigned long)ctx.items.count, CFAbsoluteTimeGetCurrent() - scanStarted,
               (unsigned long)ctx.measureCacheHits);
        if (completion) completion([ctx.items copy], ctx.scanLimited, note, NO);
    });
}

@end
