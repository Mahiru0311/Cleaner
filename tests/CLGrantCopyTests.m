#define CL_ACCESS_TESTING 1
#import "../Core/CLGrant.h"
#import "../Core/CLCache.h"
#include <stdlib.h>
SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator) { (void)allocator; return NULL; }
CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement, CFErrorRef *error)
{ (void)task; (void)entitlement; (void)error; return NULL; }
static void check(BOOL ok, NSString *name)
{
    if (!ok) { fprintf(stderr, "FAIL: %s (errno %d)\n", name.UTF8String, errno); exit(1); }
    printf("PASS: %s\n", name.UTF8String);
}
static NSData *bytes(NSString *text) { return [text dataUsingEncoding:NSUTF8StringEncoding]; }
static BOOL has(NSString *path, NSString *text) { return [[NSData dataWithContentsOfFile:path] isEqual:bytes(text)]; }
static void put(NSString *path, NSString *text) { check([bytes(text) writeToFile:path atomically:YES], @"write temp file"); }
static void mkdirs(NSString *path) { check([NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil], @"create temp tree"); }
int main(void)
{
    @autoreleasepool {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *base = [CLCanonicalVarPath(NSTemporaryDirectory().stringByResolvingSymlinksInPath) stringByAppendingPathComponent:
                          [@"CLGrantCopyTests-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        mkdirs(base);
        @try {
            NSString *srcDir = [base stringByAppendingPathComponent:@"src"];
            NSString *dstDir = [base stringByAppendingPathComponent:@"dst"];
            mkdirs(srcDir); mkdirs(dstDir);
            NSString *src = [srcDir stringByAppendingPathComponent:@"child"];
            NSString *dst = [dstDir stringByAppendingPathComponent:@"child"];
            put(src, @"replacement"); put(dst, @"old destination");
            NSString *savedSource = [base stringByAppendingPathComponent:@"saved-source"];
            cl_test_tree_hook = ^(NSString *stage, NSString *path) {
                if ([stage isEqual:@"copyReady"]) {
                    check(has(dst, @"old destination"), @"old destination exists before copy attempt");
                    check(rename(path.fileSystemRepresentation, savedSource.fileSystemRepresentation) == 0, @"inject copy failure by removing source");
                }
            };
            check(!cl_copy_contents(srcDir, dstDir, &error) && has(dst, @"old destination"), @"failed child copy keeps previous destination");
            cl_test_tree_hook = nil;
            check(rename(savedSource.fileSystemRepresentation, src.fileSystemRepresentation) == 0, @"restore fixture source");
            cl_test_tree_hook = ^(NSString *stage, NSString *path) {
                if ([stage isEqual:@"copyStaged"]) check(has(path, @"old destination"), @"old destination survives until completed staging");
            };
            check(cl_copy_contents(srcDir, dstDir, &error) && has(dst, @"replacement"), @"completed child atomically replaces old destination");
            cl_test_tree_hook = nil;
            [fm removeItemAtPath:src error:nil]; [fm removeItemAtPath:dst error:nil];
            mkdirs([src stringByAppendingPathComponent:@"nested"]);
            put([src stringByAppendingPathComponent:@"nested/new"], @"new subtree");
            mkdirs([dst stringByAppendingPathComponent:@"old"]);
            put([dst stringByAppendingPathComponent:@"old/old"], @"old subtree");
            check(cl_copy_contents(srcDir, dstDir, &error) && has([dst stringByAppendingPathComponent:@"nested/new"], @"new subtree") && ![fm fileExistsAtPath:[dst stringByAppendingPathComponent:@"old"]], @"directory replacement installs complete subtree rather than merging");
            check([fm contentsOfDirectoryAtPath:dstDir error:nil].count == 1, @"successful copy removes private staging artifacts");
            check(!cl_copy_contents(srcDir, srcDir, &error), @"same-tree copy refused");
            check(!cl_copy_contents(srcDir, [srcDir stringByAppendingPathComponent:@"descendant"], &error), @"descendant copy refused before recursive staging");
            NSString *linkChild = [srcDir stringByAppendingPathComponent:@"link-child"];
            check(symlink(file.fileSystemRepresentation, linkChild.fileSystemRepresentation) == 0, @"create tree symlink child");
            check(cl_copy_contents(srcDir, dstDir, &error), @"tree copy preserves symlink item without following it");
            struct stat st;
            check(lstat([dstDir stringByAppendingPathComponent:@"link-child"].fileSystemRepresentation, &st) == 0 && S_ISLNK(st.st_mode), @"copied symlink remains a symlink");
        } @finally {
            cl_test_tree_hook = nil;
            [fm removeItemAtPath:base error:nil];
        }
    }
    return 0;
}
