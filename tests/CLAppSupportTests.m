#import <Foundation/Foundation.h>
#import "../Core/CLAppSupport.h"

static int failures;

#define CLCheck(condition) do { \
    if (!(condition)) { \
        fprintf(stderr, "FAIL %s:%d: %s\n", __func__, __LINE__, #condition); \
        failures++; \
    } \
} while (0)

static NSDictionary *CLBaseManifest(void)
{
    return @{ @"Complete": @YES, @"Format": @1, @"BundleID": @"com.example.app",
              @"Created": [NSDate dateWithTimeIntervalSinceReferenceDate:100],
              @"Parts": @[@"Documents", @"Library"], @"Sequence": @1 };
}

static void TestManifestTypes(void)
{
    NSString *error = nil;
    NSArray *parts = nil;
    CLCheck(CLAppSupportManifestFields(CLBaseManifest(), @"com.example.app", &parts, &error));
    BOOL canonicalParts = [parts isEqualToArray:@[@"Documents", @"Library"]];
    CLCheck(canonicalParts);

    NSMutableDictionary *wrongBundle = [CLBaseManifest() mutableCopy];
    wrongBundle[@"BundleID"] = @"com.other.app";
    CLCheck(!CLAppSupportManifestFields(wrongBundle, @"com.example.app", NULL, &error));

    NSMutableDictionary *wrongFormat = [CLBaseManifest() mutableCopy];
    wrongFormat[@"Format"] = @2;
    CLCheck(!CLAppSupportManifestFields(wrongFormat, @"com.example.app", NULL, &error));

    NSMutableDictionary *missingTimestamp = [CLBaseManifest() mutableCopy];
    [missingTimestamp removeObjectForKey:@"Created"];
    CLCheck(!CLAppSupportManifestFields(missingTimestamp, @"com.example.app", NULL, &error));

    NSMutableDictionary *duplicatePart = [CLBaseManifest() mutableCopy];
    duplicatePart[@"Parts"] = @[@"Documents", @"Documents"];
    CLCheck(!CLAppSupportManifestFields(duplicatePart, @"com.example.app", NULL, &error));

    NSMutableDictionary *unexpectedPart = [CLBaseManifest() mutableCopy];
    unexpectedPart[@"Parts"] = @[@"Documents", @"tmp"];
    CLCheck(!CLAppSupportManifestFields(unexpectedPart, @"com.example.app", NULL, &error));

    NSMutableDictionary *missingParts = [CLBaseManifest() mutableCopy];
    [missingParts removeObjectForKey:@"Parts"];
    CLCheck(!CLAppSupportManifestFields(missingParts, @"com.example.app", NULL, &error));

    NSMutableDictionary *malformedReason = [CLBaseManifest() mutableCopy];
    malformedReason[@"Reason"] = @[@"not", @"text"];
    CLCheck(!CLAppSupportManifestFields(malformedReason, @"com.example.app", NULL, &error));

    NSMutableDictionary *malformedSequence = [CLBaseManifest() mutableCopy];
    malformedSequence[@"Sequence"] = @0;
    CLCheck(!CLAppSupportManifestFields(malformedSequence, @"com.example.app", NULL, &error));

    NSMutableDictionary *stringSequence = [CLBaseManifest() mutableCopy];
    stringSequence[@"Sequence"] = @"10";
    CLCheck(!CLAppSupportManifestFields(stringSequence, @"com.example.app", NULL, &error));

    NSMutableDictionary *partialManifest = [CLBaseManifest() mutableCopy];
    partialManifest[@"Parts"] = @[@"Library"];
    parts = nil;
    CLCheck(CLAppSupportManifestFields(partialManifest, @"com.example.app", &parts, &error));
    CLCheck([parts isEqualToArray:@[@"Library"]]);

    NSMutableDictionary *typedComplete = [CLBaseManifest() mutableCopy];
    typedComplete[@"Complete"] = @1;
    CLCheck(!CLAppSupportManifestFields(typedComplete, @"com.example.app", NULL, &error));

    NSMutableDictionary *hashes = [CLBaseManifest() mutableCopy];
    hashes[@"PartHashes"] = @{ @"Documents": @"aa", @"Library": @"bb" };
    CLCheck(CLAppSupportManifestFields(hashes, @"com.example.app", NULL, &error));
    NSMutableDictionary *missingHash = [hashes mutableCopy];
    missingHash[@"PartHashes"] = @{ @"Documents": @"aa" };
    CLCheck(!CLAppSupportManifestFields(missingHash, @"com.example.app", NULL, &error));
    NSMutableDictionary *extraHash = [hashes mutableCopy];
    extraHash[@"PartHashes"] = @{ @"Documents": @"aa", @"Library": @"bb", @"tmp": @"cc" };
    CLCheck(!CLAppSupportManifestFields(extraHash, @"com.example.app", NULL, &error));
    NSMutableDictionary *badHash = [hashes mutableCopy];
    badHash[@"PartHashes"] = @{ @"Documents": @1, @"Library": @"bb" };
    CLCheck(!CLAppSupportManifestFields(badHash, @"com.example.app", NULL, &error));
}

