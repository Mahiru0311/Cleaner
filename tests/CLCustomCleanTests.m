// Custom cleaning (v2.3) and the app-count-after-clean regression, through
// the real implementation. Fixtures are disposable and under $TMPDIR.
#define CL_ACCESS_TESTING 1
#import "../Core/CLCache.h"
#import "../Core/CLCustomClean.h"
#import "../Core/CLScan.h"
#import "../Core/CLSafety.h"
#include <stdlib.h>
#include <sys/stat.h>

SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator) { (void)allocator; return NULL; }
CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement, CFErrorRef *error)
{ (void)task; (void)entitlement; (void)error; return NULL; }

static void check(BOOL ok, NSString *name)
{
    if (!ok) { fprintf(stderr, "FAIL: %s (errno %d)\n", name.UTF8String, errno); exit(1); }
    printf("PASS: %s\n", name.UTF8String);
}
static NSData *bytes(NSString *text) { return [text dataUsingEncoding:NSUTF8StringEncoding]; }
static void put(NSString *path, NSString *text) { check([bytes(text) writeToFile:path atomically:YES], @"write temp file"); }
static void mkdirs(NSString *path) { check([NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil], @"create temp tree"); }
static BOOL has(NSString *path) { return [NSFileManager.defaultManager fileExistsAtPath:path]; }

