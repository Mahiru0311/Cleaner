//
//  CLGrant.m
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

#pragma mark - Log

#ifdef CL_ACCESS_TESTING
void (^cl_test_tree_hook)(NSString *stage, NSString *path);
static NSString *cl_test_backup_root;
static NSString *cl_test_app_backup_root;
#endif

static NSMutableString *gLog;
static NSLock *gLogLock;

void cl_log(NSString *format, ...)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gLog = [NSMutableString new]; gLogLock = [NSLock new]; });
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[wqfiles] %@", line);
    [gLogLock lock];
    [gLog appendFormat:@"%@\n", line];
    [gLogLock unlock];
}

NSString *cl_log_text(void)
{
    [gLogLock lock];
    NSString *text = [gLog copy] ?: @"";
    [gLogLock unlock];
    return text;
}

NSString *cl_errno(int err) { return [NSString stringWithFormat:@"%s (errno %d)", strerror(err), err]; }

#pragma mark - App group

typedef struct __SecTask *SecTaskRef;
extern SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator);
extern CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement, CFErrorRef *error);

NSString *cl_app_group(void)
{
    static NSString *group;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *groups = nil;
        SecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
        if (task) {
            CFTypeRef value = SecTaskCopyValueForEntitlement(task, CFSTR("com.apple.security.application-groups"), NULL);
            if (value) groups = (__bridge_transfer NSArray *)value;
            CFRelease(task);
        }
        for (id candidate in groups) {
            if (![candidate isKindOfClass:NSString.class]) continue;
            NSURL *root = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:candidate];
            if (root) {
                group = candidate;
                if (!CLRecoverSwapAtPath([root.path stringByAppendingPathComponent:@"Library"]))
                    cl_log(@"App-group cache recovery requires attention; preserved contents retained: %@ (%@)", root.path, cl_errno(errno));
                break;
            }
        }
        cl_log(@"App group: %@ (entitled: %@)", group ?: @"NONE",
               groups.count ? [groups componentsJoinedByString:@", "] : @"none");
    });
    return group;
}

#pragma mark - worse_query

typedef void *(*cq_create_fn)(void);
typedef void (*cq_set_u64_fn)(void *, uint64_t);
typedef void (*cq_set_ids_fn)(void *, xpc_object_t);
typedef void *(*cq_result_fn)(void *);
typedef void (*cq_free_fn)(void *);
typedef char *(*cq_token_fn)(void *);
typedef int64_t (*ext_consume_fn)(const char *);
// The callback returns true to continue; a void block leaves that value undefined.
typedef void (*cq_iterate_fn)(void *, bool (^)(void *));
typedef const char *(*co_get_path_fn)(void *);
typedef const char *(*co_get_id_fn)(void *);

static void cl_release_handle(int64_t handle);

static int64_t cl_query_token(NSString *group, BOOL altFlags)
{
    static void *mgr;
    static cq_create_fn create;
    static cq_set_u64_fn setClass, setFlags, setPart;
    static cq_set_ids_fn setGroups;
    static cq_result_fn single;
    static cq_free_fn freeQuery;
    static cq_token_fn copyToken;
    static ext_consume_fn consume;
    if (!mgr) {
        mgr = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW | RTLD_LOCAL);
        if (!mgr) return -2;
        create = (cq_create_fn)dlsym(mgr, "container_query_create");
        setClass = (cq_set_u64_fn)dlsym(mgr, "container_query_set_class");
        setGroups = (cq_set_ids_fn)dlsym(mgr, "container_query_set_group_identifiers");
        setFlags = (cq_set_u64_fn)dlsym(mgr, "container_query_operation_set_flags");
        setPart = (cq_set_u64_fn)dlsym(mgr, "container_query_operation_set_part");
        single = (cq_result_fn)dlsym(mgr, "container_query_get_single_result");
        freeQuery = (cq_free_fn)dlsym(mgr, "container_query_free");
        copyToken = (cq_token_fn)dlsym(mgr, "container_copy_sandbox_token");
        consume = (ext_consume_fn)dlsym(RTLD_DEFAULT, "sandbox_extension_consume");
    }
    if (!create || !setClass || !setGroups || !setFlags || !setPart || !single || !freeQuery || !copyToken || !consume) return -2;

    void *query = create();
    if (!query) return -3;
    char *token = NULL;
    @try {
        setClass(query, 7);  // app group container
        xpc_object_t ident = xpc_string_create(group.UTF8String);
        setGroups(query, ident);
        setPart(query, 3);   // Library/Caches
        setFlags(query, altFlags ? 0x0000000800000000ULL : 0x0000008000000000ULL);
        void *result = single(query);
        token = result ? copyToken(result) : NULL;
        int64_t handle = token ? consume(token) : (result ? -6 : -5);
        return token && handle < 0 ? -7 : handle;
    } @finally {
        if (token) free(token);
        freeQuery(query);
    }
}

