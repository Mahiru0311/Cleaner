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

// fd-based tree walk (v2.3). Every entry is fstatat(AT_SYMLINK_NOFOLLOW)
// off the parent's fd and every subdirectory is openat(O_NOFOLLOW) —
// nothing is ever resolved through a path string, so there is no window
// where a swapped symlink can redirect the walk (the WQFiles/NSFileManager
// enumerator in v2.2 walked by path and could descend into a symlinked
// directory, overcounting at best). Modelled on the fd traversal in
// YangJiiii/3105 (GPL-3.0, see docs/GITHUB-RESEARCH-v2.3.md): open/openat/
// fstatat/fdopendir/unlinkat, never follow links. topName is the first-level
// subdirectory name for the optional subdir accounting.
typedef struct {
    unsigned long long bytes;
    unsigned long long items;
    BOOL limited;
} CLMeasureAccum;

static void cl_measure_fd(int dirfd, NSString *path, CLScanCancellation *cancellation,
                          CLMeasureAccum *acc, NSString *topName, NSMutableDictionary *subdirs)
{
    int listing = dup(dirfd);
    if (listing < 0) { acc->limited = YES; return; }
    DIR *dir = fdopendir(listing);
    if (!dir) { close(listing); acc->limited = YES; return; }
    for (;;) {
        if (cancellation.isCancelled) break;
        errno = 0;
        struct dirent *entry = readdir(dir);
        if (!entry) { if (errno) acc->limited = YES; break; }
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        NSString *name = [NSFileManager.defaultManager stringWithFileSystemRepresentation:entry->d_name
                                                                                  length:strlen(entry->d_name)];
        if (!name) { acc->limited = YES; continue; }
        struct stat st;
        if (fstatat(dirfd, entry->d_name, &st, AT_SYMLINK_NOFOLLOW) != 0) { acc->limited = YES; continue; }
        if (S_ISREG(st.st_mode)) {
            acc->bytes += (unsigned long long)st.st_size;
            acc->items++;
            if (topName && subdirs) {
                NSNumber *old = subdirs[topName];
                subdirs[topName] = @([old unsignedLongLongValue] + (unsigned long long)st.st_size);
            }
        } else if (S_ISDIR(st.st_mode)) {
            NSString *childPath = [path stringByAppendingPathComponent:name];
            int child = openat(dirfd, entry->d_name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
            if (child < 0 && cl_is_denied(errno) && cl_grant(childPath))
                child = openat(dirfd, entry->d_name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
            if (child < 0) { acc->limited = YES; continue; }
            struct stat cst;
            if (fstat(child, &cst) != 0 || !CLSameObject(&st, &cst)) { close(child); acc->limited = YES; continue; }
            cl_measure_fd(child, childPath, cancellation, acc, topName ?: name, subdirs);
            close(child);
        }
        // Symlinks, sockets, devices, fifos: skipped, never followed.
    }
    closedir(dir);
}

CLMeasureResult cl_measure_tree_subdirs(NSString *dir, CLScanCancellation *cancellation, unsigned long long *bytes,
                                        NSArray<NSDictionary *> *_Nullable *_Nullable subdirsOut)
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
    // cl_open_directory opens with O_NOFOLLOW after an ancestry check and
    // grants access on denial — the fd walk's entry point.
    int fd = cl_open_directory(dir);
    if (fd < 0) {
        if (errno == ENOENT || errno == ENOTDIR) return CLMeasureResultMissing;
        return CLMeasureResultLimited;
    }
    NSMutableDictionary *subdirTotals = subdirsOut ? [NSMutableDictionary new] : nil;
    CLMeasureAccum acc = {0};
    cl_measure_fd(fd, dir, cancellation, &acc, nil, subdirTotals);
    close(fd);
    if (cancellation.isCancelled) return CLMeasureResultCancelled;
    if (bytes) *bytes = acc.bytes;
    if (subdirsOut) {
        NSArray *sorted = [subdirTotals keysSortedByValueUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
            return [b compare:a];
        }];
        NSMutableArray *top = [NSMutableArray new];
        for (NSString *name in [sorted subarrayWithRange:NSMakeRange(0, MIN(5, (long)sorted.count))]) {
            [top addObject:@{ @"name": name, @"bytes": subdirTotals[name] }];
        }
        *subdirsOut = [top copy];
    }
    return acc.limited ? CLMeasureResultLimited : CLMeasureResultKnown;
}