int main(void)
{
    @autoreleasepool {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *base = [CLCanonicalVarPath(NSTemporaryDirectory().stringByResolvingSymlinksInPath) stringByAppendingPathComponent:
                          [@"CLCustomCleanTests-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        mkdirs(base);
        @try {
            // --- Folder-rule validation: the safety boundary. ---
            NSString *reason = nil;
            check(!cl_custom_clean_validate_folder_pattern(@"", &reason), @"empty folder pattern refused");
            check(!cl_custom_clean_validate_folder_pattern(@"/Library/Caches", &reason), @"absolute folder pattern refused");
            check(!cl_custom_clean_validate_folder_pattern(@"Library/../Caches", &reason), @"dot-dot folder pattern refused");
            check(!cl_custom_clean_validate_folder_pattern(@"Documents", &reason), @"Documents itself refused");
            check(!cl_custom_clean_validate_folder_pattern(@"Library", &reason), @"Library itself refused");
            check(cl_custom_clean_validate_folder_pattern(@"Library/Caches", NULL), @"Library/Caches allowed");
            check(cl_custom_clean_validate_folder_pattern(@"tmp", NULL), @"tmp allowed");
            check(cl_custom_clean_validate_folder_pattern(@"Documents/foo", NULL), @"Documents subfolder allowed (with a warning at run time)");
            check(cl_custom_clean_validate_folder_pattern(@"Library/Application Support/x", NULL), @"Library subfolder allowed");

            // --- Fake container: Caches + tmp + Documents. ---
            NSString *container = [base stringByAppendingPathComponent:@"App-UUID"];
            mkdirs([container stringByAppendingPathComponent:@"Library/Caches/sub"]);
            mkdirs([container stringByAppendingPathComponent:@"tmp"]);
            mkdirs([container stringByAppendingPathComponent:@"Documents"]);
            put([container stringByAppendingPathComponent:@"Library/Caches/a.mp4"], @"12345");       // 5
            put([container stringByAppendingPathComponent:@"Library/Caches/b.jpg"], @"123");          // 3
            put([container stringByAppendingPathComponent:@"Library/Caches/sub/c.mp4"], @"1234567");  // 7
            put([container stringByAppendingPathComponent:@"tmp/d.log"], @"1234567890");              // 10
            put([container stringByAppendingPathComponent:@"Documents/keep.mp4"], @"12345");          // 5

            // --- Extension matching only touches Caches + tmp. ---
            unsigned long long freed = 0;
            NSUInteger failed = 0;
            check(cl_clean_matching_files(container, @[@".mp4"], nil, nil, &freed, &failed, NULL) && freed == 12 && failed == 0,
                  @"extension match deletes .mp4 from Caches only (5 + 7)");
            check(!has([container stringByAppendingPathComponent:@"Library/Caches/a.mp4"]), @"matched file gone");
            check(!has([container stringByAppendingPathComponent:@"Library/Caches/sub/c.mp4"]), @"matched file in subfolder gone");
            check(has([container stringByAppendingPathComponent:@"Library/Caches/b.jpg"]), @"non-matching file kept");
            check(has([container stringByAppendingPathComponent:@"Documents/keep.mp4"]), @"Documents never touched by extension rules");
            check(has([container stringByAppendingPathComponent:@"tmp/d.log"]), @"tmp .log kept (not matched)");

            // --- Excluded folders are skipped. ---
            put([container stringByAppendingPathComponent:@"Library/Caches/a.mp4"], @"12345");
            put([container stringByAppendingPathComponent:@"Library/Caches/sub/c.mp4"], @"1234567");
            freed = 0; failed = 0;
            check(cl_clean_matching_files(container, @[@".mp4"], nil, @[@"Library/Caches/sub"], &freed, &failed, NULL) && freed == 5,
                  @"excluded subfolder skipped");
            check(has([container stringByAppendingPathComponent:@"Library/Caches/sub/c.mp4"]), @"excluded file kept");

            // --- Name matching. ---
            freed = 0; failed = 0;
            check(cl_clean_matching_files(container, nil, @[@".log"], nil, &freed, &failed, NULL) && freed == 10,
                  @"name match deletes the .log from tmp");
            check(!has([container stringByAppendingPathComponent:@"tmp/d.log"]), @"matched log gone");

            // --- Per-folder purge: contents go, the folder stays, the
            // container itself and outside paths are refused. ---
            put([container stringByAppendingPathComponent:@"Library/Caches/sub/x"], @"123");
            put([container stringByAppendingPathComponent:@"Library/Caches/sub/y"], @"12");
            freed = 0;
            // sub holds c.mp4 (7) + x (3) + y (2) = 12.
            check(cl_purge_folder_contents([container stringByAppendingPathComponent:@"Library/Caches/sub"],
                                           container, &freed, NULL) && freed == 12,
                  @"folder purge removes contents and reports freed bytes");
            check(has([container stringByAppendingPathComponent:@"Library/Caches/sub"]), @"folder itself stays");
            check(!has([container stringByAppendingPathComponent:@"Library/Caches/sub/x"]), @"folder contents gone");
            check(!cl_purge_folder_contents(container, container, &freed, &reason), @"container itself refused");
            check(!cl_purge_folder_contents([base stringByAppendingPathComponent:@"outside"],
                                            container, &freed, &reason), @"path outside the container refused");

            // --- Caches subdirectory breakdown (fd measure). ---
            // Caches now holds b.jpg (3) at the top level, plus the new
            // alpha (5 + 7) and beta (3) subdirectories; sub is empty
            // after the purge, so it reports no size.
            NSString *caches = [container stringByAppendingPathComponent:@"Library/Caches"];
            mkdirs([caches stringByAppendingPathComponent:@"alpha"]);
            put([caches stringByAppendingPathComponent:@"alpha/one"], @"12345");
            put([caches stringByAppendingPathComponent:@"alpha/two"], @"1234567");
            mkdirs([caches stringByAppendingPathComponent:@"beta"]);
            put([caches stringByAppendingPathComponent:@"beta/three"], @"123");
            NSArray<NSDictionary *> *subdirs = nil;
            unsigned long long total = 0;
            check(cl_measure_tree_subdirs(caches, nil, &total, &subdirs) == CLMeasureResultKnown,
                  @"subdir measurement succeeds");
            check(total == 18, @"subdir measurement total (3 + 5 + 7 + 3)");
            check(subdirs.count == 2, @"two non-empty top-level subdirectories reported");
            check([subdirs[0][@"name"] isEqualToString:@"alpha"] && [subdirs[0][@"bytes"] unsignedLongLongValue] == 12,
                  @"largest subdirectory first with its size");
            check([subdirs[1][@"name"] isEqualToString:@"beta"] && [subdirs[1][@"bytes"] unsignedLongLongValue] == 3,
                  @"second subdirectory with its size");

            // --- App count after clean-all (v2.3 regression): the store
            // keeps the measured total even when every row is ~0 bytes. ---
            CLCacheItem *app1 = [CLCacheItem new];
            app1.bundleID = @"com.example.one"; app1.cacheBytes = 100; app1.tempBytes = 0;
            CLCacheItem *app2 = [CLCacheItem new];
            app2.bundleID = @"com.example.two"; app2.cacheBytes = 0; app2.tempBytes = 0;
            CLCacheItem *logs = [CLCacheItem new];
            logs.crashLogs = YES; logs.cacheBytes = 50;
            CLCacheStore *store = [CLCacheStore shared];
            [store updateWithItems:@[app1, app2, logs] limited:NO totalApps:114];
            check(store.appCount == 2, @"appCount counts non-log rows");
            check(store.totalAppCount == 114, @"totalAppCount is the measured container total");
            check(store.totalBytes == 150, @"totalBytes sums all rows");
            // After a clean-all the scan returns no rows at all (every app
            // is sub-64 KB, so the scanner drops them from the list) — but
            // the measured container total still arrives.
            [store updateWithItems:@[] limited:NO totalApps:114];
            check(store.appCount == 0, @"appCount falls to 0 when no rows remain");
            check(store.totalAppCount == 114, @"totalAppCount stays 114 after clean-all");
            check(store.totalBytes == 0, @"cleanable total is 0 after clean-all");
        } @finally {
            [fm removeItemAtPath:base error:nil];
        }
        puts("All CLCustomClean regression tests passed.");
    }
    return 0;
}