BOOL cl_system_areas_reachable(void)
{
    // worse_query reaches System Data, the system groups and the App Groups
    // parent only on iOS 27; on iOS 26 it reaches the individual app,
    // extension, daemon and app group containers.
    return NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27;
}

static int64_t cl_query(NSString *target, BOOL altFlags)
{
    NSString *group = cl_app_group();
    if (!group) return -1;
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *root = [files containerURLForSecurityApplicationGroupIdentifier:group];
    if (!root) return -1;
    NSString *libraryPath = [root.path stringByAppendingPathComponent:@"Library"];
    if (![files createDirectoryAtPath:libraryPath withIntermediateDirectories:YES attributes:nil error:nil]) return -4;
    int library = CLOpenDirectoryNoLinks(libraryPath);
    if (library < 0) return -4;
    int lock = CLOpenRegularAt(library, ".wq-caches-lock", O_RDWR | O_CREAT, 0600);
    if (lock < 0 || flock(lock, LOCK_EX | LOCK_NB) != 0) {
        if (lock >= 0) close(lock);
        close(library);
        return -4;
    }
    int64_t handle = -4;
    @try {
        // Keep the exact Caches swap point required by worse_query, but preserve
        // its original inode and nested contents. Next acquisition recovers an
        // interrupted swap from the durable marker, before doing another query.
        if (CLSwapBegin(library, target)) handle = cl_query_token(group, altFlags);
    } @catch (NSException *exception) {
        cl_log(@"token query exception: %@", exception.reason);
        handle = -9;
    } @finally {
        if (!CLSwapRecover(library)) {
            cl_log(@"token cache recovery failed: %@; preserved contents retained", libraryPath);
            if (handle >= 0) cl_release_handle(handle);
            handle = -8;
        }
        close(lock);
        close(library);
    }
    return handle;
}

static NSMutableDictionary<NSString *, NSNumber *> *gCLGrants;
static NSMutableArray<NSString *> *gCLGrantOrder;   // oldest first
// The kernel limits how many sandbox extensions a process may hold. Keep a
// bounded working set and release the oldest; released paths are simply
// granted again when they are next used.
static const NSUInteger kCLMaxGrants = 192;

static void cl_release_handle(int64_t handle)
{
    typedef int (*ext_release_fn)(int64_t);
    static ext_release_fn release;
    if (!release) release = (ext_release_fn)dlsym(RTLD_DEFAULT, "sandbox_extension_release");
    if (release && handle >= 0) release(handle);
}
static NSRecursiveLock *gCLGrantLock;

NSString *cl_norm(NSString *path)
{
    NSString *p = path.stringByStandardizingPath;
    if ([p hasPrefix:@"/var/"]) p = [@"/private" stringByAppendingString:p];
    return p;
}

// Whether the target can now be opened. Only a sandbox denial (EPERM) counts
// as "the token didn't help": EACCES is ordinary file permissions (root-owned
// system containers), which a token never changes.
static BOOL cl_grant_opens(NSString *path)
{
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd >= 0) { close(fd); return YES; }
    return errno != EPERM;
}

