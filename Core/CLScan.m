//
//  CLScan.m
//  Cleaner v2 — extracted from WQAccess.m (v0.1, commit 201591c8), renamed.
//  Cleaner
//
//  Sandbox extension technique: worse_query by Taj C (forcequit),
//  https://github.com/forcequitOS/worse_query, GPL-3.0-or-later.
//
//  Notes from testing on 27.0.1:
//  - An extension covers the folder it was issued for. A container root
//    extension was not enough to open a file two levels down for writing, so
//    writes always ask for the file's own folder first.
//  - /var/containers/Shared/SystemGroup itself gets no token; its children do.
//

#import "CLScan.h"
#import "CLGrant.h"
#import "CLSafety.h"


#import <dlfcn.h>
#import <objc/message.h>
#import <dirent.h>
#import <errno.h>
#import <fcntl.h>
#import <string.h>
#import <stdatomic.h>
#import <sys/clonefile.h>
#import <sys/stat.h>
#import <sys/mount.h>
#import <sys/xattr.h>
#import <unistd.h>
#import <xpc/xpc.h>

@implementation CLScanCancellation {
    _Atomic BOOL _cancelled;
}

- (BOOL)isCancelled
{
    return atomic_load_explicit(&_cancelled, memory_order_relaxed);
}

- (void)cancel
{
    atomic_store_explicit(&_cancelled, YES, memory_order_relaxed);
}

@end

// fsgetpath: resolve a filesystem object id to a path. Not in the public SDK.
extern ssize_t fsgetpath(char *buf, size_t buflen, fsid_t *fsid, uint64_t objid);

// Highest object id in use on the volume, roughly: APFS hands out ids in
// increasing order, so a file created now gets one of the newest. Containers
// of apps installed long after setup sit far above the ids of Apple's own
// apps; a fixed limit misses them on a well-used device.
static const int64_t kCLInodeMargin = 100000;

#ifdef CL_ACCESS_TESTING
int64_t cl_test_volume_limit = -1;
#endif

