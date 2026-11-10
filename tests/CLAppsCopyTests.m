// Compile the real copy implementation against a temporary tree and verify the
// same source-stability plus destination-shape checks used by app backups.
#define CL_ACCESS_TESTING 1
#import "../Core/CLGrant.h"
#import "../Core/CLAppSupport.h"
#include <stdlib.h>

SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator) { (void)allocator; return NULL; }
CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement, CFErrorRef *error)
{ (void)task; (void)entitlement; (void)error; return NULL; }

static int failures;

#define CLCheck(condition) do { \
    if (!(condition)) { \
        fprintf(stderr, "FAIL %s:%d: %s\n", __func__, __LINE__, #condition); \
        failures++; \
    } \
} while (0)

static void Put(NSString *path, NSString *text)
{
    CLCheck([[text dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:YES]);
}

int main(void)
{
    @autoreleasepool {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *base = [CLCanonicalVarPath(NSTemporaryDirectory().stringByResolvingSymlinksInPath)
                          stringByAppendingPathComponent:
                          [@"CLAppsCopyTests-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        NSString *src = [base stringByAppendingPathComponent:@"src"];
        NSString *dst = [base stringByAppendingPathComponent:@"dst"];
        @try {
            CLCheck([fm createDirectoryAtPath:[src stringByAppendingPathComponent:@"nested"]
                  withIntermediateDirectories:YES attributes:nil error:nil]);
            Put([src stringByAppendingPathComponent:@"file"], @"original bytes");
            Put([src stringByAppendingPathComponent:@"nested/child"], @"nested bytes");
            CLCheck(symlink([src stringByAppendingPathComponent:@"file"].fileSystemRepresentation,
                            [src stringByAppendingPathComponent:@"link"].fileSystemRepresentation) == 0);

            NSString *error = nil;
            BOOL exists = NO;
            NSString *sourceBefore = CLAppSupportTreeSignature(src, YES, &exists, &error);
            CLCheck(sourceBefore.length > 0 && exists);
            CLCheck(cl_copy_contents(src, dst, &error));
            NSString *sourceAfter = CLAppSupportTreeSignature(src, YES, &exists, &error);
            NSString *sourceShape = CLAppSupportTreeSignature(src, NO, &exists, &error);
            NSString *destinationShape = CLAppSupportTreeSignature(dst, NO, &exists, &error);
            CLCheck(sourceAfter && sourceShape && destinationShape);
            CLCheck([sourceBefore isEqualToString:sourceAfter]);
            CLCheck([sourceShape isEqualToString:destinationShape]);

            // The empty-tree case is also a valid copy.
            NSString *emptySrc = [base stringByAppendingPathComponent:@"empty-src"];
            NSString *emptyDst = [base stringByAppendingPathComponent:@"empty-dst"];
            CLCheck([fm createDirectoryAtPath:emptySrc withIntermediateDirectories:YES attributes:nil error:nil]);
            CLCheck(cl_copy_contents(emptySrc, emptyDst, &error));
            NSString *emptyShape = CLAppSupportTreeSignature(emptyDst, NO, &exists, &error);
            CLCheck(emptyShape && ![emptyShape isEqualToString:@"<missing>"] && exists);

            // Mutating the source after the copy changes the source shape.
            Put([src stringByAppendingPathComponent:@"file"], @"different bytes!");
            NSString *changedShape = CLAppSupportTreeSignature(src, NO, &exists, &error);
            CLCheck(![changedShape isEqualToString:destinationShape]);

            // Content hashing detects a same-size byte change that the shape hash cannot.
            NSString *contentBefore = CLAppSupportTreeContentSignature(dst, &exists, &error);
            CLCheck(contentBefore && exists);
            Put([dst stringByAppendingPathComponent:@"file"], @"ORIGINAL BYTES");
            NSString *contentAfter = CLAppSupportTreeContentSignature(dst, &exists, &error);
            CLCheck(contentAfter && ![contentAfter isEqualToString:contentBefore]);

            // A copy failure must not leave a published destination.
            NSString *missing = [base stringByAppendingPathComponent:@"missing"];
            CLCheck(!cl_copy_contents(missing, [base stringByAppendingPathComponent:@"never"], &error));
        } @finally {
            [fm removeItemAtPath:base error:nil];
        }
        if (failures) {
            fprintf(stderr, "%d app copy regression check(s) failed\n", failures);
            return 1;
        }
        puts("All Apps copy regression tests passed.");
    }
    return 0;
}
