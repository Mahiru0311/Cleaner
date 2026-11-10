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

            // --- v2.4 rule validation: age/size/subfolder sanity. ---
            NSString *vreason = nil;
            NSDictionary *vrule = cl_custom_clean_make_rule_full(@"*", @"extension", @".mp4", @30, nil, nil, nil);
            check(cl_custom_clean_validate_rule(vrule, &vreason), @"age filter rule valid");
            vrule = cl_custom_clean_make_rule_full(@"*", @"extension", @".mp4", @4000, nil, nil, nil);
            check(!cl_custom_clean_validate_rule(vrule, &vreason), @"age over 3650 days refused");
            vrule = cl_custom_clean_make_rule_full(@"*", @"extension", @".mp4", nil, @1000, @100, nil);
            check(!cl_custom_clean_validate_rule(vrule, &vreason), @"min size above max size refused");
            vrule = cl_custom_clean_make_rule_full(@"*", @"extension", @".mp4", nil, @100, @1000, nil);
            check(cl_custom_clean_validate_rule(vrule, &vreason), @"min below max size valid");
            vrule = cl_custom_clean_make_rule_full(@"*", @"extension", @".mp4", nil, nil, nil, @"Documents/foo");
            check(!cl_custom_clean_validate_rule(vrule, &vreason), @"subfolder outside Caches/tmp refused");
            vrule = cl_custom_clean_make_rule_full(@"*", @"extension", @".mp4", nil, nil, nil, @"Library/Caches/sub");
            check(cl_custom_clean_validate_rule(vrule, &vreason), @"subfolder under Caches allowed");
            vrule = cl_custom_clean_make_rule_full(@"*", @"extension", @".mp4", nil, nil, nil, @"com.foo");
            check(cl_custom_clean_validate_rule(vrule, &vreason), @"bare subfolder name allowed (means under Caches)");
            vrule = cl_custom_clean_make_rule_full(@"*", @"extension", @".mp4", nil, nil, nil, @"Documents");
            check(cl_custom_clean_validate_rule(vrule, &vreason), @"bare name Documents means Library/Caches/Documents");
            vrule = cl_custom_clean_make_rule_full(@"*", @"extension", @".mp4", nil, nil, nil, @"tmp");
            check(cl_custom_clean_validate_rule(vrule, &vreason), @"bare name tmp means the tmp directory");
            vrule = cl_custom_clean_make_rule_full(@"*", @"extension", @".mp4", nil, nil, nil, @"Library/../Caches");
            check(!cl_custom_clean_validate_rule(vrule, &vreason), @"subfolder with dot-dot refused");
            vrule = cl_custom_clean_make_rule_full(@"*", @"folder", @"Library/Caches/x", @30, nil, nil, nil);
            check(!cl_custom_clean_validate_rule(vrule, &vreason), @"folder rule with age filter refused");
            vrule = cl_custom_clean_make_rule_full(@"*", @"name", @"thumb", nil, nil, nil, @"tmp");
            check(cl_custom_clean_validate_rule(vrule, &vreason), @"name rule scoped to tmp valid");

            // --- v2.4 filters, dry-run math, idempotency, interrupt safety. ---
            // A fresh container so these tests do not depend on the state
            // the earlier blocks left behind.
            NSString *container2 = [base stringByAppendingPathComponent:@"App-UUID-2"];
            mkdirs([container2 stringByAppendingPathComponent:@"Library/Caches/sub"]);
            mkdirs([container2 stringByAppendingPathComponent:@"tmp"]);
            put([container2 stringByAppendingPathComponent:@"Library/Caches/new.mp4"], [@"" stringByPaddingToLength:100 withString:@"x" startingAtIndex:0]);
            put([container2 stringByAppendingPathComponent:@"Library/Caches/old.mp4"], [@"" stringByPaddingToLength:200 withString:@"x" startingAtIndex:0]);
            put([container2 stringByAppendingPathComponent:@"Library/Caches/sub/old2.mp4"], [@"" stringByPaddingToLength:300 withString:@"x" startingAtIndex:0]);
            put([container2 stringByAppendingPathComponent:@"Library/Caches/sub/new2.mp4"], [@"" stringByPaddingToLength:400 withString:@"x" startingAtIndex:0]);
            put([container2 stringByAppendingPathComponent:@"Library/Caches/big.log"], [@"" stringByPaddingToLength:5000 withString:@"x" startingAtIndex:0]);
            put([container2 stringByAppendingPathComponent:@"Library/Caches/small.log"], @"0123456789");
            put([container2 stringByAppendingPathComponent:@"tmp/temp.mp4"], [@"" stringByPaddingToLength:600 withString:@"x" startingAtIndex:0]);
            NSDate *fortyDaysAgo = [NSDate dateWithTimeIntervalSinceNow:-40 * 86400];
            check([fm setAttributes:@{ NSFileModificationDate: fortyDaysAgo }
                       ofItemAtPath:[container2 stringByAppendingPathComponent:@"Library/Caches/old.mp4"] error:nil],
                  @"set old file mtime");
            check([fm setAttributes:@{ NSFileModificationDate: fortyDaysAgo }
                       ofItemAtPath:[container2 stringByAppendingPathComponent:@"Library/Caches/sub/old2.mp4"] error:nil],
                  @"set old subfolder file mtime");
            // Age filter, dry-run first: only the two 40-day-old .mp4s
            // match (200 + 300); the three new .mp4s are skipped, not errors.
            CLCleanMatchOptions ageOpts = { .minAgeSeconds = 30 * 86400.0, .dryRun = YES };
            CLCleanMatchResult ageDry;
            check(cl_clean_matching_files_filtered(container2, @[@".mp4"], nil, nil, &ageOpts, &ageDry, NULL) &&
                  ageDry.matched == 2 && ageDry.matchedBytes == 500 && ageDry.skipped == 3 && ageDry.failed == 0,
                  @"age filter dry-run: 2 old files, 500 bytes, 3 skipped");
            check(has([container2 stringByAppendingPathComponent:@"Library/Caches/old.mp4"]),
                  @"dry-run deletes nothing");
            ageOpts.dryRun = NO;
            CLCleanMatchResult ageRun;
            check(cl_clean_matching_files_filtered(container2, @[@".mp4"], nil, nil, &ageOpts, &ageRun, NULL) &&
                  ageRun.freed == 500 && ageRun.failed == 0,
                  @"age filter run frees exactly the dry-run bytes");
            check(!has([container2 stringByAppendingPathComponent:@"Library/Caches/old.mp4"]),
                  @"old file gone after the age-filtered run");
            check(has([container2 stringByAppendingPathComponent:@"Library/Caches/new.mp4"]),
                  @"new file kept by the age filter");
            // Size filter: only big.log (5000) is over 1000 bytes.
            CLCleanMatchOptions sizeOpts = { .minSize = 1000, .dryRun = YES };
            CLCleanMatchResult sizeDry;
            check(cl_clean_matching_files_filtered(container2, @[@".log"], nil, nil, &sizeOpts, &sizeDry, NULL) &&
                  sizeDry.matched == 1 && sizeDry.matchedBytes == 5000 && sizeDry.skipped == 1,
                  @"size filter dry-run: 1 big file, 5000 bytes, 1 skipped");
            sizeOpts.dryRun = NO;
            CLCleanMatchResult sizeRun;
            check(cl_clean_matching_files_filtered(container2, @[@".log"], nil, nil, &sizeOpts, &sizeRun, NULL) &&
                  sizeRun.freed == 5000 && sizeRun.failed == 0,
                  @"size filter run frees the big log only");
            check(has([container2 stringByAppendingPathComponent:@"Library/Caches/small.log"]),
                  @"small log kept by the size filter");
            // Max-size filter: only new.mp4 (100) is at most 150 bytes.
            CLCleanMatchOptions maxOpts = { .maxSize = 150 };
            CLCleanMatchResult maxRun;
            check(cl_clean_matching_files_filtered(container2, @[@".mp4"], nil, nil, &maxOpts, &maxRun, NULL) &&
                  maxRun.matched == 1 && maxRun.matchedBytes == 100 && maxRun.skipped == 2,
                  @"max-size filter: only the 100-byte file matches");
            // Subfolder scope: only sub/new2.mp4 (400) is under Caches/sub.
            CLCleanMatchOptions subOpts = { .roots = @[@"Library/Caches/sub"] };
            CLCleanMatchResult subRun;
            check(cl_clean_matching_files_filtered(container2, @[@".mp4"], nil, nil, &subOpts, &subRun, NULL) &&
                  subRun.matched == 1 && subRun.matchedBytes == 400 && subRun.skipped == 0,
                  @"subfolder scope: only the subfolder file matches");
            // A root outside Caches/tmp is refused outright.
            CLCleanMatchOptions badOpts = { .roots = @[@"Documents"] };
            CLCleanMatchResult badRun;
            NSString *badReason = nil;
            check(!cl_clean_matching_files_filtered(container2, @[@".mp4"], nil, nil, &badOpts, &badRun, &badReason),
                  @"subfolder root outside Caches/tmp refused");
            // Idempotent re-run: the subfolder call again frees 0, no errors.
            CLCleanMatchResult subAgain;
            check(cl_clean_matching_files_filtered(container2, @[@".mp4"], nil, nil, &subOpts, &subAgain, NULL) &&
                  subAgain.freed == 0 && subAgain.failed == 0 && subAgain.matched == 0,
                  @"idempotent re-run frees 0 with no errors");
            // Interrupt safety: a pre-cancelled run deletes nothing, and
            // the next full run still works.
            CLScanCancellation *preCancelled = [CLScanCancellation new];
            [preCancelled cancel];
            CLCleanMatchOptions cancelOpts = { .cancellation = preCancelled };
            CLCleanMatchResult cancelRun;
            check(cl_clean_matching_files_filtered(container2, @[@".mp4"], nil, nil, &cancelOpts, &cancelRun, NULL) &&
                  cancelRun.freed == 0 && cancelRun.failed == 0,
                  @"pre-cancelled run deletes nothing");
            check(has([container2 stringByAppendingPathComponent:@"tmp/temp.mp4"]),
                  @"cancelled run leaves the files in place");
            CLCleanMatchResult fullRun;
            check(cl_clean_matching_files_filtered(container2, @[@".mp4"], nil, nil, NULL, &fullRun, NULL) &&
                  fullRun.freed == 600 && fullRun.failed == 0,
                  @"the run after a cancelled one still frees the remainder");
            // Mid-run cancel: 2000 files, cancel after 5 ms from another
            // thread. Either the first run finishes (freed1 == total) or
            // it is interrupted — either way the two runs together free
            // exactly the total, with no errors on the second run.
            NSString *bulk = [container2 stringByAppendingPathComponent:@"Library/Caches/bulk"];
            mkdirs(bulk);
            for (int i = 0; i < 2000; i++) {
                put([bulk stringByAppendingPathComponent:[NSString stringWithFormat:@"f%04d.mp4", i]], @"0123456789");
            }
            CLScanCancellation *midCancel = [CLScanCancellation new];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_MSEC)),
                           dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ [midCancel cancel]; });
            CLCleanMatchOptions midOpts = { .cancellation = midCancel };
            CLCleanMatchResult mid1, mid2;
            cl_clean_matching_files_filtered(container2, @[@".mp4"], nil, nil, &midOpts, &mid1, NULL);
            cl_clean_matching_files_filtered(container2, @[@".mp4"], nil, nil, NULL, &mid2, NULL);
            check(mid1.failed == 0 && mid2.failed == 0 && mid1.freed + mid2.freed == 20000,
                  @"mid-run cancel + re-run frees exactly the total, no errors");
            check([fm contentsOfDirectoryAtPath:bulk error:nil].count == 0,
                  @"no bulk files remain after the re-run");

            // --- Dry-run preview + single-rule run, through the real API. ---
            // The rule is passed in directly (no rules-plist writes).
            NSString *container3 = [base stringByAppendingPathComponent:@"App-UUID-3"];
            mkdirs([container3 stringByAppendingPathComponent:@"Library/Caches"]);
            put([container3 stringByAppendingPathComponent:@"Library/Caches/a.mp4"], @"12345");
            put([container3 stringByAppendingPathComponent:@"Library/Caches/b.mp4"], @"1234567");
            CLCacheItem *item3 = [CLCacheItem new];
            item3.bundleID = @"com.example.three"; item3.name = @"Test3"; item3.containerPath = container3;
            NSDictionary *rule3 = cl_custom_clean_make_rule_full(@"*", @"extension", @".mp4", nil, nil, nil, nil);
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            __block NSDictionary *dry = nil;
            cl_custom_clean_dry_run(@[item3], rule3, nil, ^(NSDictionary *result) {
                dry = result; dispatch_semaphore_signal(sem);
            });
            dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
            check([dry[@"matched"] unsignedIntegerValue] == 2 &&
                  [dry[@"bytes"] unsignedLongLongValue] == 12,
                  @"dry-run preview math: 2 files, 12 bytes");
            check(has([container3 stringByAppendingPathComponent:@"Library/Caches/a.mp4"]),
                  @"dry-run preview deletes nothing");
            __block NSDictionary *one = nil;
            cl_custom_clean_run_one_rule(@[item3], rule3, nil, ^(NSDictionary *result) {
                one = result; dispatch_semaphore_signal(sem);
            });
            dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
            check([one[@"freed"] unsignedLongLongValue] == 12 &&
                  [one[@"failed"] unsignedIntegerValue] == 0,
                  @"single-rule run frees exactly the dry-run bytes");
            check(!has([container3 stringByAppendingPathComponent:@"Library/Caches/a.mp4"]),
                  @"single-rule run deletes the files");
            __block NSDictionary *again = nil;
            cl_custom_clean_run_one_rule(@[item3], rule3, nil, ^(NSDictionary *result) {
                again = result; dispatch_semaphore_signal(sem);
            });
            dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
            check([again[@"freed"] unsignedLongLongValue] == 0 &&
                  [again[@"failed"] unsignedIntegerValue] == 0,
                  @"single-rule idempotent re-run frees 0 with no errors");

            // --- v2.5 directory rules: validation, pasted paths, execution. ---
            NSString *container4 = [base stringByAppendingPathComponent:@"App-UUID-4"];
            mkdirs([container4 stringByAppendingPathComponent:@"Library/Caches/videos"]);
            mkdirs([container4 stringByAppendingPathComponent:@"Library/Caches/other"]);
            mkdirs([container4 stringByAppendingPathComponent:@"Documents/Downloads"]);
            mkdirs([container4 stringByAppendingPathComponent:@"tmp"]);
            put([container4 stringByAppendingPathComponent:@"Library/Caches/videos/a.mp4"], @"12345");
            put([container4 stringByAppendingPathComponent:@"Library/Caches/videos/b.mov"], @"1234567");
            put([container4 stringByAppendingPathComponent:@"Library/Caches/videos/c.jpg"], @"123");
            put([container4 stringByAppendingPathComponent:@"Library/Caches/other/d.mp4"], @"12345");
            put([container4 stringByAppendingPathComponent:@"Documents/Downloads/e.mp4"], @"12345");
            put([container4 stringByAppendingPathComponent:@"Documents/Downloads/f.txt"], @"123");
            put([container4 stringByAppendingPathComponent:@"tmp/g.mp4"], @"12345");
            CLCacheItem *item4 = [CLCacheItem new];
            item4.bundleID = @"com.example.four"; item4.name = @"Test4"; item4.containerPath = container4;

            // Validation.
            NSString *dreason = nil;
            NSDictionary *dAll = cl_custom_clean_make_directory_rule(@"com.example.four", @"Library/Caches/videos", CLCustomRuleScopeAll, nil, nil, nil, nil, nil);
            check(cl_custom_clean_validate_rule(dAll, &dreason), @"directory scope-all valid");
            NSDictionary *dAllBad = cl_custom_clean_make_directory_rule(@"com.example.four", @"Library/Caches/videos", CLCustomRuleScopeAll, @".mp4", nil, nil, nil, nil);
            check(!cl_custom_clean_validate_rule(dAllBad, &dreason), @"directory scope-all with filters refused");
            NSDictionary *dNoCond = cl_custom_clean_make_directory_rule(@"com.example.four", @"Library/Caches/videos", CLCustomRuleScopeFiltered, nil, nil, nil, nil, nil);
            check(!cl_custom_clean_validate_rule(dNoCond, &dreason), @"directory filtered needs at least one condition");
            NSDictionary *dFilt = cl_custom_clean_make_directory_rule(@"com.example.four", @"Library/Caches/videos", CLCustomRuleScopeFiltered, @".mp4", nil, nil, nil, nil);
            check(cl_custom_clean_validate_rule(dFilt, &dreason), @"directory filtered with an extension valid");
            NSDictionary *dDocs = cl_custom_clean_make_directory_rule(@"com.example.four", @"Documents", CLCustomRuleScopeAll, nil, nil, nil, nil, nil);
            check(!cl_custom_clean_validate_rule(dDocs, &dreason), @"directory rule on Documents itself refused");
            NSDictionary *dLib = cl_custom_clean_make_directory_rule(@"com.example.four", @"Library", CLCustomRuleScopeAll, nil, nil, nil, nil, nil);
            check(!cl_custom_clean_validate_rule(dLib, &dreason), @"directory rule on Library itself refused");
            NSDictionary *dRoot = cl_custom_clean_make_directory_rule(@"com.example.four", @"", CLCustomRuleScopeAll, nil, nil, nil, nil, nil);
            check(!cl_custom_clean_validate_rule(dRoot, &dreason), @"directory rule on the container root refused");
            NSDictionary *dBadExt = cl_custom_clean_make_directory_rule(@"com.example.four", @"Library/Caches/videos", CLCustomRuleScopeFiltered, @",,", nil, nil, nil, nil);
            check(!cl_custom_clean_validate_rule(dBadExt, &dreason), @"directory filtered with a nonsense extensions CSV refused");
            // Extensions CSV normalization.
            NSArray<NSString *> *parsed = cl_custom_clean_parse_extensions(@".MP4, mov，.JPG,, .mp4");
            check([parsed isEqualToArray:@[@".mp4", @".mov", @".jpg"]], @"extensions CSV normalized (case, dots, Chinese comma, deduped)");
            check(cl_custom_clean_parse_extensions(nil).count == 0, @"nil extensions CSV parses to empty");
            check(cl_custom_clean_parse_extensions(@",,").count == 0, @"separator-only CSV parses to empty");

            // Pasted-path resolution.
            NSString *rbid = nil, *rrel = nil, *rreason = nil;
            check(cl_custom_clean_resolve_pasted_path([container4 stringByAppendingPathComponent:@"Library/Caches/videos"], @[item4], nil, &rbid, &rrel, &rreason) &&
                  [rbid isEqualToString:@"com.example.four"] && [rrel isEqualToString:@"Library/Caches/videos"],
                  @"absolute pasted path resolves to app + relative path");
            check(!cl_custom_clean_resolve_pasted_path([base stringByAppendingPathComponent:@"outside/x"], @[item4], nil, &rbid, &rrel, &rreason),
                  @"absolute path outside any scanned container refused");
            check(!cl_custom_clean_resolve_pasted_path(container4, @[item4], nil, &rbid, &rrel, &rreason),
                  @"absolute container root refused");
            check(!cl_custom_clean_resolve_pasted_path(@"../outside", @[item4], @"com.example.four", &rbid, &rrel, &rreason),
                  @"relative path with leading dot-dot refused");
            check(!cl_custom_clean_resolve_pasted_path(@".", @[item4], @"com.example.four", &rbid, &rrel, &rreason),
                  @"relative dot (container root) refused");
            check(cl_custom_clean_resolve_pasted_path(@"Library/Caches/videos", @[item4], @"com.example.four", &rbid, &rrel, &rreason) &&
                  [rrel isEqualToString:@"Library/Caches/videos"],
                  @"relative path resolves under the given app");
            check(!cl_custom_clean_resolve_pasted_path(@"Library/Caches/videos", @[item4], nil, &rbid, &rrel, &rreason),
                  @"relative path without an app refused");

            // Execution through the real API: scope-all dry-run + run, then
            // the filtered rule inside Documents/Downloads (rootsMayBeAnywhere).
            // A scope-all dry-run measures the whole directory: matched is
            // 1 (one directory), bytes is the total inside it.
            __block NSDictionary *dry4 = nil;
            cl_custom_clean_dry_run(@[item4], dAll, nil, ^(NSDictionary *result) {
                dry4 = result; dispatch_semaphore_signal(sem);
            });
            dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
            check([dry4[@"matched"] unsignedIntegerValue] == 1 &&
                  [dry4[@"bytes"] unsignedLongLongValue] == 15,
                  @"directory scope-all dry-run: 1 directory, 15 bytes");
            check(has([container4 stringByAppendingPathComponent:@"Library/Caches/videos/a.mp4"]),
                  @"directory dry-run deletes nothing");
            __block NSDictionary *run4 = nil;
            cl_custom_clean_run_one_rule(@[item4], dAll, nil, ^(NSDictionary *result) {
                run4 = result; dispatch_semaphore_signal(sem);
            });
            dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
            check([run4[@"freed"] unsignedLongLongValue] == 15 &&
                  [run4[@"failed"] unsignedIntegerValue] == 0,
                  @"directory scope-all run frees the whole directory");
            check(has([container4 stringByAppendingPathComponent:@"Library/Caches/videos"]),
                  @"directory itself stays after a scope-all run");
            check(!has([container4 stringByAppendingPathComponent:@"Library/Caches/videos/b.mov"]),
                  @"directory contents gone after a scope-all run");
            check(has([container4 stringByAppendingPathComponent:@"Library/Caches/other/d.mp4"]),
                  @"sibling directory untouched by a scope-all rule");
            // Filtered rule in Documents/Downloads: only e.mp4 matches, f.txt stays.
            NSDictionary *dDl = cl_custom_clean_make_directory_rule(@"com.example.four", @"Documents/Downloads", CLCustomRuleScopeFiltered, @".mp4", nil, nil, nil, nil);
            __block NSDictionary *dryDl = nil;
            cl_custom_clean_dry_run(@[item4], dDl, nil, ^(NSDictionary *result) {
                dryDl = result; dispatch_semaphore_signal(sem);
            });
            dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
            check([dryDl[@"matched"] unsignedIntegerValue] == 1 &&
                  [dryDl[@"bytes"] unsignedLongLongValue] == 5,
                  @"directory filtered dry-run inside Documents: 1 file, 5 bytes");
            __block NSDictionary *runDl = nil;
            cl_custom_clean_run_one_rule(@[item4], dDl, nil, ^(NSDictionary *result) {
                runDl = result; dispatch_semaphore_signal(sem);
            });
            dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
            check([runDl[@"freed"] unsignedLongLongValue] == 5 &&
                  [runDl[@"failed"] unsignedIntegerValue] == 0,
                  @"directory filtered run frees only the matching file");
            check(!has([container4 stringByAppendingPathComponent:@"Documents/Downloads/e.mp4"]),
                  @"matching file in Documents gone");
            check(has([container4 stringByAppendingPathComponent:@"Documents/Downloads/f.txt"]),
                  @"non-matching file in Documents kept");
            // Idempotent re-run frees 0.
            __block NSDictionary *again4 = nil;
            cl_custom_clean_run_one_rule(@[item4], dDl, nil, ^(NSDictionary *result) {
                again4 = result; dispatch_semaphore_signal(sem);
            });
            dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
            check([again4[@"freed"] unsignedLongLongValue] == 0 &&
                  [again4[@"failed"] unsignedIntegerValue] == 0,
                  @"directory rule idempotent re-run frees 0 with no errors");
            // rootsMayBeAnywhere unset still refuses a non-Caches/tmp root.
            CLCleanMatchOptions noAnywhere = { .roots = @[@"Documents/Downloads"] };
            CLCleanMatchResult naResult;
            NSString *naReason = nil;
            check(!cl_clean_matching_files_filtered(container4, @[@".mp4"], nil, nil, &noAnywhere, &naResult, &naReason),
                  @"rootsMayBeAnywhere unset still refuses Documents");

            // Plist round-trip through the test hook: save → reload → present;
            // edit keeps the same UUID; disable; delete.
            NSString *rulesPlist = [base stringByAppendingPathComponent:@"rules.plist"];
            cl_custom_clean_set_plist_path_for_testing(rulesPlist);
            cl_custom_clean_save_rules(@[dFilt]);
            NSArray<NSDictionary *> *loaded = cl_custom_clean_rules();
            check(loaded.count == 1, @"rules plist round-trip: one rule saved and reloaded");
            NSDictionary *loadedRule = loaded[0];
            check([loadedRule[CLCustomRuleBundleIDKey] isEqualToString:@"com.example.four"] &&
                  [loadedRule[CLCustomRulePatternKey] isEqualToString:@"Library/Caches/videos"] &&
                  [loadedRule[CLCustomRuleScopeKey] isEqualToString:CLCustomRuleScopeFiltered],
                  @"reloaded rule keeps bundle, pattern and scope");
            check([(NSString *)loadedRule[CLCustomRuleIDKey] length] > 0, @"reloaded rule has a UUID");
            check([loadedRule[CLCustomRuleEnabledKey] boolValue], @"new rule is enabled");
            check([cl_custom_clean_rule_summary(loadedRule) containsString:@"Library/Caches/videos"],
                  @"rule summary shows the picked directory");
            // Edit (same UUID, new pattern) — like the picker saving an edited rule.
            NSString *ruleID = loadedRule[CLCustomRuleIDKey];
            NSMutableDictionary *edited = [loadedRule mutableCopy];
            edited[CLCustomRulePatternKey] = @"Library/Caches/other";
            cl_custom_clean_save_rules(@[edited]);
            NSArray<NSDictionary *> *reloaded2 = cl_custom_clean_rules();
            check(reloaded2.count == 1 &&
                  [reloaded2[0][CLCustomRuleIDKey] isEqualToString:ruleID] &&
                  [reloaded2[0][CLCustomRulePatternKey] isEqualToString:@"Library/Caches/other"],
                  @"edit keeps the same UUID and changes the pattern");
            // Disable, then delete.
            NSMutableDictionary *disabled = [reloaded2[0] mutableCopy];
            disabled[CLCustomRuleEnabledKey] = @NO;
            cl_custom_clean_save_rules(@[disabled]);
            check(![cl_custom_clean_rules()[0][CLCustomRuleEnabledKey] boolValue],
                  @"disabled rule stays disabled after reload");
            cl_custom_clean_save_rules(@[]);
            check(cl_custom_clean_rules().count == 0, @"deleted rule is gone after reload");

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
            check(store.totalAppCount == 114, @"totalAppCount is the measured app total (v2.5: distinct bundle IDs, not containers)");
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