static int64_t cl_volume_max_inode(fsid_t fsid, int64_t *probeInode)
{
    if (probeInode) *probeInode = 0;
#ifdef CL_ACCESS_TESTING
    if (cl_test_volume_limit >= 0) return cl_test_volume_limit;
#endif
    NSArray<NSString *> *directories = @[
        NSTemporaryDirectory() ?: @"",
        [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"],
        [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject] ?: @"",
    ];
    for (NSString *directory in directories) {
        if (!directory.length) continue;
        NSString *probe = [directory stringByAppendingPathComponent:
                           [NSString stringWithFormat:@"wq-inode-%u", arc4random()]];
        int fd = open(probe.fileSystemRepresentation, O_CREAT | O_EXCL | O_WRONLY, 0600);
        if (fd < 0) {
            cl_log(@"inode probe: cannot create %@ (%@)", probe, cl_errno(errno));
            continue;
        }
        struct stat st = {0};
        struct statfs sfs = {0};
        BOOL ok = fstat(fd, &st) == 0 && fstatfs(fd, &sfs) == 0;
        int err = errno;
        close(fd);
        unlink(probe.fileSystemRepresentation);
        if (!ok) {
            cl_log(@"inode probe: cannot inspect %@ (%@)", probe, cl_errno(err));
            continue;
        }
        if (memcmp(&sfs.f_fsid, &fsid, sizeof(fsid)) != 0) {
            cl_log(@"inode probe: %@ is on a different volume", probe);
            continue;
        }
        if ((uint64_t)st.st_ino > (uint64_t)INT64_MAX - (uint64_t)kCLInodeMargin) return 0;
        if (probeInode) *probeInode = (int64_t)st.st_ino;
        return (int64_t)st.st_ino + kCLInodeMargin;
    }
    return 0;
}

// Scans object ids first...last once and collects the direct children of every
// base in `bases` (each a /private/var/... path), as path -> object id. Uses at
// most 4 worker threads (half the cores) at `qos`: a full scan of a well-used
// device is millions of ids, and running it on every core made phones hot.
// progress gets the ids done, the range size and the hits per base. Returns
// one dictionary per base, or nil when cancelled.
typedef void (^CLScanProgress)(int64_t done, int64_t total, const NSUInteger *counts);
static NSArray<NSMutableDictionary<NSString *, NSNumber *> *> *cl_scan_children(fsid_t fsid, int64_t firstId, int64_t lastId,
                                                                               NSArray<NSString *> *bases,
                                                                               CLScanCancellation *cancellation,
                                                                               qos_class_t qos, CLScanProgress progress)
{
    NSUInteger baseCount = MIN(bases.count, (NSUInteger)8);
    // Heap tables: blocks can't capture C arrays.
    char **prefixes = calloc(8, sizeof(char *));
    size_t *prefixLens = calloc(8, sizeof(size_t));
    NSUInteger *counts = calloc(8, sizeof(NSUInteger));
    if (!prefixes || !prefixLens || !counts) { free(prefixes); free(prefixLens); free(counts); return nil; }
    NSMutableArray<NSMutableDictionary<NSString *, NSNumber *> *> *found = [NSMutableArray new];
    for (NSUInteger i = 0; i < baseCount; i++) {
        prefixes[i] = strdup(bases[i].fileSystemRepresentation);
        prefixLens[i] = strlen(prefixes[i]);
        [found addObject:[NSMutableDictionary new]];
    }
    if (firstId < 1) firstId = 1;
    int64_t total = lastId >= firstId ? lastId - firstId + 1 : 0;
    NSLock *lock = [NSLock new];
    const int64_t chunk = 32768;
    int64_t chunks = (total + chunk - 1) / chunk;
    __block int64_t nextChunk = 0, done = 0;
    NSUInteger cores = NSProcessInfo.processInfo.activeProcessorCount;
    size_t workers = (size_t)MAX((NSUInteger)1, MIN((NSUInteger)4, cores / 2));
    dispatch_apply(workers, dispatch_get_global_queue(qos, 0), ^(size_t __unused w) {
        fsid_t id = fsid;
        char buf[1200];
        for (;;) {
            if (cancellation.isCancelled) return;
            [lock lock];
            int64_t c = nextChunk++;
            [lock unlock];
            if (c >= chunks) return;
            int64_t first = firstId + c * chunk, last = MIN(first + chunk - 1, lastId);
            NSMutableDictionary *local[8] = {nil};
            for (int64_t ino = first; ino <= last; ino++) {
                if ((ino & 127) == 0 && cancellation.isCancelled) return;
                ssize_t n = fsgetpath(buf, sizeof(buf), &id, (uint64_t)ino);
                if (n <= 0) continue;
                // fsgetpath returns /private/var/...; bases are normalized the same way.
                for (NSUInteger i = 0; i < baseCount; i++) {
                    if (strncmp(buf, prefixes[i], prefixLens[i]) == 0 && buf[prefixLens[i]] == '/' &&
                        strchr(buf + prefixLens[i] + 1, '/') == NULL) {
                        if (!local[i]) local[i] = [NSMutableDictionary new];
                        local[i][[NSString stringWithUTF8String:buf]] = @(ino);
                        break;
                    }
                }
            }
            NSUInteger snapshot[8] = {0};
            [lock lock];
            for (NSUInteger i = 0; i < baseCount; i++) {
                if (local[i]) [found[i] addEntriesFromDictionary:local[i]];
                snapshot[i] = counts[i] = found[i].count;
            }
            done += last - first + 1;
            int64_t nowDone = done;
            [lock unlock];
            if (progress && !cancellation.isCancelled) progress(nowDone, total, snapshot);
        }
    });
    for (NSUInteger i = 0; i < baseCount; i++) free(prefixes[i]);
    free(prefixes);
    free(prefixLens);
    free(counts);
    if (cancellation.isCancelled) return nil;
    return found;
}

static NSArray<NSString *> *cl_sorted_paths(NSDictionary<NSString *, NSNumber *> *hits)
{
    return [hits.allKeys sortedArrayUsingSelector:@selector(compare:)];
}

static void cl_check_scan_completion(fsid_t fsid, int64_t probeInode, NSString *what)
{
    if (probeInode <= 0) return;
    int64_t afterProbe = 0;
    if (cl_volume_max_inode(fsid, &afterProbe) <= 0 || afterProbe <= 0) {
        // A completion probe failure must not turn a usable partial list
        // into "no apps at all". The initial bound still found what it
        // scanned; callers can refresh later.
        cl_log(@"enumerate %@: completion probe unavailable; returning the scanned subset", what);
    } else if (afterProbe > probeInode + kCLInodeMargin) {
        cl_log(@"enumerate %@: inode IDs advanced beyond the scanned bound; the list may be incomplete until refreshed", what);
    }
}

// The three container parents that can only be listed by scanning. One scan
// collects all three and is reused for a while: the Cache Cleaner alone used to
// scan the whole id range three times (apps, extensions, and the daemon scan
// that finds the app name database).
static NSArray<NSString *> *cl_shared_scan_roots(void)
{
    return @[ @"/private/var/mobile/Containers/Data/Application",
              @"/private/var/mobile/Containers/Data/PluginKitPlugin",
              @"/private/var/mobile/Containers/Data/InternalDaemon" ];
}

#pragma mark - Persistent container scan
//
// APFS hands out object ids in increasing order and never reuses them, so a
// container created after a scan has an id above that scan's probe id. The
// result is kept on disk with the probe id: the next scan only checks the
// ids created since, and confirms each remembered container by resolving
// its id again (gone or moved containers are dropped). A full scan still
// runs once a week, or when the volume or its ids don't match.

static const NSTimeInterval kCLFullScanInterval = 7 * 24 * 3600;
static const NSInteger kCLScanCacheVersion = 1;

static NSString *cl_scan_cache_path(void)
{
#ifdef CL_ACCESS_TESTING
    return nil;
#else
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    return dir.length ? [dir stringByAppendingPathComponent:@"wq-container-scan.plist"] : nil;
#endif
}

static NSDictionary *cl_scan_cache_load(fsid_t fsid, int64_t probeInode, NSTimeInterval now, NSString **whyFull)
{
    NSString *path = cl_scan_cache_path();
    if (!path) return nil;
    NSDictionary *cache = [NSDictionary dictionaryWithContentsOfFile:path];
    if (![cache isKindOfClass:NSDictionary.class]) { *whyFull = @"no saved scan"; return nil; }
    NSNumber *version = cache[@"version"], *f0 = cache[@"fsid0"], *f1 = cache[@"fsid1"], *probe = cache[@"probe"], *fullAt = cache[@"fullAt"];
    NSDictionary *roots = cache[@"roots"];
    for (id value in @[version ?: NSNull.null, f0 ?: NSNull.null, f1 ?: NSNull.null, probe ?: NSNull.null, fullAt ?: NSNull.null])
        if (![value isKindOfClass:NSNumber.class]) { *whyFull = @"saved scan unreadable"; return nil; }
    if (version.integerValue != kCLScanCacheVersion || ![roots isKindOfClass:NSDictionary.class]) { *whyFull = @"saved scan unreadable"; return nil; }
    if (f0.intValue != fsid.val[0] || f1.intValue != fsid.val[1]) { *whyFull = @"different volume"; return nil; }
    if (probe.longLongValue <= 0 || probe.longLongValue > probeInode) { *whyFull = @"volume ids were reset"; return nil; }
    NSTimeInterval age = now - fullAt.doubleValue;
    if (age < 0 || age >= kCLFullScanInterval) { *whyFull = @"weekly full scan"; return nil; }
    for (NSString *root in cl_shared_scan_roots())
        if (![roots[root] isKindOfClass:NSDictionary.class]) { *whyFull = @"saved scan unreadable"; return nil; }
    return cache;
}

static void cl_scan_cache_save(fsid_t fsid, int64_t probeInode, NSTimeInterval fullAt, NSDictionary *roots)
{
    NSString *path = cl_scan_cache_path();
    if (!path) return;
    NSDictionary *cache = @{ @"version": @(kCLScanCacheVersion), @"fsid0": @(fsid.val[0]), @"fsid1": @(fsid.val[1]),
                             @"probe": @(probeInode), @"fullAt": @(fullAt), @"roots": roots };
    if (![cache writeToFile:path atomically:YES]) cl_log(@"scan: cannot save the container list to %@", path);
}

// Drops remembered containers whose id no longer resolves to the same path.
static NSMutableDictionary<NSString *, NSNumber *> *cl_scan_verify(fsid_t fsid, NSDictionary *remembered, NSUInteger *dropped)
{
    NSMutableDictionary *kept = [NSMutableDictionary new];
    char buf[1200];
    for (NSString *path in remembered) {
        NSNumber *ino = remembered[path];
        if (![path isKindOfClass:NSString.class] || ![ino isKindOfClass:NSNumber.class]) { (*dropped)++; continue; }
        fsid_t id = fsid;
        ssize_t n = fsgetpath(buf, sizeof(buf), &id, ino.unsignedLongLongValue);
        if (n > 0 && strcmp(buf, path.fileSystemRepresentation) == 0) kept[path] = ino;
        else (*dropped)++;
    }
    return kept;
}

// One shared scan runs at a time, detached from the screen that started it:
// leaving the screen no longer throws the work away. Waiters stop waiting when
// cancelled; the scan finishes and is reused by the next caller.
static const NSTimeInterval kCLSharedScanTTL = 600;
static NSObject *gCLSharedScanGuard;
static void (^gCLScanProgress)(int64_t, int64_t, NSUInteger);
static NSUInteger gCLScanProgressIndex;
static id gCLScanProgressOwner;

static void cl_shared_scan_setup(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gCLSharedScanGuard = [NSObject new]; });
}

