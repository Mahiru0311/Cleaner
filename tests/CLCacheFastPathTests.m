// Tests the v2.8 fast path (targets-only scan) and the persisted item
// list (cached first paint). Fixtures are disposable and under $TMPDIR.
// On the macOS host there is no sandbox grant and no container label, so
// a targets-only item built here is limited (no bundle id) — the test
// asserts what the fast path must guarantee on any host: the item is
// built with both target records and the unmeasured mark, and no tree
// measurement runs at all (the measurement counter stays at 0).
#define CL_ACCESS_TESTING 1
#import "../Core/CLCache.h"
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

int main(void)
{
    @autoreleasepool {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *base = [CLCanonicalVarPath(NSTemporaryDirectory().stringByResolvingSymlinksInPath) stringByAppendingPathComponent:
                          [@"CLCacheFastPathTests-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        mkdirs(base);
        @try {
            // --- Fixture container with real cache files. ---
            NSString *container = [base stringByAppendingPathComponent:@"container"];
            NSString *caches = [container stringByAppendingPathComponent:@"Library/Caches"];
            NSString *tmp = [container stringByAppendingPathComponent:@"tmp"];
            mkdirs(caches);
            mkdirs(tmp);
            put([caches stringByAppendingPathComponent:@"a.dat"], @"12345");
            put([tmp stringByAppendingPathComponent:@"b.dat"], @"1234567");

            NSUInteger before = cl_test_measure_call_count();
            CLCacheItem *item = cl_cache_targets_only_item(container, nil);
            check(item != nil, @"targets-only item is built for a container with caches");
            check(item.targetRecords.count == 2, @"targets-only item has both target records");
            check([item.targetRecords[0].path isEqualToString:caches], @"first target record is Library/Caches");
            check([item.targetRecords[1].path isEqualToString:tmp], @"second target record is tmp");
            check(item.targetRecords[0].identityKnown && item.targetRecords[1].identityKnown,
                  @"target records carry the identity for validation");
            check(item.unmeasured, @"targets-only item is marked unmeasured");
            check(item.cacheBytes == 0 && item.tempBytes == 0, @"targets-only item carries no sizes");
            check(item.containerIdentityKnown, @"targets-only item records the container identity");
            check(item.name.length > 0, @"targets-only item has a name");
            check(cl_test_measure_call_count() == before,
                  @"targets-only build never measures a tree (counter unchanged)");

            // --- Container with no Caches/tmp at all: still an item
            // (the purge of a missing dir is a no-op), still unmeasured.
            NSString *empty = [base stringByAppendingPathComponent:@"empty-container"];
            mkdirs(empty);
            CLCacheItem *emptyItem = cl_cache_targets_only_item(empty, nil);
            check(emptyItem != nil, @"targets-only item is built for a container without cache dirs");
            check(emptyItem.targetRecords.count == 2, @"empty container still gets both target records");
            check(!emptyItem.targetRecords[0].existed && !emptyItem.targetRecords[1].existed,
                  @"missing targets are recorded as not existing");
            check(emptyItem.unmeasured, @"empty container item is unmeasured");
            check(cl_test_measure_call_count() == before,
                  @"missing-target build never measures a tree either");

            // --- Persisted item list: save / load round-trip. ---
            NSString *itemsPath = [base stringByAppendingPathComponent:@"items.plist"];
            cl_test_items_cache_path = itemsPath;
            CLCacheItem *app = [CLCacheItem new];
            app.name = @"TestApp";
            app.bundleID = @"com.example.test";
            app.containerPath = container;
            app.cacheBytes = 12345;
            app.tempBytes = 678;
            app.cacheKnown = YES;
            app.tempKnown = YES;
            app.limited = NO;
            app.selected = YES;
            CLCacheItem *logs = [CLCacheItem new];
            logs.name = @"崩溃日志";
            logs.cacheBytes = 999;
            logs.cacheKnown = YES;
            logs.crashLogs = YES;
            logs.selected = YES;
            cl_cache_save_items(@[app, logs], 2);
            NSTimeInterval savedAt = 0;
            NSArray<CLCacheItem *> *loaded = cl_cache_load_items(&savedAt);
            check(loaded.count == 2, @"persisted items load back");
            check(savedAt > 0, @"load reports the save time");
            CLCacheItem *loadedApp = loaded[0];
            check([loadedApp.name isEqualToString:@"TestApp"], @"app name survives the round-trip");
            check([loadedApp.bundleID isEqualToString:@"com.example.test"], @"bundle id survives the round-trip");
            check([loadedApp.containerPath isEqualToString:container], @"container path survives the round-trip");
            check(loadedApp.cacheBytes == 12345 && loadedApp.tempBytes == 678, @"sizes survive the round-trip");
            check(loadedApp.cacheKnown && loadedApp.tempKnown, @"known flags survive the round-trip");
            check(loadedApp.selected, @"selection survives the round-trip");
            check(!loadedApp.unmeasured, @"persisted items are measured rows, not targets-only");
            CLCacheItem *loadedLogs = loaded[1];
            check(loadedLogs.crashLogs, @"crash-log row survives the round-trip");
            check(loadedLogs.targets.count == 1 && [loadedLogs.targets[0] isEqualToString:CLCrashLogsPath],
                  @"crash-log row keeps its target for the row key");

            // --- Corrupt file loads as empty, never as a crash. ---
            check([@"garbage" writeToFile:itemsPath atomically:YES encoding:NSUTF8StringEncoding error:nil],
                  @"write corrupt items file");
            check(cl_cache_load_items(NULL) == nil, @"corrupt items file loads as empty");

            // --- Expired entries are dropped (24 h TTL). ---
            cl_cache_save_items(@[app], 1);
            NSMutableDictionary *plist = [[NSDictionary dictionaryWithContentsOfFile:itemsPath] mutableCopy];
            check(plist != nil, @"saved items plist is readable");
            plist[@"savedAt"] = @(NSDate.date.timeIntervalSinceReferenceDate - 25 * 3600);
            check([plist writeToFile:itemsPath atomically:YES], @"rewrite items plist with an old save time");
            check(cl_cache_load_items(NULL) == nil, @"items older than 24 h are dropped");

            // --- Wrong version is dropped. ---
            cl_cache_save_items(@[app], 1);
            plist = [[NSDictionary dictionaryWithContentsOfFile:itemsPath] mutableCopy];
            plist[@"version"] = @99;
            check([plist writeToFile:itemsPath atomically:YES], @"rewrite items plist with a wrong version");
            check(cl_cache_load_items(NULL) == nil, @"items with an unknown version are dropped");
        } @finally {
            [fm removeItemAtPath:base error:nil];
        }
    }
    printf("CLCacheFastPathTests: PASS\n");
    return 0;
}