BOOL cl_grant(NSString *path)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gCLGrants = [NSMutableDictionary new];
        gCLGrantOrder = [NSMutableArray new];
        gCLGrantLock = [NSRecursiveLock new];
    });
    NSString *key = cl_norm(path);
    [gCLGrantLock lock];
    NSNumber *known = gCLGrants[key];
    if (known) {
        [gCLGrantOrder removeObject:key];   // most recently used goes last
        [gCLGrantOrder addObject:key];
        [gCLGrantLock unlock];
        return YES;
    }
    while (gCLGrantOrder.count >= kCLMaxGrants) {
        NSString *oldest = gCLGrantOrder.firstObject;
        cl_release_handle(gCLGrants[oldest].longLongValue);
        [gCLGrants removeObjectForKey:oldest];
        [gCLGrantOrder removeObjectAtIndex:0];
    }
    struct stat st;
    if (lstat(key.fileSystemRepresentation, &st) != 0) {
        [gCLGrantLock unlock];
        return NO;  // worse_query needs an existing target
    }
    // iOS 26 needs the alternative query flags; try the likely ones first so
    // a grant costs one query, and the other set only when that fails. A
    // token can also be issued and consumed yet not open the target (seen on
    // 27.0.1 with an AltStore app group): check, and then try the other flags.
    // The set that works is remembered for the rest of the run.
    static int preferAlt = -1;
    BOOL altFirst = preferAlt >= 0 ? (BOOL)preferAlt : !cl_system_areas_reachable();
    int64_t handle = cl_query(key, altFirst);
    BOOL usedAlt = altFirst;
    if (handle >= 0 && !cl_grant_opens(key)) {
        static BOOL logged;
        if (!logged) {
            logged = YES;
            cl_log(@"grant: the token for %@ doesn't open it (%@ query flags); trying the other flags", key,
                   altFirst ? @"alternative" : @"standard");
        }
        cl_release_handle(handle);
        handle = -8;
    }
    if (handle < 0 && handle != -1 && handle != -2) {
        int64_t alt = cl_query(key, !altFirst);
        if (alt >= 0 && !cl_grant_opens(key)) {
            cl_release_handle(alt);
            alt = -8;
        }
        if (alt >= 0) {
            handle = alt;
            usedAlt = !altFirst;
        }
    }
    if (handle >= 0 && preferAlt != (int)usedAlt) {
        if (preferAlt >= 0 || usedAlt != !cl_system_areas_reachable())
            cl_log(@"grant: the %@ query flags work on this device", usedAlt ? @"alternative" : @"standard");
        preferAlt = usedAlt;
    }
    if (handle >= 0) {  // failures are retried next time
        gCLGrants[key] = @(handle);
        [gCLGrantOrder addObject:key];
    }
    [gCLGrantLock unlock];
    return handle >= 0;
}

BOOL cl_is_denied(int err) { return err == EPERM || err == EACCES; }

NSString *cl_backup_root(void)
{
#ifdef CL_ACCESS_TESTING
    if (cl_test_backup_root) return cl_test_backup_root;
#endif
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"Backups"];
}

NSString *cl_app_backup_root(void)
{
#ifdef CL_ACCESS_TESTING
    if (cl_test_app_backup_root) return cl_test_app_backup_root;
#endif
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"AppBackups"];
}

BOOL cl_is_backup_storage_path(NSString *path)
{
    NSString *original = CLCanonicalVarPath(path);
    NSMutableArray<NSString *> *roots = [NSMutableArray new];
    NSString *fileRoot = CLCanonicalVarPath(cl_backup_root());
    NSString *appRoot = CLCanonicalVarPath(cl_app_backup_root());
    if (fileRoot.length) [roots addObject:fileRoot];
    if (appRoot.length) [roots addObject:appRoot];
    for (NSString *root in roots) {
        if ([original isEqualToString:root] || [original hasPrefix:[root stringByAppendingString:@"/"]]) return YES;
    }
    return NO;
}

NSArray<NSString *> *cl_list(NSString *dir, NSString **errorText)
{
    NSError *error = nil;
    NSArray *items = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:&error];
    if (!items && cl_grant(dir)) items = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:&error];
    if (!items && errorText) *errorText = error.localizedDescription ?: @"Cannot list this folder";
    return items;
}