static void cl_scan_slots_clear(void);

void cl_enumerate_invalidate(void)
{
    cl_shared_scan_setup();
    @synchronized (gCLSharedScanGuard) { cl_scan_slots_clear(); }
}


// The first few path components, with UUIDs collapsed, so the Log shows which
// areas are visible without listing individual files.
static NSString *cl_sample_area(NSString *path)
{
    NSArray<NSString *> *parts = path.pathComponents;
    NSMutableArray *kept = [NSMutableArray new];
    for (NSString *part in parts) {
        if (kept.count >= 7) break;
        BOOL uuid = part.length == 36 && [[NSUUID alloc] initWithUUIDString:part] != nil;
        [kept addObject:uuid ? @"*" : part];
        if (uuid && kept.count >= 6) break;
    }
    return [NSString pathWithComponents:kept];
}

// LaunchServices API: each app's and plug-in's data container, where the
// system lets this app ask (it refuses on iOS 27).
static NSDictionary<NSString *, NSArray<NSString *> *> *cl_lsapi_list_containers(NSArray<NSString *> *roots, NSString **summary)
{
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    SEL defaultSel = NSSelectorFromString(@"defaultWorkspace");
    SEL appsSel = NSSelectorFromString(@"allInstalledApplications");
    if (!workspaceClass || ![workspaceClass respondsToSelector:defaultSel]) { *summary = @"LaunchServices API: unavailable"; return nil; }
    NSMutableDictionary<NSString *, NSString *> *labels = [NSMutableDictionary new];
    NSUInteger proxies = 0, plugins = 0;
    @try {
        id (*send)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        id workspace = send(workspaceClass, defaultSel);
        if (![workspace respondsToSelector:appsSel]) { *summary = @"LaunchServices API: no application list"; return nil; }
        NSArray *apps = send(workspace, appsSel);
        SEL containerSel = NSSelectorFromString(@"dataContainerURL"), idSel = NSSelectorFromString(@"bundleIdentifier");
        SEL pluginsSel = NSSelectorFromString(@"plugInKitPlugins");
        void (^add)(id) = ^(id proxy) {
            if (![proxy respondsToSelector:containerSel] || ![proxy respondsToSelector:idSel]) return;
            NSURL *url = send(proxy, containerSel);
            NSString *bid = send(proxy, idSel);
            if (![url isKindOfClass:NSURL.class] || ![bid isKindOfClass:NSString.class] || !url.path.length || !bid.length) return;
            NSString *path = cl_norm(url.path);
            if (!labels[path]) labels[path] = bid;
        };
        for (id app in [apps isKindOfClass:NSArray.class] ? apps : @[]) {
            proxies++;
            add(app);
            NSArray *appPlugins = [app respondsToSelector:pluginsSel] ? send(app, pluginsSel) : nil;
            for (id plugin in [appPlugins isKindOfClass:NSArray.class] ? appPlugins : @[]) { plugins++; add(plugin); }
        }
    } @catch (NSException *exception) {
        *summary = [NSString stringWithFormat:@"LaunchServices API: %@", exception.reason];
        return nil;
    }
    NSMutableDictionary<NSString *, NSMutableArray *> *found = [NSMutableDictionary new];
    for (NSString *root in roots) found[root] = [NSMutableArray new];
    for (NSString *path in labels) [found[path.stringByDeletingLastPathComponent] addObject:path];
    NSMutableDictionary *result = [NSMutableDictionary new];
    for (NSString *root in roots) result[root] = [found[root] sortedArrayUsingSelector:@selector(compare:)];
    *summary = [NSString stringWithFormat:@"LaunchServices API: %lu apps and %lu plug-ins, %lu data containers (%lu apps, %lu extensions)",
                (unsigned long)proxies, (unsigned long)plugins, (unsigned long)labels.count,
                (unsigned long)[result[roots[0]] count], (unsigned long)[result[roots[1]] count]];
    return result;
}

