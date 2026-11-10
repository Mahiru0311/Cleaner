
//
//  CLBackgroundClean.m
//  Cleaner v2.4 — the default clean, runnable without any UI.
//
//  Same work as the Cleaner page's clean button, minus the UI: scan, then
//  validate + purge each app's Library/Caches + tmp, then the enabled
//  custom rules. Crash logs are NOT included (the intent's contract is
//  apps' caches + tmp + custom rules).
//
//  Safety is the same as the UI clean: every item is re-validated
//  (CLCacheValidateItem) immediately before its targets are purged, and a
//  failed validation skips that app instead of deleting anything. A
//  cancelled or timed-out run leaves the remaining files in place; the
//  next run matches them again, so re-runs are idempotent (a second run
//  right after a full one frees 0 bytes with no errors). The purge itself
//  is per-file unlinkat, so there is no half-deleted file state.
//

#import "CLBackgroundClean.h"
#import "CLCache.h"
#import "CLCustomClean.h"
#import "CLGrant.h"
#import "CLScan.h"

NSDictionary *CLBackgroundCleanRun(NSTimeInterval budgetSeconds)
{
    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    NSTimeInterval (^elapsed)(void) = ^{ return CFAbsoluteTimeGetCurrent() - started; };

    // --- Scan (measurement cache first; the app's own scans keep it warm).
    CLCacheScanner *scanner = [CLCacheScanner new];
    dispatch_semaphore_t scanSem = dispatch_semaphore_create(0);
    __block NSArray<CLCacheItem *> *items = nil;
    __block BOOL scanLimited = NO;
    __block BOOL scanCancelled = NO;
    __block NSUInteger totalApps = 0;
    [scanner startWithProgress:nil completion:^(NSArray<CLCacheItem *> *scanItems, BOOL limited,
                                                NSString *__unused note, BOOL cancelled, NSUInteger apps) {
        items = scanItems;
        scanLimited = limited;
        scanCancelled = cancelled;
        totalApps = apps;
        dispatch_semaphore_signal(scanSem);
    }];
    // The scanner calls its completion on a background queue, so waiting
    // here (off the main thread — the Swift side guarantees that) cannot
    // deadlock. A scan is normally a few seconds with a warm cache.
    dispatch_semaphore_wait(scanSem, DISPATCH_TIME_FOREVER);
    if (scanCancelled || !items) {
        return @{ @"freed": @0, @"customFreed": @0, @"failed": @0, @"customFailed": @0,
                  @"appsCleaned": @0, @"appsSkipped": @0, @"appsRemaining": @(totalApps),
                  @"appsTotal": @(totalApps), @"partial": @YES, @"timedOut": @NO,
                  @"customSkipped": @YES, @"scanLimited": @(scanLimited),
                  @"duration": @(elapsed()), @"error": @"扫描被取消或失败，未清理任何应用。" };
    }

    // --- Purge every app's Caches + tmp, within the budget.
    CLScanCancellation *cancellation = [CLScanCancellation new];
    unsigned long long freed = 0;
    NSUInteger appsCleaned = 0;
    NSUInteger appsSkipped = 0;
    NSUInteger failed = 0;
    NSUInteger appsRemaining = 0;
    BOOL timedOut = NO;
    for (CLCacheItem *item in items) {
        if (item.crashLogs || !item.containerPath.length) continue;
        if (elapsed() >= budgetSeconds) { timedOut = YES; appsRemaining++; continue; }
        NSString *reason = nil;
        if (item.limited || !CLCacheValidateItem(item, &reason)) {
            // Validation failure is a skip, not a failure: nothing was
            // deleted, and the app is simply left for the next run.
            appsSkipped++;
            cl_log(@"background clean: skipping %@ (%@)", item.name, reason ?: @"受限");
            continue;
        }
        BOOL itemOk = YES;
        for (CLCacheTargetRecord *record in item.targetRecords) {
            if (cancellation.isCancelled) break;
            NSString *r = nil;
            if (!CLCacheValidateItem(item, &r)) { itemOk = NO; break; }
            if (!cl_purge_contents_cancellable(record.path, &freed, cancellation)) {
                if (cancellation.isCancelled) break;
                itemOk = NO;
            }
        }
        if (itemOk) appsCleaned++;
        else failed++;
        cl_log(@"background clean: %@ freed %llu bytes", item.name, freed);
    }

    // --- Enabled custom rules, only if time remains.
    unsigned long long customFreed = 0;
    NSUInteger customFailed = 0;
    BOOL customSkipped = NO;
    if (elapsed() < budgetSeconds) {
        dispatch_semaphore_t customSem = dispatch_semaphore_create(0);
        __block NSDictionary *customResult = nil;
        cl_custom_clean_run(items, nil, ^(NSDictionary *result) {
            customResult = result;
            dispatch_semaphore_signal(customSem);
        });
        dispatch_semaphore_wait(customSem, DISPATCH_TIME_FOREVER);
        customFreed = [customResult[@"freed"] unsignedLongLongValue];
        customFailed = [customResult[@"failed"] unsignedIntegerValue];
    } else {
        customSkipped = YES;
        timedOut = YES;
    }

    BOOL partial = timedOut || scanLimited || failed > 0 || customFailed > 0;
    return @{ @"freed": @(freed), @"customFreed": @(customFreed),
              @"failed": @(failed), @"customFailed": @(customFailed),
              @"appsCleaned": @(appsCleaned), @"appsSkipped": @(appsSkipped),
              @"appsRemaining": @(appsRemaining), @"appsTotal": @(totalApps),
              @"partial": @(partial), @"timedOut": @(timedOut),
              @"customSkipped": @(customSkipped), @"scanLimited": @(scanLimited),
              @"duration": @(elapsed()) };
}