static int cl_open(NSString *path, int flags, mode_t mode)
{
    if (flags & O_TRUNC) { errno = EINVAL; return -1; }
    int fd = CLOpenRegularAt(AT_FDCWD, path.fileSystemRepresentation, flags, mode);
    if (fd >= 0 || !cl_is_denied(errno)) return fd;
    // The file's own folder first, then the file itself.
    if (cl_grant(path.stringByDeletingLastPathComponent)) {
        fd = CLOpenRegularAt(AT_FDCWD, path.fileSystemRepresentation, flags, mode);
        if (fd >= 0 || !cl_is_denied(errno)) return fd;
    }
    if (!(flags & O_CREAT) && cl_grant(path)) fd = CLOpenRegularAt(AT_FDCWD, path.fileSystemRepresentation, flags, mode);
    if (fd < 0) {
        // Say why: a sandbox refusal (EPERM) and plain Unix permissions
        // (EACCES: owner/mode don't allow it) need different fixes.
        int err = errno;
        struct stat st;
        BOOL have = lstat(path.fileSystemRepresentation, &st) == 0;
        cl_log(@"open %@ for %@ -> %@; file uid %d mode %o, we are uid %d", path,
               (flags & O_ACCMODE) == O_RDONLY ? @"reading" : @"writing", cl_errno(err),
               have ? (int)st.st_uid : -1, have ? (int)(st.st_mode & 07777) : 0, (int)getuid());
        errno = err;
    }
    return fd;
}

NSData *cl_read(NSString *path, NSUInteger maxBytes, NSString **errorText)
{
    int fd = cl_open(path, O_RDONLY, 0);
    if (fd < 0) {
        if (errorText) *errorText = cl_errno(errno);
        return nil;
    }
    NSMutableData *data = [NSMutableData new];
    uint8_t buf[65536];
    for (;;) {
        size_t want = sizeof(buf);
        if (maxBytes && data.length + want > maxBytes) want = maxBytes - data.length;
        if (want == 0) break;
        ssize_t n = read(fd, buf, want);
        if (n < 0) {
            if (errno == EINTR) continue;
            if (errorText) *errorText = cl_errno(errno);
            close(fd);
            return nil;
        }
        if (n == 0) break;
        [data appendBytes:buf length:(NSUInteger)n];
    }
    close(fd);
    return data;
}

NSString *cl_permission_hint(NSString *path, BOOL forWriting)
{
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) != 0) return nil;
    uid_t me = getuid();
    mode_t need = forWriting ? 2 : 4;   // w / r
    BOOL allowed = st.st_uid == me ? (st.st_mode >> 6 & need) != 0
                 : (st.st_gid == getgid() ? (st.st_mode >> 3 & need) != 0 : (st.st_mode & need) != 0);
    if (allowed) return nil;
    NSString *owner = st.st_uid == 0 ? @"root" : [NSString stringWithFormat:@"uid %d", (int)st.st_uid];
    return [NSString stringWithFormat:@"This file belongs to %@ (mode %o) and only its owner may %@ it. "
            "Cleaner reaches the folder, but runs as mobile (uid %d), so no app can %@ this file.",
            owner, st.st_mode & 07777, forWriting ? @"change" : @"read", (int)me, forWriting ? @"change" : @"open"];
}

static int cl_open_directory_flags(NSString *path, int flags)
{
    int fd = CLOpenDirectoryNoLinksFlags(path, flags);
    if (fd < 0 && cl_is_denied(errno) && cl_grant(path)) fd = CLOpenDirectoryNoLinksFlags(path, flags);
    return fd;
}

int cl_open_directory(NSString *path)
{
    return cl_open_directory_flags(path, O_RDONLY);
}

BOOL cl_stat(NSString *path, struct stat *st)
{
    if (lstat(path.fileSystemRepresentation, st) == 0) return YES;
    if (!cl_is_denied(errno)) return NO;
    if (cl_grant(path.stringByDeletingLastPathComponent) && lstat(path.fileSystemRepresentation, st) == 0) return YES;
    return NO;
}