// Container-manager query function types (dlsym'd from
// libsystem_containermanager.dylib; same block as in CLGrant.m).
typedef void *(*cq_create_fn)(void);
typedef void (*cq_set_u64_fn)(void *, uint64_t);
typedef void (*cq_free_fn)(void *);
// The callback returns true to continue; a void block leaves that value undefined.
typedef void (*cq_iterate_fn)(void *, bool (^)(void *));
typedef const char *(*co_get_path_fn)(void *);

// The container manager can list containers directly (instant, no scan). On
// releases where it answers this app only with its own containers, the list
// has no other apps and the fsgetpath scan is used instead. Classes are not
// relied on: every class is asked and paths are sorted by their parent.
static NSDictionary<NSString *, NSArray<NSString *> *> *cl_mcm_list_containers(NSArray<NSString *> *roots, NSString **summary)
{
    NSMutableDictionary<NSString *, NSMutableSet<NSString *> *> *found = [NSMutableDictionary new];
    for (NSString *root in roots) found[root] = [NSMutableSet new];
    NSMutableArray *perClass = [NSMutableArray new];
    void *mgr = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW | RTLD_LOCAL);
    if (!mgr) { *summary = @"container manager unavailable"; return nil; }
    cq_create_fn create = (cq_create_fn)dlsym(mgr, "container_query_create");
    cq_set_u64_fn setClass = (cq_set_u64_fn)dlsym(mgr, "container_query_set_class");
    cq_iterate_fn iterate = (cq_iterate_fn)dlsym(mgr, "container_query_iterate_results_sync");
    cq_free_fn freeQuery = (cq_free_fn)dlsym(mgr, "container_query_free");
    co_get_path_fn getPath = (co_get_path_fn)dlsym(mgr, "container_object_get_path");
    if (!create || !setClass || !iterate || !freeQuery || !getPath) {
        dlclose(mgr);
        *summary = @"container manager query unavailable";
        return nil;
    }
    for (uint64_t cls = 1; cls <= 14; cls++) {
        void *query = create();
        if (!query) continue;
        __block NSUInteger count = 0;
        setClass(query, cls);
        @try {
            iterate(query, ^bool(void *object) {
                const char *path = object ? getPath(object) : NULL;
                if (!path || !path[0]) return true;
                count++;
                NSString *norm = cl_norm([NSString stringWithUTF8String:path] ?: @"");
                NSString *parent = norm.stringByDeletingLastPathComponent;
                [found[parent] addObject:norm];
                return true;
            });
        } @catch (NSException *exception) {
            cl_log(@"scan: container manager class %llu: %@", cls, exception.reason);
        }
        freeQuery(query);
        if (count) [perClass addObject:[NSString stringWithFormat:@"%llu:%lu", cls, (unsigned long)count]];
    }
    dlclose(mgr);
    NSMutableDictionary *result = [NSMutableDictionary new];
    for (NSString *root in roots) result[root] = [found[root].allObjects sortedArrayUsingSelector:@selector(compare:)];
    *summary = [NSString stringWithFormat:@"container manager: %lu apps, %lu extensions, %lu daemons (by class %@)",
                (unsigned long)[result[roots[0]] count], (unsigned long)[result[roots[1]] count],
                (unsigned long)[result[roots[2]] count], perClass.count ? [perClass componentsJoinedByString:@" "] : @"none"];
    return result;
}