CLMeasureResult cl_measure_tree(NSString *dir, CLScanCancellation *cancellation, unsigned long long *bytes)
{
    return cl_measure_tree_subdirs(dir, cancellation, bytes, NULL);
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

// Per-folder cleaning (directory view swipe action) and custom cleaning
// (folder rules). The folder must be a real directory inside the container
// and must not be the container itself; the purge itself is the same
// fd-relative, no-follow removal as cl_purge_contents.
BOOL cl_purge_folder_contents(NSString *path, NSString *container, unsigned long long *freed,
                              NSString **reason)
{
    if (!path.length || !container.length) {
        if (reason) *reason = @"路径为空";
        return NO;
    }
    NSString *canon = CLSafetyCanonicalPath(path);
    NSString *canonContainer = CLSafetyCanonicalPath(container);
    if ([canon isEqualToString:canonContainer]) {
        if (reason) *reason = @"不能清空容器本身";
        return NO;
    }
    if (![canon hasPrefix:[canonContainer stringByAppendingString:@"/"]]) {
        if (reason) *reason = @"目标不在应用容器内";
        return NO;
    }
    if (!CLSafetyHasNoSymlinkAncestry(path, NO)) {
        if (reason) *reason = @"路径祖先不安全";
        return NO;
    }
    struct stat st = {0};
    if (lstat(path.fileSystemRepresentation, &st) != 0) {
        if (errno == ENOENT) { if (freed) *freed = 0; return YES; }
        if (reason) *reason = @"无法读取该文件夹";
        return NO;
    }
    if (!S_ISDIR(st.st_mode)) {
        if (reason) *reason = @"目标不是文件夹";
        return NO;
    }
    unsigned long long removed = 0;
    if (!cl_purge_contents_cancellable(path, &removed, nil)) {
        if (reason) *reason = @"清理失败，部分内容可能残留";
        return NO;
    }
    if (freed) *freed = removed;
    return YES;
}

// YES when a container-relative path is an excluded path itself or below
// one (excludes are folders: "Library/Caches/xxx" covers everything under it).
static BOOL cl_clean_match_excluded(NSString *relativePath, NSArray<NSString *> *excludes)
{
    for (NSString *ex in excludes) {
        if ([relativePath isEqualToString:ex] ||
            [relativePath hasPrefix:[ex stringByAppendingString:@"/"]]) return YES;
    }
    return NO;
}

typedef struct {
    NSArray<NSString *> *extensions;
    NSArray<NSString *> *names;
    NSArray<NSString *> *excludes;
    NSString *container;
    unsigned long long freed;
    NSUInteger failed;
    BOOL limited;
    // v2.4 filters (0 = no filter): only files older than minAgeSeconds,
    // and with minSize <= size <= maxSize (maxSize 0 = no maximum).
    NSTimeInterval minAgeSeconds;
    unsigned long long minSize;
    unsigned long long maxSize;
    NSTimeInterval now;  // Unix epoch, captured once at walk start
    BOOL dryRun;         // count + sample only, delete nothing
    NSUInteger matched;  // files matching pattern + filters
    unsigned long long matchedBytes;
    NSUInteger skipped;  // pattern-matched but filtered out by age/size
    NSMutableArray<NSString *> *sample;  // container-relative paths, capped at 50
    // v2.6: every failed / skipped file, listed with its reason, capped
    // at 50 each — a failure or skip is never silent.
    NSMutableArray<NSString *> *failedPaths;   // "rel/path · 删除失败" etc.
    NSMutableArray<NSString *> *skippedPaths;  // "rel/path · 太新" / "· 太小" / "· 太大"
    // v2.4 hardening: the container identity is re-checked immediately
    // before every delete — if the container was replaced mid-walk, the
    // walk stops instead of deleting from a different container.
    dev_t containerDevice;
    ino_t containerInode;
    BOOL containerIdentityKnown;
    BOOL stop;
} CLCleanMatch;

static void cl_clean_match_fd(int dirfd, NSString *path, NSString *container, CLCleanMatch *m,
                              CLScanCancellation *cancellation)
{
    int listing = dup(dirfd);
    if (listing < 0) { m->limited = YES; return; }
    DIR *dir = fdopendir(listing);
    if (!dir) { close(listing); m->limited = YES; return; }
    for (;;) {
        if (cancellation.isCancelled || m->stop) break;
        errno = 0;
        struct dirent *entry = readdir(dir);
        if (!entry) { if (errno) m->limited = YES; break; }
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        NSString *name = [NSFileManager.defaultManager stringWithFileSystemRepresentation:entry->d_name
                                                                                  length:strlen(entry->d_name)];
        if (!name) { m->limited = YES; continue; }
        NSString *childPath = [path stringByAppendingPathComponent:name];
        struct stat st;
        if (fstatat(dirfd, entry->d_name, &st, AT_SYMLINK_NOFOLLOW) != 0) {
            m->failed++;
            if (m->failedPaths.count < 50) {
                [m->failedPaths addObject:[NSString stringWithFormat:@"%@ · 无法读取",
                                           [childPath substringFromIndex:container.length + 1]]];
            }
            continue;
        }
        if (S_ISDIR(st.st_mode)) {
            NSString *rel = [childPath substringFromIndex:container.length + 1];
            if (cl_clean_match_excluded(rel, m->excludes)) continue;
            int child = openat(dirfd, entry->d_name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
            if (child < 0 && cl_is_denied(errno) && cl_grant(childPath))
                child = openat(dirfd, entry->d_name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
            if (child < 0) { m->failed++; continue; }
            struct stat cst;
            if (fstat(child, &cst) != 0 || !CLSameObject(&st, &cst)) { close(child); m->failed++; continue; }
            cl_clean_match_fd(child, childPath, container, m, cancellation);
            close(child);
            // Empty directories are left in place (harmless); only matching
            // files are deleted by extension/name rules.
        } else if (S_ISREG(st.st_mode)) {
            NSString *lower = name.lowercaseString;
            BOOL match = NO;
            for (NSString *ext in m->extensions) {
                // v2.6: exact extension match. The name must be LONGER
                // than the extension and end with it — a bare ".mp4"
                // dotfile is not an mp4 file, and ".mp4" never matches
                // ".mp4.bak" (no .mp4 suffix) or "xmp4" (no dot).
                // Case-insensitive: both sides lowercased.
                NSString *lext = ext.lowercaseString;
                if (lext.length && lower.length > lext.length && [lower hasSuffix:lext]) { match = YES; break; }
            }
            if (!match) {
                // Name-substring matching is case-insensitive too (both
                // sides lowercased) — documented, not accidental.
                for (NSString *sub in m->names) {
                    if (sub.length && [lower containsString:sub.lowercaseString]) { match = YES; break; }
                }
            }
            if (!match) continue;
            // v2.4 filters: a pattern match that is too new, too small or
            // too big is skipped (counted), not deleted and not an error.
            // v2.6: every skipped file is listed with its reason.
            NSString *relPath = [childPath substringFromIndex:container.length + 1];
            if (m->minAgeSeconds > 0) {
                NSTimeInterval mtime = (NSTimeInterval)st.st_mtimespec.tv_sec +
                    (NSTimeInterval)st.st_mtimespec.tv_nsec / 1000000000.0;
                if (mtime > m->now - m->minAgeSeconds) {
                    m->skipped++;
                    if (m->skippedPaths.count < 50) {
                        [m->skippedPaths addObject:[relPath stringByAppendingString:@" · 太新"]];
                    }
                    continue;
                }
            }
            if ((m->minSize > 0 && (unsigned long long)st.st_size < m->minSize) ||
                (m->maxSize > 0 && (unsigned long long)st.st_size > m->maxSize)) {
                m->skipped++;
                if (m->skippedPaths.count < 50) {
                    NSString *why = (m->minSize > 0 && (unsigned long long)st.st_size < m->minSize) ? @" · 太小" : @" · 太大";
                    [m->skippedPaths addObject:[relPath stringByAppendingString:why]];
                }
                continue;
            }
            // v2.4 hardening: re-validate the container identity
            // immediately before the delete.
            if (m->containerIdentityKnown) {
                struct stat cst;
                if (lstat(m->container.fileSystemRepresentation, &cst) != 0 ||
                    cst.st_dev != m->containerDevice || cst.st_ino != m->containerInode) {
                    m->failed++;
                    if (m->failedPaths.count < 50) {
                        [m->failedPaths addObject:[relPath stringByAppendingString:@" · 容器已变化，已停止"]];
                    }
                    m->limited = YES;
                    m->stop = YES;
                    return;
                }
            }
            struct stat cur;
            if (fstatat(dirfd, entry->d_name, &cur, AT_SYMLINK_NOFOLLOW) != 0 ||
                !CLSameObject(&st, &cur)) {
                m->failed++;
                if (m->failedPaths.count < 50) {
                    [m->failedPaths addObject:[relPath stringByAppendingString:@" · 文件已变化，跳过"]];
                }
                continue;
            }
            if (m->dryRun) {
                m->matched++;
                m->matchedBytes += (unsigned long long)st.st_size;
                if (m->sample && m->sample.count < 50) {
                    [m->sample addObject:[childPath substringFromIndex:m->container.length + 1]];
                }
                continue;
            }
            if (unlinkat(dirfd, entry->d_name, 0) == 0) {
                m->freed += (unsigned long long)st.st_size;
                m->matched++;
                m->matchedBytes += (unsigned long long)st.st_size;
                // v2.6: the sample is the matched set in BOTH modes — in
                // a dry-run it is "would delete", in a real run it is
                // "deleted" — so a test can prove preview set == delete
                // set instead of comparing only byte totals.
                if (m->sample && m->sample.count < 50) {
                    [m->sample addObject:[childPath substringFromIndex:m->container.length + 1]];
                }
            } else {
                m->failed++;
                if (m->failedPaths.count < 50) {
                    [m->failedPaths addObject:[relPath stringByAppendingString:@" · 删除失败"]];
                }
            }
        }
        // Links and special files: never followed, never deleted by a match rule.
    }
    closedir(dir);
}

// Filtered variant (v2.4): age/size filters, a subfolder scope (roots),
// dry-run preview and cancellation. roots must be container-relative
// paths under Library/Caches or tmp (nil = both, the old behaviour);
// anything else is refused. Returns NO when the walk could not start
// (bad container/roots) or when any delete failed.
BOOL cl_clean_matching_files_filtered(NSString *container, NSArray<NSString *> *extensions,
                                      NSArray<NSString *> *nameSubstrings,
                                      NSArray<NSString *> *excludedRelativePaths,
                                      const CLCleanMatchOptions *options,
                                      CLCleanMatchResult *resultOut, NSString **reason)
{
    CLCleanMatchOptions opts = options ? *options : (CLCleanMatchOptions){0};
    NSArray<NSString *> *roots = opts.roots.count ? opts.roots : @[@"Library/Caches", @"tmp"];
    for (NSString *rel in roots) {
        if ([rel isEqualToString:@"Library/Caches"] || [rel hasPrefix:@"Library/Caches/"] ||
            [rel isEqualToString:@"tmp"] || [rel hasPrefix:@"tmp/"]) continue;
        // v2.5: a validated directory rule may target any directory inside
        // the container (e.g. Documents/Downloads); the rule engine, not
        // this walk, owns that decision. The root must still be a relative
        // path with no . / .. components — defence in depth, whatever the
        // caller claimed.
        if (opts.rootsMayBeAnywhere) {
            if (rel.isAbsolutePath) {
                if (reason) *reason = @"规则目录必须是相对路径";
                return NO;
            }
            BOOL bad = NO;
            for (NSString *component in rel.pathComponents) {
                if ([component isEqualToString:@"."] || [component isEqualToString:@".."]) bad = YES;
            }
            if (bad) {
                if (reason) *reason = @"规则目录不能包含 . 或 ..";
                return NO;
            }
            continue;
        }
        if (reason) *reason = @"规则子目录只能在 Library/Caches 或 tmp 之下";
        return NO;
    }
    if (!container.length) {
        if (reason) *reason = @"容器路径为空";
        return NO;
    }
    if (!CLSafetyHasNoSymlinkAncestry(container, NO)) {
        if (reason) *reason = @"容器路径不安全";
        return NO;
    }
    CLCleanMatch m = { .extensions = extensions ?: @[], .names = nameSubstrings ?: @[],
                       .excludes = excludedRelativePaths ?: @[], .container = container,
                       .minAgeSeconds = opts.minAgeSeconds, .minSize = opts.minSize,
                       .maxSize = opts.maxSize, .now = NSDate.date.timeIntervalSince1970,
                       .dryRun = opts.dryRun, .sample = [NSMutableArray new],
                       .failedPaths = [NSMutableArray new], .skippedPaths = [NSMutableArray new] };
    struct stat cst;
    if (lstat(container.fileSystemRepresentation, &cst) == 0) {
        m.containerDevice = cst.st_dev;
        m.containerInode = cst.st_ino;
        m.containerIdentityKnown = YES;
    }
    for (NSString *rel in roots) {
        if (cl_clean_match_excluded(rel, m.excludes)) continue;
        NSString *root = [container stringByAppendingPathComponent:rel];
        int fd = cl_open_directory(root);
        if (fd < 0) {
            if (errno == ENOENT || errno == ENOTDIR) continue;
            m.limited = YES;
            continue;
        }
        cl_clean_match_fd(fd, root, container, &m, opts.cancellation);
        close(fd);
        if (m.stop) break;
    }
    if (resultOut) {
        *resultOut = (CLCleanMatchResult){ .freed = m.freed, .failed = m.failed,
            .skipped = m.skipped, .matched = m.matched, .matchedBytes = m.matchedBytes,
            .samplePaths = [m.sample copy], .failedPaths = [m.failedPaths copy],
            .skippedPaths = [m.skippedPaths copy], .limited = m.limited };
    }
    if (m.stop) {
        if (reason) *reason = @"容器在清理过程中发生变化，已停止";
        return NO;
    }
    if (m.failed && reason) *reason = [NSString stringWithFormat:@"%lu 个文件删除失败", (unsigned long)m.failed];
    return m.failed == 0;
}

BOOL cl_clean_matching_files(NSString *container, NSArray<NSString *> *extensions,
                             NSArray<NSString *> *nameSubstrings,
                             NSArray<NSString *> *excludedRelativePaths,
                             unsigned long long *freed, NSUInteger *failed,
                             NSString **reason)
{
    CLCleanMatchResult r;
    CLCleanMatchOptions opts = {0};
    BOOL ok = cl_clean_matching_files_filtered(container, extensions, nameSubstrings,
                                               excludedRelativePaths, &opts, &r, reason);
    if (freed) *freed = r.freed;
    if (failed) *failed = r.failed;
    return ok;
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

#ifdef CL_ACCESS_TESTING
// v2.8: counts tree-measurement calls so the regression test can prove
// the targets-only scan never measures.
NSUInteger cl_test_measure_calls = 0;
NSUInteger cl_test_measure_call_count(void) { return cl_test_measure_calls; }
#endif

static CLCacheMeasurementState CLCacheMeasureDirectory(NSString *path,
                                                        CLScanCancellation *cancellation,
                                                        unsigned long long *bytes)
{
#ifdef CL_ACCESS_TESTING
    cl_test_measure_calls++;
#endif
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

// Same, but also returns the top-5 first-level subdirectory sizes (v2.3) —
// used for the Caches tree so the directory view can show a folder's size
// without a second walk.
static CLCacheMeasurementState CLCacheMeasureDirectorySubdirs(NSString *path,
                                                             CLScanCancellation *cancellation,
                                                             unsigned long long *bytes,
                                                             NSArray<NSDictionary *> **subdirsOut)
{
#ifdef CL_ACCESS_TESTING
    cl_test_measure_calls++;
#endif
    unsigned long long total = 0;
    NSArray<NSDictionary *> *subdirs = nil;
    CLMeasureResult result = cl_measure_tree_subdirs(path, cancellation, &total, subdirsOut ? &subdirs : NULL);
    switch (result) {
        case CLMeasureResultMissing:
            return CLCacheMeasurementMissing;
        case CLMeasureResultKnown:
            if (bytes) *bytes = total;
            if (subdirsOut) *subdirsOut = subdirs;
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
                                    BOOL *cacheKnown, BOOL *tempKnown,
                                    NSArray<NSDictionary *> **cacheSubdirs)
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
    // The Caches top-5 breakdown is cached with the sizes (v2.3); an entry
    // written before v2.3 simply has no breakdown — still a valid hit.
    if (cacheSubdirs) {
        NSArray *subdirs = e[@"cacheSubdirs"];
        *cacheSubdirs = [subdirs isKindOfClass:NSArray.class] ? subdirs : nil;
    }
    return YES;
}

static void cl_measure_cache_store(NSMutableDictionary *store, NSString *container,
                                   const struct stat *containerStat,
                                   const struct stat *cachesStat, const struct stat *tmpStat,
                                   unsigned long long cacheBytes, unsigned long long tempBytes,
                                   BOOL cacheKnown, BOOL tempKnown,
                                   NSArray<NSDictionary *> *cacheSubdirs)
{
    store[container] = @{ @"device": @(containerStat->st_dev), @"inode": @(containerStat->st_ino),
        @"cachesMtime": @(cachesStat->st_mtimespec.tv_sec), @"cachesMtimeNs": @(cachesStat->st_mtimespec.tv_nsec),
        @"cachesSize": @(cachesStat->st_size),
        @"tmpMtime": @(tmpStat->st_mtimespec.tv_sec), @"tmpMtimeNs": @(tmpStat->st_mtimespec.tv_nsec),
        @"tmpSize": @(tmpStat->st_size),
        @"cacheBytes": @(cacheBytes), @"tempBytes": @(tempBytes),
        @"cacheKnown": @(cacheKnown), @"tempKnown": @(tempKnown),
        @"cacheSubdirs": cacheSubdirs ?: @[],
        @"savedAt": @(NSDate.date.timeIntervalSinceReferenceDate) };
}

#pragma mark - Persisted item list (v2.8, cached first paint)
//
// The last completed scan's rows, saved so the clean page can paint
// instantly on a cold launch instead of showing an empty spinner until
// the first measurement batch arrives. Display-only: no target records
// are stored, so these items can never be cleaned — the clean button
// stays hidden while the refresh scan runs, and the refresh replaces
// them with fresh measured items (merge-by-key in the clean page).
// Same 24 h TTL as the measurement cache; a corrupt or foreign file
// loads as empty, never as a crash.

static const NSInteger kCLItemsCacheVersion = 1;
static const NSUInteger kCLItemsCacheMaxItems = 512;

static NSString *cl_items_cache_path(void)
{
#ifdef CL_ACCESS_TESTING
    extern NSString *cl_test_items_cache_path;
    if (cl_test_items_cache_path.length) return cl_test_items_cache_path;
#endif
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    return dir.length ? [dir stringByAppendingPathComponent:@"cl-cache-items.plist"] : nil;
}

void cl_cache_save_items(NSArray<CLCacheItem *> *items, NSUInteger totalApps)
{
    NSString *path = cl_items_cache_path();
    if (!path) return;
    NSMutableArray *rows = [NSMutableArray new];
    for (CLCacheItem *it in items) {
        if (rows.count >= kCLItemsCacheMaxItems) break;
        if (!it.name.length) continue;
        // Crash-log rows have no containerPath (they key off their target);
        // app rows without one are not real rows.
        if (!it.crashLogs && !it.containerPath.length) continue;
        [rows addObject:@{ @"name": it.name,
                           @"bundleID": it.bundleID ?: @"",
                           @"containerPath": it.containerPath ?: @"",
                           @"cacheBytes": @(it.cacheBytes), @"tempBytes": @(it.tempBytes),
                           @"cacheKnown": @(it.cacheKnown), @"tempKnown": @(it.tempKnown),
                           @"limited": @(it.limited), @"crashLogs": @(it.crashLogs),
                           @"selected": @(it.selected) }];
    }
    NSDictionary *plist = @{ @"version": @(kCLItemsCacheVersion),
                             @"savedAt": @(NSDate.date.timeIntervalSinceReferenceDate),
                             @"totalApps": @(totalApps), @"items": rows };
    if (![plist writeToFile:path atomically:YES])
        cl_log(@"cache items: cannot save the last scan to %@", path);
}

NSArray<CLCacheItem *> *cl_cache_load_items(NSTimeInterval *savedAtOut)
{
    if (savedAtOut) *savedAtOut = 0;
    NSString *path = cl_items_cache_path();
    if (!path) return nil;
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:path];
    if (![plist isKindOfClass:NSDictionary.class]) return nil;
    if ([plist[@"version"] integerValue] != kCLItemsCacheVersion) return nil;
    NSTimeInterval savedAt = [plist[@"savedAt"] doubleValue];
    if (savedAt <= 0 || NSDate.date.timeIntervalSinceReferenceDate - savedAt > kCLMeasureCacheTTL) return nil;
    NSArray *rows = plist[@"items"];
    if (![rows isKindOfClass:NSArray.class]) return nil;
    NSMutableArray<CLCacheItem *> *items = [NSMutableArray new];
    for (id row in rows) {
        if (![row isKindOfClass:NSDictionary.class]) continue;
        NSString *name = row[@"name"];
        if (![name isKindOfClass:NSString.class] || !name.length) continue;
        BOOL crashLogs = [row[@"crashLogs"] boolValue];
        NSString *containerPath = row[@"containerPath"];
        if (![containerPath isKindOfClass:NSString.class]) containerPath = @"";
        if (!crashLogs && !containerPath.length) continue;
        CLCacheItem *it = [CLCacheItem new];
        it.name = name;
        NSString *bid = row[@"bundleID"];
        it.bundleID = [bid isKindOfClass:NSString.class] ? bid : @"";
        it.containerPath = containerPath;
        it.cacheBytes = [row[@"cacheBytes"] unsignedLongLongValue];
        it.tempBytes = [row[@"tempBytes"] unsignedLongLongValue];
        it.cacheKnown = [row[@"cacheKnown"] boolValue];
        it.tempKnown = [row[@"tempKnown"] boolValue];
        it.limited = [row[@"limited"] boolValue];
        it.crashLogs = crashLogs;
        it.selected = [row[@"selected"] boolValue];
        // Crash-log rows carry their target for the row key; app rows
        // carry no target records (display-only, never cleanable).
        if (it.crashLogs) it.targets = @[CLCrashLogsPath];
        [items addObject:it];
    }
    if (!items.count) return nil;
    if (savedAtOut) *savedAtOut = savedAt;
    return items;
}

#ifdef CL_ACCESS_TESTING
NSString *cl_test_items_cache_path = nil;
#endif

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
@property (nonatomic) NSUInteger totalAppCount;
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

- (void)updateWithItems:(NSArray<CLCacheItem *> *)items limited:(BOOL)limited totalApps:(NSUInteger)totalApps
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
    // totalApps is the count of DISTINCT APPS actually measured (v2.4:
    // Application containers only). appCount above drops apps under 64 KB
    // — after a clean every app is ~0 bytes and appCount falls to 0,
    // which is what the home showed (the v2.3 bug). v2.3's fix counted
    // every container including PluginKitPlugin extensions and showed
    // 1226; this counts apps, so the home shows 114 and stays 114.
    _totalAppCount = totalApps;
    _limited = limited;
    _scanning = NO;
    _lastScanFinished = NSDate.date.timeIntervalSinceReferenceDate;
    // v2.8: persist the rows for the clean page's cached first paint.
    cl_cache_save_items(items, totalApps);
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
    _totalAppCount = 0;
}

@end

@interface CLCacheScanner ()
@property (nonatomic, strong) CLScanCancellation *cancellation;
// Internal entry: skipMeasurement=YES builds targets-only items (no tree
// walks) for the background clean; NO is the measured scan for the UI.
- (void)startWithProgress:(void (^_Nullable)(NSString *status))progress
              itemsUpdate:(void (^_Nullable)(NSArray<CLCacheItem *> *newItems))itemsUpdate
               completion:(void (^)(NSArray<CLCacheItem *> *items, BOOL limited, NSString *note, BOOL cancelled, NSUInteger totalApps))completion
         skipMeasurement:(BOOL)skipMeasurement;
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
// Every container measured (including sub-64 KB ones that produce no row).
// The home's app count does NOT come from this.
@property (nonatomic) NSUInteger totalContainers;
// Distinct APPS measured (v2.5): the set of bundle ids resolved for
// containers under Containers/Data/Application. PluginKitPlugin containers
// (widgets, extensions) are measured too, but they are not apps and are
// never added to this set. v2.4 counted every Application container here
// and the home showed 267 for 114 apps: one app can own several
// containers under Data/Application, and most containers are sub-64 KB
// and produce no row, so a container count is not an app count. The set
// is keyed by the same resolver the rows use (cl_container_label), so the
// count equals the clean-list item count (114 on the user's phone) and it
// survives a clean-all, because enumeration does not depend on cache size.
@property (nonatomic, strong) NSMutableSet<NSString *> *appBundleIDs;
@property (nonatomic) NSUInteger deliveredItemCount;
@property (nonatomic) BOOL scanLimited;
@property (nonatomic) NSUInteger limitedContainers;
@property (nonatomic) NSUInteger limitedMeasurements;
@property (nonatomic) NSUInteger missingIdentities;
@property (nonatomic) NSUInteger measureCacheHits;
// v2.8: when YES, scanOneContainer builds targets-only items (no tree
// measurement) and the crash-log measurement is skipped.
@property (nonatomic) BOOL skipMeasurement;
@end

@implementation CLCacheScanContext
@end

@implementation CLCacheScanner

- (void)cancel
{
    [_cancellation cancel];
}

- (void)startWithProgress:(void (^_Nullable)(NSString *status))progress
               completion:(void (^)(NSArray<CLCacheItem *> *items, BOOL limited, NSString *note, BOOL cancelled, NSUInteger totalApps))completion
{
    [self startWithProgress:progress itemsUpdate:nil completion:completion];
}

// v2.8 fast path — one container's purgeable item WITHOUT measuring
// its trees: grant + safety + stat + label + target records only. The
// purge needs targets, not sizes, and counts the freed bytes itself;
// measuring first meant walking every changed cache tree twice (measure,
// then purge) and deleting nothing until all measuring was done. The
// item is marked unmeasured (sizes unknown, 0 — NOT "nothing to clean")
// and is limited only when the container cannot be granted, fails the
// safety check, or has no identity — exactly like the measured scan's
// limited rows, so the background clean counts it as skipped instead of
// silently dropping the app. Never calls the tree-measurement functions
// (the regression test asserts the measurement counter stays at 0).
CLCacheItem *cl_cache_targets_only_item(NSString *c, CLScanCancellation *cancellation)
{
    if (cancellation.isCancelled) return nil;
    NSString *caches = [c stringByAppendingPathComponent:@"Library/Caches"];
    NSString *tmp = [c stringByAppendingPathComponent:@"tmp"];
    // One ancestry walk for the container + both targets (same as the
    // measured scan), instead of the three walks the two single-target
    // checks used to do.
    BOOL safeCaches = NO, safeTmp = NO;
    BOOL safeContainer = CLSafetyContainerTargetsSafe(c, caches, @"Library/Caches", &safeCaches,
                                                         tmp, @"tmp", &safeTmp);
    BOOL granted = safeContainer && cl_grant(c);  // one token for the whole container
    // Stat everything once up front: the container identity and both
    // targets (for the target records) — no re-stat later.
    struct stat containerStat = {0};
    BOOL containerKnown = cl_stat(c, &containerStat) && S_ISDIR(containerStat.st_mode);
    struct stat cachesStat = {0}, tmpStat = {0};
    CLCachePathState cachesState = CLCacheInspectPath(caches, &cachesStat);
    CLCachePathState tmpState = CLCacheInspectPath(tmp, &tmpStat);
    if (!granted || !safeContainer) {
        cl_log(@"cache scan: %@ (%@) %@", c.lastPathComponent, cl_bundle_id_for_container(c) ?: @"未知应用",
               safeContainer ? @"拒绝访问" : @"未通过路径安全检查");
    }
    CLCacheItem *item = [CLCacheItem new];
    NSString *bid = granted ? cl_container_label(c) : nil;
    item.bundleID = bid;
    item.name = cl_display_name(bid) ?: bid ?: c.lastPathComponent;
    item.targets = @[caches, tmp];
    item.cacheBytes = 0;
    item.tempBytes = 0;
    item.cacheSubdirs = nil;
    item.cacheKnown = NO;
    item.tempKnown = NO;
    item.unmeasured = YES;
    item.limited = !granted || !safeContainer;
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
    }
    item.selected = !item.limited;
    return item;
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
    // v2.8: the targets-only scan (background clean) never measures — the
    // item is built without any tree walk (see cl_cache_targets_only_item).
    // A limited item still marks the scan limited, like the measured
    // scan does: the background clean reports partial progress when apps
    // were skipped.
    if (ctx.skipMeasurement) {
        CLCacheItem *item = cl_cache_targets_only_item(c, cancellation);
        if (item && item.limited) {
            [ctx.lock lock];
            ctx.scanLimited = YES;
            [ctx.lock unlock];
        }
        return item;
    }
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
    NSArray<NSDictionary *> *cacheSubdirs = nil;
    BOOL fromCache = NO;
    if (containerKnown && cachesState == CLCachePathExisting && tmpState == CLCachePathExisting) {
        fromCache = cl_measure_cache_lookup(ctx.measureCache, c, &containerStat, &cachesStat, &tmpStat,
                                            &cacheBytes, &tempBytes, &cacheKnown, &tempKnown, &cacheSubdirs);
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
            ? CLCacheMeasureDirectorySubdirs(caches, cancellation, &cacheBytes, &cacheSubdirs)
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
                                   cacheBytes, tempBytes, cacheKnown, tempKnown, cacheSubdirs);
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
    item.cacheSubdirs = cacheSubdirs;
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

// Every app container under Data/Application, from the filesystem —
// independent of the scan store, so the rule picker lists apps that
// were never scanned (v2.7: adding a rule used to cover only what the
// scanner found, so an app that was never scanned could not get a rule
// at all). Uses the same cached inode enumeration as the scan
// (cl_enumerate, shared 10-minute cache) and the same labeling as the
// scan rows (cl_container_label for the bundle id, cl_display_name for
// the name), then dedupes by bundle id — one app can own several
// containers under Data/Application (v2.4 counted containers and showed
// 267 for 114 apps). Our own container is skipped, like the Apps page.
// Runs on the caller's queue (off the main thread — cl_load_display_names
// blocks); progress is the enumerate progress. Returns lightweight
// CLCacheItems (name, bundleID, containerPath only — no cache
// measurement) or nil when the enumeration fails or is cancelled.
NSArray<CLCacheItem *> *_Nullable cl_all_app_containers(
    CLScanCancellation *_Nullable cancellation,
    void (^_Nullable progress)(int64_t done, int64_t total, NSUInteger found))
{
    NSArray<NSString *> *containers = cl_enumerate(
        @"/private/var/mobile/Containers/Data/Application", 0, cancellation, progress);
    if (!containers) return nil;
    if (!cl_display_names_loaded()) cl_load_display_names();
    NSString *home = [NSHomeDirectory() stringByResolvingSymlinksInPath];
    NSMutableArray<CLCacheItem *> *apps = [NSMutableArray new];
    NSMutableSet<NSString *> *seen = [NSMutableSet new];
    for (NSString *c in containers) {
        if (cancellation.isCancelled) return nil;
        if ([[c stringByResolvingSymlinksInPath] isEqualToString:home]) continue;
        NSString *bid = cl_container_label(c);
        if (!bid.length) continue;
        if ([seen containsObject:bid]) continue;
        [seen addObject:bid];
        CLCacheItem *item = [CLCacheItem new];
        item.bundleID = bid;
        item.name = cl_display_name(bid) ?: bid;
        item.containerPath = c;
        [apps addObject:item];
    }
    [apps sortUsingComparator:^NSComparisonResult(CLCacheItem *a, CLCacheItem *b) {
        return [a.name localizedStandardCompare:b.name];
    }];
    return apps;
}

- (void)startWithProgress:(void (^_Nullable)(NSString *status))progress
              itemsUpdate:(void (^_Nullable)(NSArray<CLCacheItem *> *newItems))itemsUpdate
               completion:(void (^)(NSArray<CLCacheItem *> *items, BOOL limited, NSString *note, BOOL cancelled, NSUInteger totalApps))completion
{
    [self startWithProgress:progress itemsUpdate:itemsUpdate completion:completion skipMeasurement:NO];
}

- (void)startTargetsOnlyWithProgress:(void (^_Nullable)(NSString *status))progress
                          completion:(void (^)(NSArray<CLCacheItem *> *items, BOOL limited, NSString *note, BOOL cancelled, NSUInteger totalApps))completion
{
    [self startWithProgress:progress itemsUpdate:nil completion:completion skipMeasurement:YES];
}

- (void)startWithProgress:(void (^_Nullable)(NSString *status))progress
              itemsUpdate:(void (^_Nullable)(NSArray<CLCacheItem *> *newItems))itemsUpdate
               completion:(void (^)(NSArray<CLCacheItem *> *items, BOOL limited, NSString *note, BOOL cancelled, NSUInteger totalApps))completion
         skipMeasurement:(BOOL)skipMeasurement
{
    [self cancel];
    CLScanCancellation *cancellation = [CLScanCancellation new];
    _cancellation = cancellation;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        CLCacheScanContext *ctx = [CLCacheScanContext new];
        ctx.cancellation = cancellation;
        ctx.skipMeasurement = skipMeasurement;
        ctx.lock = [NSLock new];
        ctx.items = [NSMutableArray new];
        ctx.appBundleIDs = [NSMutableSet new];
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
            if (cancellation.isCancelled) { if (completion) completion(nil, ctx.scanLimited, @"扫描已取消。", YES, ctx.appBundleIDs.count); return; }
            NSString *kind = [root.lastPathComponent isEqualToString:@"Application"] ? @"应用" : @"扩展";
            // Only the Application root holds apps. PluginKitPlugin
            // containers are extensions, counted in totalContainers
            // (progress) but never added to appBundleIDs.
            BOOL isAppRoot = [root.lastPathComponent isEqualToString:@"Application"];
            NSArray *containers = cl_enumerate(root, 0, cancellation, ^(int64_t done, int64_t total, NSUInteger __unused f) {
                if (progress) progress([NSString stringWithFormat:@"正在查找%@… %lld%%", kind, (long long)(done * 100 / (total ?: 1))]);
            });
            if (!containers) {
                if (cancellation.isCancelled) { if (completion) completion(nil, ctx.scanLimited, @"扫描已取消。", YES, ctx.appBundleIDs.count); return; }
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
                    ctx.totalContainers++;
                    if (isAppRoot) {
                        // v2.5: the home's app count is DISTINCT BUNDLE
                        // IDS, not containers. The row already carries its
                        // bundle id when one was measured; a container too
                        // small to list (no row) still belongs to an app,
                        // so its id is resolved here as well. Containers
                        // that do not resolve to a bundle id are not apps
                        // and are not counted.
                        NSString *bid = item.bundleID;
                        if (!bid.length) bid = cl_container_label(containers[idx]);
                        if (bid.length) [ctx.appBundleIDs addObject:bid];
                    }
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
            if (cancellation.isCancelled) { if (completion) completion(nil, ctx.scanLimited, @"扫描已取消。", YES, ctx.appBundleIDs.count); return; }
        }
        // v2.8: the targets-only scan skips the crash-log measurement too
        // (crash logs are not part of the background clean's contract,
        // and measuring them is another tree walk).
        if (!ctx.skipMeasurement) {
        unsigned long long crash = 0;
        // Crash logs are in a system group, which worse_query reaches on iOS 27
        // only. On iOS 26 the section is left out instead of reported as limited.
        BOOL crashReachable = cl_system_areas_reachable();
        BOOL safeCrashPath = crashReachable && CLCacheCrashPathIsSafe(CLCrashLogsPath);
        CLCacheMeasurementState crashState = !crashReachable ? CLCacheMeasurementMissing
            : safeCrashPath ? CLCacheMeasureDirectory(CLCrashLogsPath, cancellation, &crash)
                            : CLCacheMeasurementLimited;
        if (crashState == CLCacheMeasurementCancelled) { if (completion) completion(nil, ctx.scanLimited, @"扫描已取消。", YES, ctx.appBundleIDs.count); return; }
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
        if (completion) completion([ctx.items copy], ctx.scanLimited, note, NO, ctx.appBundleIDs.count);
    });
}

@end