static BOOL cl_directory_current(NSString *path, int fd)
{
    int current = CLOpenDirectoryNoLinksFlags(path, O_SEARCH);
    struct stat a, b;
    BOOL ok = current >= 0 && fstat(current, &a) == 0 && fstat(fd, &b) == 0 && CLSameObject(&a, &b);
    if (current >= 0) close(current);
    return ok;
}

static BOOL cl_sync_entry(int parent, NSString *name)
{
    struct stat st;
    if (fstatat(parent, name.fileSystemRepresentation, &st, AT_SYMLINK_NOFOLLOW) != 0) return NO;
    if (S_ISLNK(st.st_mode)) return YES;
    if (S_ISREG(st.st_mode)) {
        int fd = CLOpenRegularAt(parent, name.fileSystemRepresentation, O_RDONLY, 0);
        if (fd < 0) return NO;
        struct stat current;
        BOOL ok = fstat(fd, &current) == 0 && CLSameObject(&st, &current) && fsync(fd) == 0;
        close(fd); return ok;
    }
    if (!S_ISDIR(st.st_mode)) { errno = EINVAL; return NO; }
    int fd = openat(parent, name.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return NO;
    int listing = dup(fd);
    DIR *dir = listing >= 0 ? fdopendir(listing) : NULL;
    if (!dir) { if (listing >= 0) close(listing); close(fd); return NO; }
    BOOL ok = YES;
    for (;;) {
        errno = 0;
        struct dirent *entry = readdir(dir);
        if (!entry) { if (errno) ok = NO; break; }
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        NSString *child = [NSFileManager.defaultManager stringWithFileSystemRepresentation:entry->d_name length:strlen(entry->d_name)];
        if (!child || !cl_sync_entry(fd, child)) { ok = NO; break; }
    }
    if (closedir(dir) != 0) ok = NO;
    if (ok && fsync(fd) != 0) ok = NO;
    close(fd);
    return ok;
}

BOOL cl_copy_contents(NSString *srcDir, NSString *dstDir, NSString **errorText)
{
    srcDir = CLCanonicalVarPath(srcDir);
    dstDir = CLCanonicalVarPath(dstDir);
    if (!CLAbsolutePathGrammar(srcDir) || !CLAbsolutePathGrammar(dstDir) || [srcDir isEqual:dstDir] ||
        [srcDir hasPrefix:[dstDir stringByAppendingString:@"/"]] || [dstDir hasPrefix:[srcDir stringByAppendingString:@"/"]]) {
        if (errorText) *errorText = @"Source and destination trees overlap or have invalid paths";
        return NO;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    int source = cl_open_directory(srcDir);
    if (source < 0) { if (errorText) *errorText = cl_errno(errno); return NO; }
    int destination = CLCreateDirectoriesNoLinksMode(dstDir, 0755);
    if (destination < 0 && cl_is_denied(errno) && cl_grant(dstDir.stringByDeletingLastPathComponent))
        destination = CLCreateDirectoriesNoLinksMode(dstDir, 0755);
    struct stat srcStat, dstStat;
    if (destination < 0 || fstat(source, &srcStat) != 0 || fstat(destination, &dstStat) != 0 || CLSameObject(&srcStat, &dstStat)) {
        if (errorText) *errorText = @"Cannot safely open distinct source and destination folders";
        close(source); if (destination >= 0) close(destination); return NO;
    }
    NSError *error = nil;
    NSArray *children = [fm contentsOfDirectoryAtPath:srcDir error:&error];
    if (!children) {
        if (errorText) *errorText = error.localizedDescription ?: @"Cannot read the source folder";
        close(source); close(destination); return NO;
    }
    BOOL allOk = YES;
    NSString *firstFailure = nil;
    for (NSString *name in children) {
        if (!cl_directory_current(srcDir, source) || !cl_directory_current(dstDir, destination)) {
            allOk = NO; firstFailure = firstFailure ?: @"A copy root changed during copying"; break;
        }
        NSString *src = [srcDir stringByAppendingPathComponent:name];
        NSString *dst = [dstDir stringByAppendingPathComponent:name];
        NSString *stageName = [@".wq-copy-stage-" stringByAppendingString:NSUUID.UUID.UUIDString];
        NSString *stagePath = [dstDir stringByAppendingPathComponent:stageName];
        if (mkdirat(destination, stageName.fileSystemRepresentation, 0700) != 0) {
            allOk = NO; firstFailure = firstFailure ?: cl_errno(errno); continue;
        }
        int stage = openat(destination, stageName.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
        if (stage < 0) { allOk = NO; firstFailure = firstFailure ?: cl_errno(errno); continue; }
        NSString *newPath = [stagePath stringByAppendingPathComponent:@"New"];
        CL_TREE_HOOK(@"copyReady", src);
        NSError *copyError = nil;
        BOOL ok = cl_directory_current(stagePath, stage) && [fm copyItemAtPath:src toPath:newPath error:&copyError];
        if (!ok && cl_grant(src) && cl_directory_current(srcDir, source) && cl_directory_current(stagePath, stage)) {
            if (cl_remove_entry(stage, @"New", newPath, NULL, nil)) {
                NSError *retryError = nil;
                ok = [fm copyItemAtPath:src toPath:newPath error:&retryError];
                if (!ok) copyError = retryError ?: copyError;
            }
        }
        if (ok) ok = cl_sync_entry(stage, @"New") && fsync(stage) == 0;
        CL_TREE_HOOK(@"copyStaged", dst);
        if (ok) ok = cl_directory_current(srcDir, source) && cl_directory_current(dstDir, destination) && cl_directory_current(stagePath, stage);
        BOOL installed = NO;
        if (ok) {
            struct stat previous;
            BOOL exists = fstatat(destination, name.fileSystemRepresentation, &previous, AT_SYMLINK_NOFOLLOW) == 0;
            if (!exists && errno != ENOENT) ok = NO;
            if (ok) {
                // Swap retains the previous destination at stage/New until the
                // copy has completed and the new namespace has been flushed.
                installed = renameatx_np(stage, "New", destination, name.fileSystemRepresentation, exists ? RENAME_SWAP : RENAME_EXCL) == 0;
                ok = installed && fsync(destination) == 0 && fsync(stage) == 0;
            }
        }
        NSString *failure = ok ? nil : copyError.localizedDescription ?: cl_errno(errno);
        // Never erase the preserved destination if installation durability failed.
        BOOL cleaned = !installed || ok;
        if (cleaned) cleaned = cl_remove_entry(stage, @"New", newPath, NULL, nil);
        close(stage);
        if (cleaned) cleaned = unlinkat(destination, stageName.fileSystemRepresentation, AT_REMOVEDIR) == 0 && fsync(destination) == 0;
        if (!ok || !cleaned) {
            allOk = NO;
            NSString *message = cleaned ? failure : [NSString stringWithFormat:@"%@; staging/recovery contents retained at %@", failure ?: cl_errno(errno), stagePath];
            firstFailure = firstFailure ?: message;
            cl_log(@"copy: %@ -> %@: %@", src, dst, message);
        }
    }
    close(source); close(destination);
    if (errorText && !allOk) *errorText = firstFailure;
    cl_log(@"copy: %@ -> %@ (%lu items) %@", srcDir, dstDir, (unsigned long)children.count, allOk ? @"OK" : @"with errors");
    return allOk;
}

// Container-manager enumeration is a second, permission-independent way to
// map a container path to its identifier. The enumeration pattern is the one
// used by terminal_worse (GPL-3.0); no part-domain traversal is involved. The UUID xattr and the root-only
// metadata plist are the fast paths; this query is the fallback for devices
// or containers where either is unavailable. Paths and identifiers stay in a
// short-lived cache because labels are requested for every row.
static NSDictionary<NSString *, NSString *> *cl_container_identifier_map(void)
static NSDictionary<NSString *, NSString *> *cl_container_identifier_map(void)
{
    static NSObject *lock;
    static NSDictionary<NSString *, NSString *> *cached;
    static NSTimeInterval cachedAt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    @synchronized (lock) {
        NSTimeInterval now = NSDate.date.timeIntervalSinceReferenceDate;
        if (cached && now - cachedAt < 60) return cached;

        NSMutableDictionary<NSString *, NSString *> *map = [NSMutableDictionary new];
        void *mgr = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW | RTLD_LOCAL);
        if (mgr) {
            cq_create_fn create = (cq_create_fn)dlsym(mgr, "container_query_create");
            cq_set_u64_fn setClass = (cq_set_u64_fn)dlsym(mgr, "container_query_set_class");
            cq_iterate_fn iterate = (cq_iterate_fn)dlsym(mgr, "container_query_iterate_results_sync");
            cq_free_fn freeQuery = (cq_free_fn)dlsym(mgr, "container_query_free");
            co_get_path_fn getPath = (co_get_path_fn)dlsym(mgr, "container_object_get_path");
            co_get_id_fn getIdentifier = (co_get_id_fn)dlsym(mgr, "container_object_get_identifier");
            if (!getIdentifier) getIdentifier = (co_get_id_fn)dlsym(mgr, "container_result_get_identifier");
            if (create && setClass && iterate && freeQuery && getPath) {
                const uint64_t classes[] = { 0, 2, 5, 7, 8, 10, 11, 13 };
                for (size_t i = 0; i < sizeof(classes) / sizeof(classes[0]); i++) {
                    void *query = create();
                    if (!query) continue;
                    setClass(query, classes[i]);
                    iterate(query, ^bool(void *object) {
                        if (!object) return true;
                        const char *path = getPath(object);
                        const char *ident = getIdentifier ? getIdentifier(object) : NULL;
                        if (!path || !path[0] || !ident || !ident[0]) return true;
                        NSString *p = [NSString stringWithUTF8String:path];
                        NSString *v = [NSString stringWithUTF8String:ident];
                        if (!p.length || !v.length) return true;
                        NSString *key = CLCanonicalVarPath(p);
                        if (key.length && !map[key]) map[key] = v;
                        return true;
                    });
                    freeQuery(query);
                }
            }
            dlclose(mgr);
        }
        cached = map;
        cachedAt = now;
        return cached;
    }
}

static NSString *(*gCLContainerLabelResolver)(NSString *path);

void cl_set_container_label_resolver(NSString *(*resolver)(NSString *path))
{
    gCLContainerLabelResolver = resolver;
}

NSString *cl_container_label(NSString *dir)
{
    char buf[512];
    ssize_t len = getxattr(dir.fileSystemRepresentation, "com.apple.containermanager.identifier", buf, sizeof(buf) - 1, 0, 0);
    if (len > 0) {
        buf[len] = 0;
        return [NSString stringWithUTF8String:buf];
    }
    // Reading the attribute can need a token on the container: ask, try again.
    if (cl_grant(dir)) {
        len = getxattr(dir.fileSystemRepresentation, "com.apple.containermanager.identifier", buf, sizeof(buf) - 1, 0, 0);
        if (len > 0) {
            buf[len] = 0;
            return [NSString stringWithUTF8String:buf];
        }
    }
    // Prefer the container-manager query over the metadata plist: it needs no
    // file permission and can also label containers whose plist is root-only.
    NSString *fromAPI = nil;
    @synchronized (NSNull.null) { fromAPI = gCLLSAPILabels[cl_norm(dir)]; }
    if (fromAPI.length) return fromAPI;
    NSString *queried = cl_container_identifier_map()[CLCanonicalVarPath(dir)];
    if (queried.length) return queried;
    // The LaunchServices database maps app and extension data containers to
    // bundle ids (set by the app; this file doesn't depend on that module).
    NSString *resolved = gCLContainerLabelResolver ? gCLContainerLabelResolver(CLCanonicalVarPath(dir)) : nil;
    if (resolved.length) return resolved;
    // The metadata plist is usually root-only (mode 600); only try it when the
    // owner and mode let this app read it, so the Log isn't flooded.
    NSString *meta = [dir stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
    if (cl_permission_hint(meta, NO)) return nil;
    NSData *data = cl_read(meta, 256 * 1024, NULL);
    if (!data) return nil;
    NSDictionary *plist = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:nil];
    id ident = [plist isKindOfClass:NSDictionary.class] ? plist[@"MCMMetadataIdentifier"] : nil;
    return [ident isKindOfClass:NSString.class] ? ident : nil;
}