// Samples ids across the volume. On some releases fsgetpath resolves only the
// caller's own files; then a full scan takes minutes and finds nothing.
static BOOL cl_fsgetpath_sees_others(fsid_t fsid, int64_t maxInode)
{
    NSMutableArray<NSString *> *own = [NSMutableArray arrayWithObject:cl_norm(NSHomeDirectory())];
    NSString *bundle = cl_norm(NSBundle.mainBundle.bundlePath.stringByDeletingLastPathComponent);
    if (bundle.length) [own addObject:bundle];
    NSString *group = cl_app_group();
    NSURL *groupURL = group ? [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:group] : nil;
    if (groupURL.path.length) [own addObject:cl_norm(groupURL.path)];
    int64_t stride = MAX((int64_t)1, maxInode / 20000);
    NSUInteger sampled = 0, resolved = 0, foreign = 0;
    NSCountedSet<NSString *> *areas = [NSCountedSet new];
    char buf[1200];
    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    for (int64_t ino = 1 + (int64_t)arc4random_uniform((uint32_t)MIN(stride, (int64_t)UINT32_MAX)); ino <= maxInode; ino += stride) {
        sampled++;
        fsid_t id = fsid;
        if (fsgetpath(buf, sizeof(buf), &id, (uint64_t)ino) <= 0) continue;
        resolved++;
        NSString *path = [NSString stringWithUTF8String:buf];
        BOOL mine = NO;
        for (NSString *prefix in own) if ([path hasPrefix:prefix]) { mine = YES; break; }
        if (!mine) {
            foreign++;
            [areas addObject:cl_sample_area(path)];
        }
    }
    cl_log(@"scan: fsgetpath sample: %lu of %lu ids resolve, %lu outside Cleaner (ids up to %lld, %.1f s)",
           (unsigned long)resolved, (unsigned long)sampled, (unsigned long)foreign, (long long)maxInode,
           CFAbsoluteTimeGetCurrent() - started);
    if (areas.count) {
        NSArray *top = [areas.allObjects sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            NSUInteger ca = [areas countForObject:a], cb = [areas countForObject:b];
            return ca > cb ? NSOrderedAscending : ca < cb ? NSOrderedDescending : [a compare:b];
        }];
        NSMutableArray *parts = [NSMutableArray new];
        for (NSString *area in [top subarrayWithRange:NSMakeRange(0, MIN(top.count, (NSUInteger)12))])
            [parts addObject:[NSString stringWithFormat:@"%@ x%lu", area, (unsigned long)[areas countForObject:area]]];
        cl_log(@"scan: resolvable areas: %@", [parts componentsJoinedByString:@", "]);
    }
    return foreign > 0;
}

static NSArray<NSString *> *(*gCLContainerListProvider)(NSString *storeHint);

void cl_set_container_list_provider(NSArray<NSString *> *(*provider)(NSString *storeHint))
{
    gCLContainerListProvider = provider;
}

static BOOL cl_is_ls_store_name(const char *path)
{
    const char *name = strrchr(path, '/');
    name = name ? name + 1 : path;
    size_t len = strlen(name);
    return len > 33 && strncmp(name, "com.apple.LaunchServices-", 25) == 0 && strcmp(name + len - 8, ".csstore") == 0;
}

// The LaunchServices database is rewritten on every app install or update, so
// its id is among the newest: scan down from the top and stop at the first.
static NSString *cl_scan_for_ls_store(fsid_t fsid, int64_t maxInode, qos_class_t qos, CLScanProgress progress)
{
    const int64_t chunk = 32768;
    int64_t chunks = (maxInode + chunk - 1) / chunk;
    __block int64_t nextChunk = 0, done = 0;
    __block NSString *found = nil;
    NSLock *lock = [NSLock new];
    CLScanCancellation *stop = [CLScanCancellation new];
    NSUInteger cores = NSProcessInfo.processInfo.activeProcessorCount;
    size_t workers = (size_t)MAX((NSUInteger)1, MIN((NSUInteger)4, cores / 2));
    dispatch_apply(workers, dispatch_get_global_queue(qos, 0), ^(size_t __unused w) {
        fsid_t id = fsid;
        char buf[1200];
        NSUInteger none[8] = {0};
        for (;;) {
            if (stop.isCancelled) return;
            [lock lock];
            int64_t c = nextChunk++;
            [lock unlock];
            if (c >= chunks) return;
            int64_t last = maxInode - c * chunk, first = MAX((int64_t)1, last - chunk + 1);
            for (int64_t ino = last; ino >= first; ino--) {
                if ((ino & 127) == 0 && stop.isCancelled) return;
                if (fsgetpath(buf, sizeof(buf), &id, (uint64_t)ino) <= 0 || !cl_is_ls_store_name(buf)) continue;
                [lock lock];
                if (!found) found = [NSString stringWithUTF8String:buf];
                [lock unlock];
                [stop cancel];
                return;
            }
            [lock lock];
            done += last - first + 1;
            int64_t nowDone = done;
            [lock unlock];
            if (progress && !stop.isCancelled) progress(nowDone, maxInode, none);
        }
    });
    return found;
}