static void TestNumericOrdering(void)
{
    NSDate *sameTime = [NSDate dateWithTimeIntervalSinceReferenceDate:100];
    CLCheck(CLAppsSupportBackupSequence(@"2026-11-09 20.00.00") == 1);
    CLCheck(CLAppsSupportBackupSequence(@"2026-11-09 20.00.00 (9)") == 9);
    CLCheck(CLAppsSupportBackupSequence(@"2026-11-09 20.00.00 (10)") == 10);
    CLCheck(CLAppsSupportCompareBackupMetadata(sameTime, 10, @"stamp (10)",
                                                sameTime, 9, @"stamp (9)") == NSOrderedDescending);
    CLCheck(CLAppsSupportCompareBackupMetadata(sameTime, 9, @"stamp (9)",
                                                sameTime, 10, @"stamp (10)") == NSOrderedAscending);
    NSDate *newer = [NSDate dateWithTimeIntervalSinceReferenceDate:101];
    CLCheck(CLAppsSupportCompareBackupMetadata(newer, 1, @"newer",
                                                sameTime, 99, @"older") == NSOrderedDescending);
}

static void TestBundleIdentifiers(void)
{
    CLCheck(CLAppSupportBundleIDValid(@"com.example.app"));
    CLCheck(CLAppSupportBundleIDValid(@"com.example-app_1"));
    CLCheck(!CLAppSupportBundleIDValid(@""));
    CLCheck(!CLAppSupportBundleIDValid(@"nodot"));
    CLCheck(!CLAppSupportBundleIDValid(@"com/example"));
    CLCheck(!CLAppSupportBundleIDValid(@"com..example"));
    CLCheck(!CLAppSupportBundleIDValid(@".com.example"));
    CLCheck(!CLAppSupportBundleIDValid(@"com.example."));
    CLCheck(!CLAppSupportBundleIDValid(@"com example.app"));
    CLCheck(!CLAppSupportBundleIDValid(@"../escape"));
}

static void TestJournalStates(void)
{
    CLCheck(CLAppsSupportJournalStateForDictionary(@{ @"State": @"Active" }) == CLAppsSupportJournalActive);
    CLCheck(CLAppsSupportJournalStateForDictionary(@{ @"State": @"Committed" }) == CLAppsSupportJournalCommitted);
    CLCheck(CLAppsSupportJournalStateForDictionary(@{ @"State": @"Other" }) == CLAppsSupportJournalUnknown);
    CLCheck(CLAppsSupportJournalStateForDictionary(@{}) == CLAppsSupportJournalUnknown);
    CLCheck(CLAppsSupportJournalStateForDictionary(nil) == CLAppsSupportJournalMissing);
    NSString *error = nil;
    CLCheck(!CLAppsSupportJournalAllowsNewRestore(CLAppsSupportJournalActive, &error) && error.length > 0);
    error = nil;
    CLCheck(!CLAppsSupportJournalAllowsNewRestore(CLAppsSupportJournalUnknown, &error) && error.length > 0);
    CLCheck(CLAppsSupportJournalAllowsNewRestore(CLAppsSupportJournalMissing, NULL));
    CLCheck(CLAppsSupportJournalAllowsNewRestore(CLAppsSupportJournalCommitted, NULL));
}

static void TestTreeSignatures(void)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *base = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [@"CLAppsTree-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSString *src = [base stringByAppendingPathComponent:@"src"];
    NSString *dst = [base stringByAppendingPathComponent:@"dst"];
    @try {
        CLCheck([fm createDirectoryAtPath:[src stringByAppendingPathComponent:@"nested"]
              withIntermediateDirectories:YES attributes:nil error:nil]);
        NSString *file = [src stringByAppendingPathComponent:@"file"];
        CLCheck([[@"original" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:file atomically:YES]);
        CLCheck(symlink(file.fileSystemRepresentation,
                        [src stringByAppendingPathComponent:@"link"].fileSystemRepresentation) == 0);

        NSString *error = nil;
        BOOL exists = NO;
        NSString *before = CLAppSupportTreeSignature(src, YES, &exists, &error);
        NSString *shape = CLAppSupportTreeSignature(src, NO, &exists, &error);
        CLCheck(before.length > 0 && shape.length > 0 && exists);

        CLCheck([fm copyItemAtPath:src toPath:dst error:nil]);
        NSString *sourceAfter = CLAppSupportTreeSignature(src, YES, &exists, &error);
        NSString *sourceShape = CLAppSupportTreeSignature(src, NO, &exists, &error);
        NSString *destinationShape = CLAppSupportTreeSignature(dst, NO, &exists, &error);
        CLCheck([before isEqualToString:sourceAfter]);       // source did not change
        CLCheck([sourceShape isEqualToString:destinationShape]); // copy has the same shape
        NSString *destinationIdentity = CLAppSupportTreeSignature(dst, YES, &exists, &error);
        CLCheck(destinationIdentity && ![before isEqualToString:destinationIdentity]);

        // A source mutation after the signature was captured must be visible.
        CLCheck([[@"original plus more" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:file atomically:YES]);
        NSString *changed = CLAppSupportTreeSignature(src, YES, &exists, &error);
        CLCheck(![before isEqualToString:changed]);
    } @finally {
        [fm removeItemAtPath:base error:nil];
    }
}

int main(void)
{
    @autoreleasepool {
        TestManifestTypes();
        TestNumericOrdering();
        TestBundleIdentifiers();
        TestJournalStates();
        TestTreeSignatures();
        if (failures) {
            fprintf(stderr, "%d Apps regression check(s) failed\n", failures);
            return 1;
        }
        puts("All Apps manifest/order/tree regression tests passed.");
    }
    return 0;
}
