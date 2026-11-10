// Measures a temp tree through the real implementation, including unreadable
// subtrees and cancellation. Fixtures are disposable and under $TMPDIR.
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
                          [@"CLCacheMeasureTests-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        mkdirs(base);
        @try {
            mkdirs([base stringByAppendingPathComponent:@"nested"]);
            put([base stringByAppendingPathComponent:@"one"], @"12345");
            put([base stringByAppendingPathComponent:@"nested/two"], @"1234567");
            put([base stringByAppendingPathComponent:@"nested/empty"], @"");
            check(symlink([base stringByAppendingPathComponent:@"one"].fileSystemRepresentation,
                          [base stringByAppendingPathComponent:@"link"].fileSystemRepresentation) == 0, @"create symlink fixture");
            unsigned long long size = 0;
            check(cl_measure_tree(base, nil, &size) == CLMeasureResultKnown && size == 12,
                  @"known tree sums regular file sizes without following links");
            check(cl_measure_tree([base stringByAppendingPathComponent:@"absent"], nil, &size) == CLMeasureResultMissing,
                  @"missing tree is distinct from an empty one");
            CLScanCancellation *cancellation = [CLScanCancellation new];
            [cancellation cancel];
            check(cl_measure_tree(base, cancellation, &size) == CLMeasureResultCancelled,
                  @"cancelled measurement is explicit");

            NSString *secret = [base stringByAppendingPathComponent:@"secret"];
            mkdirs(secret);
            put([secret stringByAppendingPathComponent:@"hidden"], @"1234567890");
            check(chmod(secret.fileSystemRepresentation, 0000) == 0, @"make subtree unreadable");
            @try {
                size = 0;
                check(cl_measure_tree(base, nil, &size) == CLMeasureResultLimited,
                      @"unreadable subtree marks the whole measurement limited");
                check(size == 12, @"limited measurement still reports the readable bytes");
            } @finally {
                chmod(secret.fileSystemRepresentation, 0700);
            }
        } @finally {
            [fm removeItemAtPath:base error:nil];
        }
        puts("All CLCache measure regression tests passed.");
    }
    return 0;
}
