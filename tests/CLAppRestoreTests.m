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

int main(void)
{
    @autoreleasepool {
        TestRestorePlanning();
        if (failures) {
            fprintf(stderr, "%d regression check(s) failed\n", failures);
            return 1;
        }
        puts("All CLApp restore regression tests passed.");
    }
    return 0;
}
