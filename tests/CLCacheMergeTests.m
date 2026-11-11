// Tests the v2.9 batch merge (cl_cache_merge_items, moved from
// CLCleanerViewController so the table-update invariant is unit-testable).
// The merge must replace cached rows by key (carrying selection over),
// append genuinely new rows, sort by bytes descending, and report whether
// any replaced row moved — a moved row must not be updated with
// reloadRowsAtIndexPaths (the path has to exist before AND after the
// update, at the same index), so the caller falls back to reloadData.
#define CL_ACCESS_TESTING 1
#import "../Core/CLCache.h"
#include <stdlib.h>

SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator) { (void)allocator; return NULL; }
CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement, CFErrorRef *error)
{ (void)task; (void)entitlement; (void)error; return NULL; }

static void check(BOOL ok, NSString *name)
{
    if (!ok) { fprintf(stderr, "FAIL: %s\n", name.UTF8String); exit(1); }
    printf("PASS: %s\n", name.UTF8String);
}

static CLCacheItem *App(NSString *bid, unsigned long long bytes, BOOL selected)
{
    CLCacheItem *item = [CLCacheItem new];
    item.name = bid;
    item.bundleID = bid;
    item.cacheBytes = bytes;
    item.selected = selected;
    return item;
}

static CLCacheItem *Logs(unsigned long long bytes)
{
    CLCacheItem *item = [CLCacheItem new];
    item.name = @"Crash Logs";
    item.crashLogs = YES;
    item.targets = @[@"/private/var/mobile/Library/Logs/CrashReporter"];
    item.cacheBytes = bytes;
    return item;
}

int main(void)
{
    @autoreleasepool {
        // --- Replace in place, selection carried, no move. ---
        {
            CLCacheItem *a = App(@"com.example.a", 1000, YES);
            CLCacheItem *b = App(@"com.example.b", 500, NO);
            CLCacheItem *freshA = App(@"com.example.a", 1000, NO);
            NSSet *replaced = nil; BOOL moved = NO;
            NSArray *merged = cl_cache_merge_items(@[a, b], @[freshA], &replaced, &moved);
            check(merged.count == 2, @"replace keeps the row count");
            check(merged[0] == freshA && merged[1] == b, @"replaced row stays in place");
            check(freshA.selected, @"selection carries over to the fresh row");
            check([replaced containsObject:freshA], @"replaced set holds the fresh row");
            check(!moved, @"same bytes, same position: no move");
        }
        // --- A replaced row whose bytes shrink moves down. ---
        {
            CLCacheItem *a = App(@"com.example.a", 1000, NO);
            CLCacheItem *b = App(@"com.example.b", 500, NO);
            CLCacheItem *freshA = App(@"com.example.a", 100, NO);
            BOOL moved = NO;
            NSArray *merged = cl_cache_merge_items(@[a, b], @[freshA], NULL, &moved);
            check(merged.count == 2 && merged[0] == b && merged[1] == freshA, @"shrunk row sorts below");
            check(moved, @"shrunk replaced row reports moved");
        }
        // --- A new row inserted above a replaced row moves it. ---
        {
            CLCacheItem *a = App(@"com.example.a", 1000, NO);
            CLCacheItem *b = App(@"com.example.b", 500, NO);
            CLCacheItem *freshA = App(@"com.example.a", 1000, NO);
            CLCacheItem *c = App(@"com.example.c", 2000, NO);
            BOOL moved = NO;
            NSArray *merged = cl_cache_merge_items(@[a, b], @[freshA, c], NULL, &moved);
            check(merged.count == 3 && merged[0] == c && merged[1] == freshA && merged[2] == b, @"new row sorts to the top");
            check(moved, @"insert above a replaced row reports moved");
        }
        // --- Pure inserts: no replaced rows, no move. ---
        {
            CLCacheItem *a = App(@"com.example.a", 1000, NO);
            CLCacheItem *b = App(@"com.example.b", 500, NO);
            NSSet *replaced = nil; BOOL moved = YES;
            NSArray *merged = cl_cache_merge_items(@[a], @[b], &replaced, &moved);
            check(merged.count == 2 && merged[0] == a && merged[1] == b, @"new row appends in sort order");
            check(replaced.count == 0, @"pure insert replaces nothing");
            check(!moved, @"pure insert reports no move");
        }
        // --- Crash-log rows key by target path, not bundle id. ---
        {
            CLCacheItem *logs = Logs(100);
            CLCacheItem *freshLogs = Logs(200);
            NSSet *replaced = nil; BOOL moved = NO;
            NSArray *merged = cl_cache_merge_items(@[logs], @[freshLogs], &replaced, &moved);
            check(merged.count == 1 && merged[0] == freshLogs, @"crash-log row replaces by target path");
            check([replaced containsObject:freshLogs], @"crash-log row is reported replaced");
            check(!moved, @"single-row list cannot move");
        }
        // --- Different keys never merge. ---
        {
            CLCacheItem *a = App(@"com.example.a", 1000, NO);
            CLCacheItem *b = App(@"com.example.b", 500, NO);
            NSSet *replaced = nil; BOOL moved = NO;
            NSArray *merged = cl_cache_merge_items(@[a], @[b], &replaced, &moved);
            check(merged.count == 2, @"different keys stay separate rows");
            check(replaced.count == 0, @"different keys replace nothing");
        }
        // --- Empty current list: fresh rows sort, nothing moves. ---
        {
            CLCacheItem *a = App(@"com.example.a", 100, NO);
            CLCacheItem *b = App(@"com.example.b", 500, NO);
            BOOL moved = YES;
            NSArray *merged = cl_cache_merge_items(@[], @[a, b], NULL, &moved);
            check(merged.count == 2 && merged[0] == b && merged[1] == a, @"empty list merges sorted");
            check(!moved, @"empty list reports no move");
        }
    }
    printf("CLCacheMergeTests: PASS\n");
    return 0;
}