// iOS 26: the App Data and Extensions lists from the LaunchServices database.
static NSDictionary<NSString *, NSArray<NSString *> *> *cl_containers_from_ls_store(NSArray<NSString *> *roots, fsid_t fsid,
                                                                                   qos_class_t qos, CLScanProgress progress)
{
    if (!gCLContainerListProvider) return nil;
    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    NSArray<NSString *> *paths = gCLContainerListProvider(nil);
    NSString *how = @"remembered location";
    if (paths.count < 2) {
        int64_t probeInode = 0;
        int64_t maxInode = cl_volume_max_inode(fsid, &probeInode);
        if (maxInode <= 0) return nil;
        NSString *store = cl_scan_for_ls_store(fsid, maxInode, qos, progress);
        if (!store) {
            cl_log(@"scan: no LaunchServices database found by id (%.1f s)", CFAbsoluteTimeGetCurrent() - started);
            return nil;
        }
        paths = gCLContainerListProvider(store);
        how = [NSString stringWithFormat:@"found by id in %.1f s", CFAbsoluteTimeGetCurrent() - started];
        if (paths.count < 2) {
            cl_log(@"scan: the LaunchServices database at %@ lists no containers", store);
            return nil;
        }
    }
    NSMutableDictionary<NSString *, NSMutableArray *> *byRoot = [NSMutableDictionary new];
    for (NSString *root in roots) byRoot[root] = [NSMutableArray new];
    for (NSString *path in paths) [byRoot[cl_norm(path).stringByDeletingLastPathComponent] addObject:cl_norm(path)];
    if ([byRoot[roots[0]] count] < 2) return nil;
    NSMutableDictionary *result = [NSMutableDictionary new];
    for (NSString *root in roots) result[root] = [byRoot[root] sortedArrayUsingSelector:@selector(compare:)];
    cl_log(@"scan: %lu apps, %lu extensions from the LaunchServices database (%@); daemon containers aren't listed there",
           (unsigned long)[result[roots[0]] count], (unsigned long)[result[roots[1]] count], how);
    return result;
}


