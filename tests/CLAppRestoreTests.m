//
//  CLAppRestoreTests.m
//  Cleaner v2 — restore-plan regression tests. Ported from the
//  TestRestorePlanning part of WQCoreTests.m (v0.1); WQCoreTests' hex
//  parsing, patch-range and edit-revision cases tested the plist/hex
//  editors, which v2 deleted, so they were not carried over.
//

#define CL_ACCESS_TESTING 1
#import <Foundation/Foundation.h>
#import "../Core/CLApp.m"
#include <stdio.h>
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

static void TestRestorePlanning(void)
{
    NSDictionary *both = cl_restore_plan(YES, YES);
    CLCheck(both.count == 2 && [both[@"Documents"] boolValue] && [both[@"Library"] boolValue]);

    NSDictionary *documentsOnly = cl_restore_plan(YES, NO);
    CLCheck([documentsOnly[@"Documents"] boolValue]);
    CLCheck(![documentsOnly[@"Library"] boolValue]);  // absent Library must be purged

    NSDictionary *libraryOnly = cl_restore_plan(NO, YES);
    CLCheck(![libraryOnly[@"Documents"] boolValue]);
    CLCheck([libraryOnly[@"Library"] boolValue]);

    NSDictionary *neither = cl_restore_plan(NO, NO);
    CLCheck(neither.count == 2);
    CLCheck(![neither[@"Documents"] boolValue] && ![neither[@"Library"] boolValue]);
}

static void TestSQLiteLockedTree(void)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *base = [NSTemporaryDirectory().stringByResolvingSymlinksInPath stringByAppendingPathComponent:
                      [@"CLSQLiteGate-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSString *library = [base stringByAppendingPathComponent:@"Library"];
    NSString *sub = [library stringByAppendingPathComponent:@"Application Support"];
    NSError *error = nil;
    CLCheck([fm createDirectoryAtPath:sub withIntermediateDirectories:YES attributes:nil error:&error]);
    NSString *db = [sub stringByAppendingPathComponent:@"analytics.sqlite"];
    NSString *wal = [db stringByAppendingString:@"-wal"];
    NSString *shm = [db stringByAppendingString:@"-shm"];
    CLCheck([@"db" writeToFile:db atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    CLCheck([@"wal" writeToFile:wal atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    CLCheck([@"shm" writeToFile:shm atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    // Idle set: nothing locked, nothing refused — even nested.
    CLCheck(cl_sqlite_locked_member_in_tree(library) == nil);
    // A running app holds the database lock: the gate names the member,
    // with its path relative to the container part.
    int app = open(db.fileSystemRepresentation, O_RDWR);
    CLCheck(app >= 0 && flock(app, LOCK_EX | LOCK_NB) == 0);
    NSString *locked = cl_sqlite_locked_member_in_tree(library);
    CLCheck(locked != nil && [locked isEqualToString:@"Library/Application Support/analytics.sqlite"]);
    close(app);
    CLCheck(cl_sqlite_locked_member_in_tree(library) == nil);

    // A lone database with no companions is not a set: even locked, it
    // does not trip the gate (nothing to keep together).
    NSString *lone = [sub stringByAppendingPathComponent:@"lone.db"];
    CLCheck([@"lone" writeToFile:lone atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    int loneFd = open(lone.fileSystemRepresentation, O_RDWR);
    CLCheck(loneFd >= 0 && flock(loneFd, LOCK_EX | LOCK_NB) == 0);
    CLCheck(cl_sqlite_locked_member_in_tree(library) == nil);
    close(loneFd);

    // An unrelated locked file is not a database set either.
    NSString *other = [sub stringByAppendingPathComponent:@"other.lock"];
    CLCheck([@"lock" writeToFile:other atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    int otherFd = open(other.fileSystemRepresentation, O_RDWR);
    CLCheck(otherFd >= 0 && flock(otherFd, LOCK_EX | LOCK_NB) == 0);
    CLCheck(cl_sqlite_locked_member_in_tree(library) == nil);
    close(otherFd);

    // A missing part reports nothing (the copy/purge reports access).
    CLCheck(cl_sqlite_locked_member_in_tree([base stringByAppendingPathComponent:@"NoSuchPart"]) == nil);
    [fm removeItemAtPath:base error:nil];
}

int main(void)
{
    @autoreleasepool {
        TestRestorePlanning();
        TestSQLiteLockedTree();
        if (failures) {
            fprintf(stderr, "%d regression check(s) failed\n", failures);
            return 1;
        }
        puts("All CLApp restore regression tests passed.");
    }
    return 0;
}