// inodeOnly: skip the container manager and LaunchServices shortcuts and scan
// ids (iOS 26 Internal Daemons, which no database lists).
static NSDictionary<NSString *, NSArray<NSString *> *> *cl_run_shared_scan(fsid_t fsid, qos_class_t qos, BOOL inodeOnly)
{
    NSArray<NSString *> *roots = cl_shared_scan_roots();
    if (inodeOnly) goto inodeScan;
    {
    NSString *mcmSummary = nil;
    NSDictionary<NSString *, NSArray<NSString *> *> *listed = cl_mcm_list_containers(roots, &mcmSummary);
    cl_log(@"scan: %@", mcmSummary);
    // Other apps' containers listed: no scan needed. A list with only this
    // app's own container is not enough.
    if ([listed[roots[0]] count] > 1) return listed;
    NSString *lsSummary = nil;
    NSDictionary<NSString *, NSArray<NSString *> *> *lsListed = cl_lsapi_list_containers(roots, &lsSummary);
    cl_log(@"scan: %@", lsSummary);
    if (!cl_system_areas_reachable() && [lsListed[roots[0]] count] > 1) {
        // The API doesn't list daemon containers; those still need the scan
        // on releases where it works, so only skip it when apps are covered.
        NSMutableDictionary *merged = [lsListed mutableCopy];
        if (![merged[roots[2]] count]) merged[roots[2]] = @[];
        return merged;
    }
    if (!cl_system_areas_reachable()) {
        // A full scan of a well-used iOS 26 device is 100+ million ids
        // (about 40 minutes); the database lists the same containers.
        CLScanProgress report = ^(int64_t done, int64_t total, const NSUInteger *__unused counts) {
            void (^progress)(int64_t, int64_t, NSUInteger) = nil;
            @synchronized (gCLSharedScanGuard) { progress = gCLScanProgress; }
            if (progress) progress(done, total, 0);
        };
        NSDictionary *fromStore = cl_containers_from_ls_store(roots, fsid, qos, report);
        if (fromStore) return fromStore;
    }
    }
inodeScan:;
    int64_t probeInode = 0;
    int64_t maxInode = cl_volume_max_inode(fsid, &probeInode);
    if (maxInode <= 0) {
        cl_log(@"enumerate containers: dynamic inode limit unavailable; refusing to present a fixed-range partial scan as complete");
        return nil;
    }
    if (maxInode > INT64_MAX - 32768) {
        cl_log(@"enumerate containers: inode bound is too large to scan safely");
        return nil;
    }
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSString *whyFull = nil;
    NSDictionary *cache = cl_scan_cache_load(fsid, probeInode, now, &whyFull);
    int64_t firstId = 1;
    NSTimeInterval fullAt = now;
    NSUInteger dropped = 0;
    NSMutableArray<NSMutableDictionary<NSString *, NSNumber *> *> *known = [NSMutableArray new];
    for (NSString *root in roots) {
        [known addObject:cache ? cl_scan_verify(fsid, cache[@"roots"][root], &dropped) : [NSMutableDictionary new]];
    }
    if (cache) {
        firstId = [cache[@"probe"] longLongValue] + 1;
        fullAt = [cache[@"fullAt"] doubleValue];
    }
    if (!cache && !cl_fsgetpath_sees_others(fsid, maxInode)) {
        cl_log(@"scan: on this iOS version fsgetpath only resolves Cleaner own files, so containers can't be found by scanning");
        return nil;
    }
    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    CLScanProgress report = ^(int64_t done, int64_t total, const NSUInteger *counts) {
        void (^progress)(int64_t, int64_t, NSUInteger) = nil;
        NSUInteger index = 0;
        @synchronized (gCLSharedScanGuard) { progress = gCLScanProgress; index = gCLScanProgressIndex; }
        if (progress) progress(done, total, (index < roots.count ? known[index].count : 0) + (index < 8 ? counts[index] : 0));
    };
    NSArray *lists = cl_scan_children(fsid, firstId, maxInode, roots, nil, qos, report);
    if (!lists) return nil;
    NSMutableDictionary *saved = [NSMutableDictionary new];
    NSMutableDictionary *scan = [NSMutableDictionary new];
    for (NSUInteger i = 0; i < roots.count; i++) {
        [known[i] addEntriesFromDictionary:lists[i]];
        saved[roots[i]] = known[i];
        scan[roots[i]] = cl_sorted_paths(known[i]);
    }
    double seconds = CFAbsoluteTimeGetCurrent() - started;
    int64_t ids = maxInode >= firstId ? maxInode - firstId + 1 : 0;
    cl_log(@"scan: %@ ids %lld-%lld (%lld ids) in %.1f s (%.0f ids/s, %@); %lu apps, %lu extensions, %lu daemons%@",
           cache ? @"new" : [NSString stringWithFormat:@"full (%@)", whyFull ?: @"no saved scan"],
           (long long)firstId, (long long)maxInode, (long long)ids, seconds, seconds > 0 ? ids / seconds : 0,
           qos == QOS_CLASS_USER_INITIATED ? @"foreground" : @"background",
           (unsigned long)known[0].count, (unsigned long)known[1].count, (unsigned long)known[2].count,
           dropped ? [NSString stringWithFormat:@"; %lu removed since the last scan", (unsigned long)dropped] : @"");
    cl_check_scan_completion(fsid, probeInode, @"containers");
    cl_scan_cache_save(fsid, probeInode, fullAt, saved);
    return scan;
}

// One scan per slot runs at a time. On iOS 26 the Internal Daemons id scan
// (most of an hour the first time) has its own slot, so the lists that come
// from the LaunchServices database never wait for it.
@interface CLScanSlot : NSObject
@property (nonatomic, copy) NSDictionary<NSString *, NSArray<NSString *> *> *scan;
@property (nonatomic) NSTimeInterval at;
@property (nonatomic, strong) dispatch_group_t group;
@property (nonatomic, strong) NSMutableDictionary *box;
@end
@implementation CLScanSlot
@end

static CLScanSlot *cl_scan_slot(BOOL inode)
{
    static CLScanSlot *slots[2];
    static dispatch_once_t once;
    dispatch_once(&once, ^{ slots[0] = [CLScanSlot new]; slots[1] = [CLScanSlot new]; });
    return slots[inode ? 1 : 0];
}

static void cl_scan_slots_clear(void)
{
    for (int i = 0; i < 2; i++) {
        CLScanSlot *slot = cl_scan_slot(i == 1);
        slot.scan = nil;
        slot.at = 0;
    }
}

static NSArray<NSString *> *cl_shared_children(NSString *base, fsid_t fsid, CLScanCancellation *cancellation,
                                               void (^progress)(int64_t, int64_t, NSUInteger))
{
    cl_shared_scan_setup();
    NSUInteger baseIndex = [cl_shared_scan_roots() indexOfObject:base];
    // iOS 26 lists apps and extensions from the LaunchServices database; only
    // Internal Daemons need the (long) id scan.
    BOOL inodeOnly = !cl_system_areas_reachable() && [base isEqualToString:@"/private/var/mobile/Containers/Data/InternalDaemon"];
    CLScanSlot *slot = cl_scan_slot(inodeOnly);
    id owner = [NSObject new];
    dispatch_group_t group = nil;
    NSMutableDictionary *box = nil;
    @synchronized (gCLSharedScanGuard) {
        if (slot.scan && NSDate.date.timeIntervalSinceReferenceDate - slot.at < kCLSharedScanTTL) {
            NSArray *cached = slot.scan[base];
            if (progress) progress(1, 1, cached.count);
            return cached;
        }
        if (progress) {
            gCLScanProgress = [progress copy];
            gCLScanProgressIndex = baseIndex;
            gCLScanProgressOwner = owner;
        }
        if (!slot.group) {
            // A screen waiting for the result gets foreground priority; the
            // worker count stays at half the cores either way.
            qos_class_t qos = progress ? QOS_CLASS_USER_INITIATED : QOS_CLASS_UTILITY;
            dispatch_group_t started = dispatch_group_create();
            NSMutableDictionary *startedBox = [NSMutableDictionary new];
            slot.group = started;
            slot.box = startedBox;
            dispatch_group_enter(started);
            dispatch_async(dispatch_get_global_queue(qos, 0), ^{
                NSDictionary *scan = nil;
                @try {
                    scan = cl_run_shared_scan(fsid, qos, inodeOnly);
                } @catch (NSException *exception) {
                    cl_log(@"scan: exception %@", exception.reason);
                }
                @synchronized (gCLSharedScanGuard) {
                    if (scan) {
                        startedBox[@"scan"] = scan;
                        slot.scan = scan;
                        slot.at = NSDate.date.timeIntervalSinceReferenceDate;
                    }
                    slot.group = nil;
                    slot.box = nil;
                }
                dispatch_group_leave(started);
            });
        }
        group = slot.group;
        box = slot.box;
    }
    BOOL cancelled = NO;
    while (dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC)) != 0) {
        if (cancellation.isCancelled) { cancelled = YES; break; }
    }
    NSArray<NSString *> *result = nil;
    @synchronized (gCLSharedScanGuard) {
        if (gCLScanProgressOwner == owner) { gCLScanProgress = nil; gCLScanProgressOwner = nil; }
        if (!cancelled) result = box[@"scan"][base];
    }
    return result;
}

NSArray<NSString *> *cl_enumerate(NSString *dir, int64_t maxInode, CLScanCancellation *cancellation,
                                  void (^progress)(int64_t, int64_t, NSUInteger))
{
    if (cancellation.isCancelled) return nil;
    NSString *base = cl_norm(dir);  // /private/var/... form
    struct stat baseStat = {0};
    int baseError = lstat(base.fileSystemRepresentation, &baseStat);
    if (baseError == 0 && !S_ISDIR(baseStat.st_mode)) {
        cl_log(@"enumerate %@: base is not a directory", dir);
        return nil;
    }
    if (baseError != 0 && errno != EACCES && errno != EPERM) {
        cl_log(@"enumerate %@: base is missing (%@)", dir, cl_errno(errno));
        return nil;
    }
    struct statfs sfs;
    if (statfs(base.fileSystemRepresentation, &sfs) != 0) {
        // The container parent may not even be stat-able without a token. In
        // that case fall back to the data volume's fsid and let fsgetpath do
        // the work; a denied parent is not the same thing as a missing parent.
        if (statfs("/private/var/mobile", &sfs) != 0) {
            cl_log(@"enumerate %@: statfs failed (%@)", dir, cl_errno(errno));
            return nil;
        }
    }
    fsid_t fsid = sfs.f_fsid;
    BOOL dynamicBound = maxInode <= 0;
    if (dynamicBound && [cl_shared_scan_roots() containsObject:base])
        return cl_shared_children(base, fsid, cancellation, progress);
    // iOS 26: a full scan takes about 40 minutes; the LaunchServices database
    // lists the group containers of installed apps.
    if (dynamicBound && !cl_system_areas_reachable() && gCLContainerListProvider &&
        [base isEqualToString:@"/private/var/mobile/Containers/Shared/AppGroup"]) {
        NSArray<NSString *> *all = gCLContainerListProvider(nil);
        if (all.count) {
            NSMutableArray *groups = [NSMutableArray new];
            for (NSString *path in all)
                if ([cl_norm(path).stringByDeletingLastPathComponent isEqualToString:base]) [groups addObject:cl_norm(path)];
            [groups sortUsingSelector:@selector(compare:)];
            cl_log(@"enumerate %@: %lu group containers from the LaunchServices database", dir, (unsigned long)groups.count);
            if (progress) progress(1, 1, groups.count);
            return groups;
        }
    }
    int64_t probeInode = 0;
    if (dynamicBound) {
        maxInode = cl_volume_max_inode(fsid, &probeInode);
        if (maxInode <= 0) {
            cl_log(@"enumerate %@: dynamic inode limit unavailable; refusing to present a fixed-range partial scan as complete", dir);
            return nil;
        }
    }
    if (maxInode > INT64_MAX - 32768) {
        cl_log(@"enumerate %@: inode bound is too large to scan safely", dir);
        return nil;
    }
    NSArray *lists = cl_scan_children(fsid, 1, maxInode, @[base], cancellation, QOS_CLASS_USER_INITIATED,
        progress ? ^(int64_t done, int64_t total, const NSUInteger *counts) { progress(done, total, counts[0]); } : nil);
    if (!lists) return nil;
    if (dynamicBound) cl_check_scan_completion(fsid, probeInode, dir);
    return cl_sorted_paths(lists.firstObject);
}

