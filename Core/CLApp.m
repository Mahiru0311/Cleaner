//
//  CLApp.m
//  Cleaner v2 — extracted from WQApps.m (v0.1, commit 201591c8), renamed.
//  Cleaner app backup and restore manager
//  GPL-3.0-or-later.
//

#import "CLApp.h"

#import "CLLaunchServices.h"

#import "CLAppSupport.h"
#import <errno.h>
#import <sys/stat.h>

@implementation CLAppItem
@end
static NSArray<NSString *> *cl_app_data_parts(void) { return @[@"Documents", @"Library", @"tmp"]; }
static NSArray<NSString *> *cl_app_backup_parts(void) { return @[@"Documents", @"Library"]; }

static NSString *cl_app_backup_root_for_bundle(NSString *bundleID)
{
    if (!CLAppSupportBundleIDValid(bundleID)) return nil;
    return [cl_app_backup_root() stringByAppendingPathComponent:bundleID];
}

// An app backup is AppBackups/<bundle id>/<date>/{Documents,Library} plus a
// manifest. It is built in a hidden staging folder and only renamed into
// place, with the manifest, once every file was copied: a failed or
// interrupted backup never shows up as one that can be restored.
static NSString *const kCLBackupManifest = @".wqbackup.plist";
static NSString *const kCLBackupStagingPrefix = @".incomplete-";
static NSString *const kCLBackupReasonBeforeRestore = @"Before restore";

static NSDictionary *cl_backup_manifest(NSString *backup)
{
    struct stat st;
    NSString *path = [backup stringByAppendingPathComponent:kCLBackupManifest];
    if (lstat(path.fileSystemRepresentation, &st) != 0 || !S_ISREG(st.st_mode)) return nil;
    NSDictionary *manifest = [NSDictionary dictionaryWithContentsOfFile:path];
    return [manifest isKindOfClass:NSDictionary.class] ? manifest : nil;
}

static BOOL cl_backup_root_child(NSString *path, NSString *bundleID)
{
    NSString *root = [cl_app_backup_root_for_bundle(bundleID) stringByStandardizingPath];
    if (!root.length) return NO;
    NSString *parent = [path.stringByDeletingLastPathComponent stringByStandardizingPath];
    NSString *name = path.lastPathComponent;
    return [parent isEqualToString:root] && name.length && ![name hasPrefix:@"."];
}

static BOOL cl_backup_parts_on_disk(NSString *backup, NSArray<NSString *> *expectedParts,
                                    BOOL hasManifest, NSString **error)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *listError = nil;
    NSArray *children = [fm contentsOfDirectoryAtPath:backup error:&listError];
    if (!children) {
        if (error) *error = listError.localizedDescription ?: @"The backup folder cannot be read";
        return NO;
    }
    NSMutableSet *actual = [NSMutableSet set];
    for (NSString *name in children) {
        if (hasManifest && [name isEqualToString:kCLBackupManifest]) continue;
        if (![(@[@"Documents", @"Library"]) containsObject:name]) {
            if (error) *error = [NSString stringWithFormat:@"The backup contains an unexpected item: %@", name];
            return NO;
        }
        NSString *part = [backup stringByAppendingPathComponent:name];
        struct stat st;
        if (lstat(part.fileSystemRepresentation, &st) != 0 || !S_ISDIR(st.st_mode)) {
            if (error) *error = [NSString stringWithFormat:@"The backup part %@ is not a directory", name];
            return NO;
        }
        NSError *partError = nil;
        if (![fm contentsOfDirectoryAtPath:part error:&partError]) {
            if (error) *error = [NSString stringWithFormat:@"The backup part %@ cannot be read: %@", name,
                                 partError.localizedDescription ?: @"unknown error"];
            return NO;
        }
        [actual addObject:name];
    }
    if (![actual isEqualToSet:[NSSet setWithArray:expectedParts]]) {
        if (error) *error = @"The backup manifest does not match the on-disk parts";
        return NO;
    }
    return YES;
}

// Strict validation is used for current backups and recovery material. A
// no-manifest directory is accepted only as an explicitly unverified legacy
// backup; it never supplies implicit purge instructions for recovery.
static BOOL cl_validate_backup(NSString *backup, NSString *bundleID, BOOL allowLegacy,
                               NSArray<NSString *> **partsOut, NSDictionary **manifestOut,
                               BOOL *verifiedOut, NSString **error)
{
    if (!cl_backup_root_child(backup, bundleID)) {
        if (error) *error = @"The backup path is outside this app's backup folder";
        return NO;
    }
    struct stat backupStat;
    if (lstat(backup.fileSystemRepresentation, &backupStat) != 0 || !S_ISDIR(backupStat.st_mode)) {
        if (error) *error = @"The backup folder is missing";
        return NO;
    }
    NSString *manifestPath = [backup stringByAppendingPathComponent:kCLBackupManifest];
    struct stat manifestStat;
    int manifestResult = lstat(manifestPath.fileSystemRepresentation, &manifestStat);
    if (manifestResult != 0 && errno != ENOENT) {
        if (error) *error = [NSString stringWithFormat:@"Cannot inspect the backup manifest (errno %d)", errno];
        return NO;
    }
    BOOL hasManifest = manifestResult == 0;
    if (hasManifest && !S_ISREG(manifestStat.st_mode)) {
        if (error) *error = @"The backup manifest is not a regular file";
        return NO;
    }
    NSDictionary *manifest = hasManifest ? cl_backup_manifest(backup) : nil;
    NSArray<NSString *> *parts = nil;
    BOOL verified = NO;
    if (hasManifest) {
        NSString *manifestError = nil;
        if (!CLAppSupportManifestFields(manifest, bundleID, &parts, &manifestError)) {
            if (error) *error = manifestError ?: @"The backup manifest is invalid";
            return NO;
        }
        verified = YES;
    } else {
        if (!allowLegacy) {
            if (error) *error = @"The safety backup has no typed manifest";
            return NO;
        }
        NSMutableArray *legacyParts = [NSMutableArray new];
        NSError *listError = nil;
        NSArray *children = [NSFileManager.defaultManager contentsOfDirectoryAtPath:backup error:&listError];
        if (!children) {
            if (error) *error = listError.localizedDescription ?: @"The legacy backup cannot be read";
            return NO;
        }
        for (NSString *name in children) {
            if (![(@[@"Documents", @"Library"]) containsObject:name]) {
                if (error) *error = [NSString stringWithFormat:@"The legacy backup contains an unexpected item: %@", name];
                return NO;
            }
            [legacyParts addObject:name];
        }
        parts = [legacyParts sortedArrayUsingSelector:@selector(compare:)];
    }
    if (!cl_backup_parts_on_disk(backup, parts, hasManifest, error)) return NO;
    if (partsOut) *partsOut = parts;
    if (manifestOut) *manifestOut = manifest;
    if (verifiedOut) *verifiedOut = verified;
    return YES;
}

// Newest first. Current backups are ordered by their manifest timestamp and
// numeric collision sequence, never by the display name's text ordering.
NSArray<NSDictionary *> *cl_app_backups(NSString *bundleID)
{
    NSString *root = cl_app_backup_root_for_bundle(bundleID);
    NSArray *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil];
    NSMutableArray *out = [NSMutableArray new];
    for (NSString *name in names) {
        if ([name hasPrefix:@"."]) continue;
        NSString *path = [root stringByAppendingPathComponent:name];
        struct stat st;
        if (lstat(path.fileSystemRepresentation, &st) != 0 || !S_ISDIR(st.st_mode)) continue;
        NSString *validationError = nil;
        NSArray *parts = nil;
        NSDictionary *manifest = nil;
        BOOL verified = NO;
        BOOL valid = cl_validate_backup(path, bundleID, YES, &parts, &manifest, &verified, &validationError);
        BOOL hasManifest = lstat([[path stringByAppendingPathComponent:kCLBackupManifest] fileSystemRepresentation], &st) == 0;
        if (!valid && !hasManifest) continue;
        NSDate *created = [manifest[@"Created"] isKindOfClass:NSDate.class] ? manifest[@"Created"] :
            [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil][NSFileModificationDate] ?: NSDate.distantPast;
        NSUInteger sequence = CLAppsSupportBackupSequence(name);
        if (CLAppSupportIsInteger(manifest[@"Sequence"]) && [manifest[@"Sequence"] unsignedIntegerValue])
            sequence = [manifest[@"Sequence"] unsignedIntegerValue];
        [out addObject:@{ @"path": path, @"name": name, @"verified": @(valid && verified),
                          @"reason": valid ? (manifest[@"Reason"] ?: @"") : (validationError ?: @"invalid manifest"),
                          @"created": created, @"sequence": @(sequence) }];
    }
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return CLAppsSupportCompareBackupMetadata(b[@"created"], [b[@"sequence"] unsignedIntegerValue], b[@"name"],
                                                    a[@"created"], [a[@"sequence"] unsignedIntegerValue], a[@"name"]);
    }];
    return out;
}

NSString *cl_backup_label(NSDictionary *__unused backup)
{
    NSString *label = backup[@"name"];
    if ([backup[@"reason"] length]) label = [label stringByAppendingFormat:@" (%@)", [backup[@"reason"] lowercaseString]];
    if (![backup[@"verified"] boolValue]) label = [label stringByAppendingString:@" (older, unverified)"];
    return label;
}

static BOOL cl_validate_container(NSString *container, NSString *bundleID, dev_t expectedDevice,
                                  ino_t expectedInode, NSString **error)
{
    struct stat st;
    if (lstat(container.fileSystemRepresentation, &st) != 0 || !S_ISDIR(st.st_mode)) {
        if (error) *error = @"The app container no longer exists or is not a directory";
        return NO;
    }
    if (expectedDevice && expectedInode && (st.st_dev != expectedDevice || st.st_ino != expectedInode)) {
        if (error) *error = @"The app container was replaced after it was scanned";
        return NO;
    }
    NSString *label = cl_container_label(container);
    if (!label.length || ![label isEqualToString:bundleID]) {
        if (error) *error = @"The app container identity no longer matches the selected app";
        return NO;
    }
    return YES;
}

static BOOL cl_copy_part_and_verify(NSString *src, NSString *dst, NSString **error)
{
    BOOL sourceBeforeExists = NO;
    NSString *sourceBefore = CLAppSupportTreeSignature(src, YES, &sourceBeforeExists, error);
    if (!sourceBefore) return NO;
    if (!cl_copy_contents(src, dst, error)) return NO;
    BOOL srcExists = NO, dstExists = NO;
    NSString *sourceAfter = CLAppSupportTreeSignature(src, YES, &srcExists, error);
    NSString *sourceShape = CLAppSupportTreeSignature(src, NO, NULL, error);
    NSString *destinationShape = CLAppSupportTreeSignature(dst, NO, &dstExists, error);
    if (!sourceAfter || !sourceShape || !destinationShape || !sourceBeforeExists || !srcExists || !dstExists ||
        ![sourceBefore isEqualToString:sourceAfter] ||
        ![sourceShape isEqualToString:destinationShape]) {
        if (error && !*error) *error = @"The copied tree could not be verified (the source changed or the copy is incomplete)";
        return NO;
    }
    return YES;
}

static BOOL cl_purge_and_verify(NSString *dir, unsigned long long *freed, NSString **error)
{
    if (!cl_purge_contents(dir, freed)) return NO;
    struct stat st;
    if (!cl_stat(dir, &st)) return YES;   // a missing part is an acceptable empty result
    if (!S_ISDIR(st.st_mode)) {
        if (error) *error = [NSString stringWithFormat:@"%@ is not a directory", dir.lastPathComponent];
        return NO;
    }
    NSError *listError = nil;
    NSArray *remaining = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:&listError];
    if (!remaining) {
        if (error) *error = listError.localizedDescription ?: [NSString stringWithFormat:@"Cannot read %@", dir.lastPathComponent];
        return NO;
    }
    if (remaining.count) {
        if (error) *error = [NSString stringWithFormat:@"Some items remain in %@; keep the app closed and try again", dir.lastPathComponent];
        return NO;
    }
    return YES;
}

// Copies the app's Documents and Library into a new complete backup. Returns
// its path, or nil with *error (nothing is left behind then).
NSString *cl_make_app_backup(NSString *bundleID, NSString *container, dev_t expectedDevice,
                                    ino_t expectedInode, NSString *reason, NSString **error)
{
    if (!CLAppSupportBundleIDValid(bundleID)) {
        if (error) *error = @"The app identifier is not a valid bundle identifier";
        return nil;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    if (!cl_validate_container(container, bundleID, expectedDevice, expectedInode, error)) return nil;
    NSString *root = cl_app_backup_root_for_bundle(bundleID);
    if (!root.length) {
        if (error) *error = @"Cannot locate the app backup folder";
        return nil;
    }
    [fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSString *name in [fm contentsOfDirectoryAtPath:root error:nil])   // leftovers of interrupted runs
        if ([name hasPrefix:kCLBackupStagingPrefix]) [fm removeItemAtPath:[root stringByAppendingPathComponent:name] error:nil];

    NSString *staging = [root stringByAppendingPathComponent:
                         [kCLBackupStagingPrefix stringByAppendingString:NSUUID.UUID.UUIDString]];
    if (![fm createDirectoryAtPath:staging withIntermediateDirectories:NO attributes:nil error:nil]) {
        if (error) *error = @"Cannot create the backup folder";
        return nil;
    }
    NSMutableArray *parts = [NSMutableArray new];
    NSMutableDictionary<NSString *, NSString *> *sourceStates = [NSMutableDictionary new];
    NSMutableDictionary<NSString *, NSString *> *partHashes = [NSMutableDictionary new];
    BOOL ok = YES;
    for (NSString *part in cl_app_backup_parts()) {
        NSString *src = [container stringByAppendingPathComponent:part];
        struct stat st;
        if (lstat(src.fileSystemRepresentation, &st) != 0 && errno == ENOENT) continue;   // the app has none
        if (!cl_stat(src, &st)) { ok = NO; if (error) *error = [NSString stringWithFormat:@"Cannot access %@", part]; break; }
        BOOL sourceExists = NO;
        NSString *sourceState = CLAppSupportTreeSignature(src, YES, &sourceExists, error);
        if (!sourceState) { ok = NO; break; }
        sourceStates[part] = sourceState;
        NSString *stagedPart = [staging stringByAppendingPathComponent:part];
        if (!cl_copy_part_and_verify(src, stagedPart, error)) { ok = NO; break; }
        BOOL stagedExists = NO;
        NSString *contentHash = CLAppSupportTreeContentSignature(stagedPart, &stagedExists, error);
        if (!contentHash || !stagedExists) {
            ok = NO;
            if (error && !*error) *error = @"Cannot hash the staged backup part";
            break;
        }
        partHashes[part] = contentHash;
        [parts addObject:part];
    }
    if (ok) {
        for (NSString *part in cl_app_backup_parts()) {
            NSString *src = [container stringByAppendingPathComponent:part];
            BOOL sourceExists = NO;
            NSString *sourceState = CLAppSupportTreeSignature(src, YES, &sourceExists, error);
            NSString *before = sourceStates[part] ?: @"<missing>";
            if (!sourceState || ![before isEqualToString:sourceState]) {
                ok = NO;
                if (error && !*error) *error = @"The app data changed while it was being backed up; no snapshot-consistent copy was made";
                break;
            }
        }
    }
    NSDate *created = NSDate.date;
    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    fmt.dateFormat = @"yyyy-MM-dd HH.mm.ss";
    NSString *stamp = [fmt stringFromDate:created];
    NSString *final = [root stringByAppendingPathComponent:stamp];
    NSUInteger sequence = 1;
    for (NSUInteger n = 2; [fm fileExistsAtPath:final]; n++) {
        sequence = n;
        final = [root stringByAppendingPathComponent:[NSString stringWithFormat:@"%@ (%lu)", stamp, (unsigned long)n]];
    }
    NSDictionary *manifest = @{ @"Complete": @YES, @"BundleID": bundleID, @"Created": created,
                                @"Parts": parts, @"PartHashes": partHashes,
                                @"Reason": reason ?: @"", @"Format": @1,
                                @"Sequence": @(sequence) };
    if (ok && ![manifest writeToFile:[staging stringByAppendingPathComponent:kCLBackupManifest] atomically:YES]) {
        ok = NO;
        if (error) *error = @"Cannot write the backup manifest";
    }
    BOOL published = NO;
    if (ok) {
        if (!cl_validate_container(container, bundleID, expectedDevice, expectedInode, error)) ok = NO;
    }
    if (ok) {
        if (rename(staging.fileSystemRepresentation, final.fileSystemRepresentation) != 0) {
            ok = NO;
            if (error) *error = [NSString stringWithFormat:@"Cannot finish the backup (errno %d)", errno];
        } else {
            published = YES;
            NSString *validationError = nil;
            if (!cl_validate_backup(final, bundleID, NO, NULL, NULL, NULL, &validationError) ||
                !cl_validate_container(container, bundleID, expectedDevice, expectedInode, &validationError)) {
                ok = NO;
                if (error) *error = validationError ?: @"The app container changed while the backup was being finalized";
            }
        }
    }
    if (!ok) {
        [fm removeItemAtPath:published ? final : staging error:nil];
        cl_log(@"app backup %@: FAILED (%@)", bundleID, error && *error ? *error : @"?");
        return nil;
    }
    cl_log(@"app backup %@ -> %@ (%@)", bundleID, final.lastPathComponent, [parts componentsJoinedByString:@", "]);
    return final;
}

BOOL cl_dir_size_cancellable(NSString *dir, CLScanCancellation *cancellation,
                             unsigned long long *sizeOut, BOOL *completeOut)
{
    if (completeOut) *completeOut = NO;
    if (sizeOut) *sizeOut = 0;
    if (cancellation.isCancelled) return NO;
    unsigned long long total = 0;
    CLMeasureResult result = cl_measure_tree(dir, cancellation, &total);
    if (result == CLMeasureResultCancelled) return NO;
    if (sizeOut) *sizeOut = total;
    if (completeOut) *completeOut = result != CLMeasureResultLimited;
    return YES;
}

static BOOL cl_replace_part(NSString *src, NSString *dst, NSString **error)
{
    // Stage the source before purging the live destination. If a named safety
    // part disappears or becomes unreadable, no live data may be purged first.
    NSString *staging = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"CLAppsRestore-%@", NSUUID.UUID.UUIDString]];
    BOOL staged = cl_copy_part_and_verify(src, staging, error);
    if (!staged) {
        [NSFileManager.defaultManager removeItemAtPath:staging error:nil];
        return NO;
    }
    unsigned long long ignored = 0;
    BOOL ok = cl_purge_and_verify(dst, &ignored, error);
    if (ok) {
        ok = cl_copy_part_and_verify(staging, dst, error);
        if (!ok && error && !*error) *error = [NSString stringWithFormat:@"Could not restore %@", dst.lastPathComponent];
    }
    [NSFileManager.defaultManager removeItemAtPath:staging error:nil];
    return ok;
}

static NSString *cl_restore_journal_path(void)
{
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    return [support stringByAppendingPathComponent:@"active-restore.plist"];
}

static BOOL cl_read_restore_journal(NSMutableDictionary **journalOut, BOOL *existsOut, NSString **error)
{
    if (journalOut) *journalOut = nil;
    if (existsOut) *existsOut = NO;
    NSString *path = cl_restore_journal_path();
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) return YES;
    NSDictionary *journal = [NSDictionary dictionaryWithContentsOfFile:path];
    if (![journal isKindOfClass:NSDictionary.class]) {
        if (error) *error = @"The restore recovery journal is unreadable";
        return NO;
    }
    if (existsOut) *existsOut = YES;
    if (journalOut) *journalOut = [journal mutableCopy];
    return YES;
}

static BOOL cl_write_restore_journal(NSDictionary *journal, NSString **error)
{
    NSString *path = cl_restore_journal_path();
    if (![NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                                  withIntermediateDirectories:YES attributes:nil error:nil]) {
        if (error) *error = @"Cannot create the restore recovery folder";
        return NO;
    }
    if (![journal writeToFile:path atomically:YES]) {
        if (error) *error = @"Cannot write the restore recovery journal";
        return NO;
    }
    return YES;
}

static BOOL cl_remove_restore_journal(NSString **error);

static BOOL cl_begin_restore_journal(CLAppItem *app, NSString *backup, NSString *safety, NSString **error)
{
    if (!cl_backup_root_child(backup, app.bundleID) || !cl_backup_root_child(safety, app.bundleID)) {
        if (error) *error = @"The restore paths are not inside this app's backup folder";
        return NO;
    }
    BOOL exists = NO;
    NSMutableDictionary *existing = nil;
    NSString *readError = nil;
    if (!cl_read_restore_journal(&existing, &exists, &readError)) {
        if (error) *error = readError;
        return NO;
    }
    if (exists) {
        CLAppsSupportJournalState state = CLAppsSupportJournalStateForDictionary(existing);
        NSString *policyError = nil;
        if (!CLAppsSupportJournalAllowsNewRestore(state, &policyError)) {
            if (error) *error = policyError;
            return NO;
        }
        if (state == CLAppsSupportJournalCommitted &&
            !cl_remove_restore_journal(&readError)) {
            if (error) *error = readError ?: @"Cannot remove the completed restore journal";
            return NO;
        }
    }
    NSDictionary *journal = @{ @"Format": @2, @"State": @"Active", @"BundleID": app.bundleID,
                               @"Container": app.container, @"Backup": backup, @"Safety": safety,
                               @"ContainerDevice": @(app.containerDevice), @"ContainerInode": @(app.containerInode),
                               @"Started": NSDate.date };
    return cl_write_restore_journal(journal, error);
}

// Marking committed is the point of no return for a completed restore. It is
// deliberately separate from removal: a committed journal must never cause a
// later rollback, even if the file itself cannot be deleted right now.
static BOOL cl_mark_restore_journal_committed(NSString **error)
{
    BOOL exists = NO;
    NSMutableDictionary *journal = nil;
    NSString *readError = nil;
    if (!cl_read_restore_journal(&journal, &exists, &readError)) {
        if (error) *error = readError;
        return NO;
    }
    if (!exists) return YES;
    journal[@"State"] = @"Committed";
    return cl_write_restore_journal(journal, error);
}

static BOOL cl_remove_restore_journal(NSString **error)
{
    NSString *path = cl_restore_journal_path();
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:path]) return YES;
    NSError *removeError = nil;
    if (![fm removeItemAtPath:path error:&removeError]) {
        if (error) *error = removeError.localizedDescription ?: @"Cannot remove the restore recovery journal";
        return NO;
    }
    return YES;
}

static BOOL cl_finish_restore_journal(NSString **error)
{
    if (!cl_mark_restore_journal_committed(error)) return NO;
    return cl_remove_restore_journal(error);
}

static BOOL cl_validate_backup_hashes(NSString *backup, NSArray<NSString *> *parts,
                                      NSDictionary *manifest, NSString **error)
{
    NSDictionary *hashes = manifest[@"PartHashes"];
    if (!hashes) return YES;   // backups made before content hashes existed
    for (NSString *part in parts) {
        NSString *expected = hashes[part];
        if (![expected isKindOfClass:NSString.class] || !expected.length) {
            if (error) *error = [NSString stringWithFormat:@"The backup has no hash for %@", part];
            return NO;
        }
        BOOL exists = NO;
        NSString *actual = CLAppSupportTreeContentSignature([backup stringByAppendingPathComponent:part],
                                                              &exists, error);
        if (!actual || !exists || ![actual isEqualToString:expected]) {
            if (error) *error = [NSString stringWithFormat:@"The backup's %@ contents changed after it was created", part];
            return NO;
        }
    }
    return YES;
}

static BOOL cl_rollback_safety(NSString *container, NSString *bundleID, NSString *safety,
                               dev_t expectedDevice, ino_t expectedInode, NSString **error)
{
    NSArray<NSString *> *parts = nil;
    NSDictionary *safetyManifest = nil;
    if (!cl_validate_container(container, bundleID, expectedDevice, expectedInode, error) ||
        !cl_validate_backup(safety, bundleID, NO, &parts, &safetyManifest, NULL, error) ||
        !cl_validate_backup_hashes(safety, parts, safetyManifest, error)) return NO;
    // Revalidate everything immediately before the first mutation. In
    // particular, a missing named safety part is never interpreted as an
    // instruction to purge the live part.
    if (!cl_validate_container(container, bundleID, expectedDevice, expectedInode, error) ||
        !cl_validate_backup(safety, bundleID, NO, &parts, &safetyManifest, NULL, error) ||
        !cl_validate_backup_hashes(safety, parts, safetyManifest, error)) return NO;
    BOOL ok = YES;
    for (NSString *part in cl_app_backup_parts()) {
        NSString *saved = [safety stringByAppendingPathComponent:part];
        NSString *dst = [container stringByAppendingPathComponent:part];
        if (!cl_validate_container(container, bundleID, expectedDevice, expectedInode, error)) {
            ok = NO;
            break;
        }
        if ([parts containsObject:part]) {
            if (!cl_replace_part(saved, dst, error)) ok = NO;
        } else {
            unsigned long long ignored = 0;
            if (!cl_purge_and_verify(dst, &ignored, error)) {
                ok = NO;
            }
        }
        if (!ok) break;
    }
    if (ok && !cl_validate_container(container, bundleID, expectedDevice, expectedInode, error)) ok = NO;
    return ok;
}

// Called on the serial I/O queue at launch. An active journal means termination
// may have left only some restored parts in place, so reapply the safety state.
NSString *cl_recover_interrupted_restore(void)
{
    NSString *path = cl_restore_journal_path();
    NSDictionary *journal = [NSDictionary dictionaryWithContentsOfFile:path];
    if (!journal) return nil;
    NSString *state = [journal[@"State"] isKindOfClass:NSString.class] ? journal[@"State"] : nil;
    if ([state isEqualToString:@"Committed"]) {
        NSString *removeError = nil;
        if (!cl_remove_restore_journal(&removeError)) {
            cl_log(@"restore recovery: committed journal cleanup failed: %@", removeError);
        }
        return nil;
    }
    if (![state isEqualToString:@"Active"]) {
        cl_log(@"restore recovery: unknown journal state at %@", path);
        return @"An interrupted restore was found with an unknown recovery state. The journal was retained for manual recovery.";
    }
    NSString *bundleID = journal[@"BundleID"], *container = journal[@"Container"], *safety = journal[@"Safety"];
    NSString *backup = journal[@"Backup"];
    id deviceValue = journal[@"ContainerDevice"];
    id inodeValue = journal[@"ContainerInode"];
    NSString *journalError = nil;
    BOOL stringFields = [bundleID isKindOfClass:NSString.class] && [container isKindOfClass:NSString.class] &&
        [safety isKindOfClass:NSString.class] && [backup isKindOfClass:NSString.class];
    BOOL identityFields = CLAppSupportIsInteger(deviceValue) && CLAppSupportIsInteger(inodeValue) &&
        [deviceValue compare:@1] != NSOrderedAscending && [inodeValue compare:@1] != NSOrderedAscending;
    dev_t device = identityFields ? [deviceValue unsignedLongLongValue] : 0;
    ino_t inode = identityFields ? [inodeValue unsignedLongLongValue] : 0;
    BOOL journalTyped = stringFields && CLAppSupportIsInteger(journal[@"Format"]) && [journal[@"Format"] unsignedIntegerValue] == 2 &&
        identityFields && bundleID.length && container.length && safety.length && backup.length && device && inode &&
        cl_backup_root_child(backup, bundleID) && cl_backup_root_child(safety, bundleID) &&
        cl_validate_container(container, bundleID, device, inode, &journalError);
    if (!journalTyped) {
        cl_log(@"restore recovery: invalid journal or incomplete safety backup at %@", path);
        return [NSString stringWithFormat:@"An interrupted restore was found, but its recovery journal is invalid. The journal was retained for manual recovery%@.",
                journalError.length ? [NSString stringWithFormat:@" (%@)", journalError] : @""];
    }
    NSString *error = nil;
    if (!cl_rollback_safety(container, bundleID, safety, device, inode, &error)) {
        cl_log(@"restore recovery for %@: FAILED (%@)", bundleID, error);
        return [NSString stringWithFormat:@"Automatic recovery of %@ failed: %@. The safety backup is %@; see Log.",
                bundleID, error ?: @"unknown error", safety.lastPathComponent];
    }
    NSString *commitError = nil;
    NSString *removeError = nil;
    if (!cl_mark_restore_journal_committed(&commitError)) {
        cl_log(@"restore recovery for %@: recovered, journal commit failed (%@)", bundleID, commitError);
        return [NSString stringWithFormat:@"An interrupted restore of %@ was recovered, but its journal could not be committed (%@). It will be checked again at the next launch.",
                bundleID, commitError ?: @"unknown error"];
    }
    if (!cl_remove_restore_journal(&removeError)) {
        cl_log(@"restore recovery for %@: recovered, cleanup pending (%@)", bundleID, removeError);
        return [NSString stringWithFormat:@"An interrupted restore of %@ was recovered. Its committed journal will be cleaned up at the next launch (%@).",
                bundleID, removeError ?: @"cleanup failed"];
    }
    cl_log(@"restore recovery for %@: OK", bundleID);
    return [NSString stringWithFormat:@"An interrupted restore of %@ was recovered from its safety backup.", bundleID];
}


#pragma mark - Restore / clear (converted from the v0.1 view controller)

// Documents and Library are always represented. YES means copy from the
// backup; NO means deliberately purge the current part during restore.
static NSDictionary<NSString *, NSNumber *> *cl_restore_plan(BOOL hasDocuments, BOOL hasLibrary)
{
    return @{ @"Documents": @(hasDocuments), @"Library": @(hasLibrary) };
}

// Restores app's Documents/Library from backup (validates, safety-backs up
// first, journals, rolls back on failure). Sets *title/*message in Chinese.
void cl_restore_app(CLAppItem *app, NSString *backup, NSString **title, NSString **message)
{
    // 1. Validate all typed manifest fields and all required parts before any
    // safety backup, journal, purge, or replacement is allowed.
    NSArray<NSString *> *parts = nil;
    NSDictionary *manifest = nil;
    BOOL verified = NO;
    NSString *error = nil;
    if (!cl_validate_backup(backup, app.bundleID, YES, &parts, &manifest, &verified, &error)) {
        *title = @"未能恢复";
        *message = [NSString stringWithFormat:@"该备份不安全，无法恢复（%@）。什么都没改。", error ?: @"清单无效"];
        return;
    }
    if (!verified && !parts.count) {
        *title = @"未能恢复";
        *message = @"这个旧备份是空的。什么都没改。";
        return;
    }
    if (!cl_validate_container(app.container, app.bundleID, app.containerDevice, app.containerInode, &error)) {
        *title = @"未能恢复";
        *message = [NSString stringWithFormat:@"所选应用的容器已不再安全（%@）。什么都没改。", error];
        return;
    }
    // 2. Keep the current data and a durable recovery journal before touching
    // anything, so both ordinary failures and process termination are covered.
    NSString *safety = cl_make_app_backup(app.bundleID, app.container, app.containerDevice,
                                           app.containerInode, kCLBackupReasonBeforeRestore, &error);
    if (!safety) {
        *title = @"未能恢复";
        *message = [NSString stringWithFormat:@"无法先备份当前数据（%@）。什么都没改。",
                    error ?: @"详见日志"];
        return;
    }
    if (!cl_begin_restore_journal(app, backup, safety, &error)) {
        *title = @"未能恢复";
        *message = [NSString stringWithFormat:@"%@。什么都没改；安全备份保留在 %@，可手动恢复。",
                    error ?: @"恢复记录无法写入", safety.lastPathComponent];
        return;
    }
    // 3. Re-read and validate the selected backup immediately before the first
    // mutation. A changed or incomplete source fails closed and retains the
    // journal/safety material.
    error = nil;
    NSArray<NSString *> *preRestoreParts = nil;
    NSDictionary *preRestoreManifest = nil;
    if (!cl_validate_container(app.container, app.bundleID, app.containerDevice, app.containerInode, &error) ||
        !cl_validate_backup(backup, app.bundleID, YES, &preRestoreParts, &preRestoreManifest, NULL, &error) ||
        ![preRestoreParts isEqualToArray:parts] ||
        !cl_validate_backup_hashes(backup, preRestoreParts, preRestoreManifest, &error)) {
        error = error ?: @"所选备份在恢复前发生了变化";
    }
    BOOL ok = error == nil;
    NSDictionary *restorePlan = cl_restore_plan([parts containsObject:@"Documents"],
                                               [parts containsObject:@"Library"]);
    for (NSString *part in cl_app_backup_parts()) {
        if (!ok) break;
        NSString *src = [backup stringByAppendingPathComponent:part];
        NSString *dst = [app.container stringByAppendingPathComponent:part];
        if (!cl_validate_container(app.container, app.bundleID, app.containerDevice, app.containerInode, &error)) {
            ok = NO;
            break;
        }
        if ([restorePlan[part] boolValue]) {
            if (!cl_replace_part(src, dst, &error)) { ok = NO; break; }
        } else {
            unsigned long long ignored = 0;
            if (!cl_purge_and_verify(dst, &ignored, &error)) {
                ok = NO;
                break;
            }
        }
    }
    NSArray<NSString *> *postRestoreParts = nil;
    if (ok && (!cl_validate_container(app.container, app.bundleID, app.containerDevice, app.containerInode, &error) ||
               !cl_validate_backup(backup, app.bundleID, YES, &postRestoreParts, NULL, NULL, &error) ||
               ![postRestoreParts isEqualToArray:parts])) {
        ok = NO;
        error = error ?: @"所选备份在恢复过程中发生了变化";
    }
    if (ok) {
        NSString *commitError = nil;
        NSString *removeError = nil;
        if (cl_mark_restore_journal_committed(&commitError)) {
            BOOL removed = cl_remove_restore_journal(&removeError);
            if (!removed) cl_log(@"restore %@: journal cleanup pending (%@)", app.bundleID, removeError);
            cl_log(@"restore %@ from %@: OK", app.bundleID, backup.lastPathComponent);
            *title = @"已恢复";
            NSString *cleanup = removed ? @"" : @" 恢复记录已提交，下次启动时会清理。";
            *message = [NSString stringWithFormat:@"打开 %@ 即可使用恢复后的 Documents 和 Library。恢复前的数据保留为备份 %@；tmp 未动。操作期间请保持应用关闭。%@",
                        app.name, safety.lastPathComponent, cleanup];
            return;
        }
        // The journal is still Active. Rolling back is the only safe outcome
        // if it cannot be marked committed, because a completed restore must
        // not be rolled back by the next launch.
        error = [NSString stringWithFormat:@"恢复已完成，但恢复记录无法提交（%@）", commitError];
    }
    cl_log(@"restore %@ from %@: FAILED (%@), rolling back", app.bundleID, backup.lastPathComponent, error);
    NSString *rollbackError = nil;
    BOOL rolledBack = cl_rollback_safety(app.container, app.bundleID, safety,
                                          app.containerDevice, app.containerInode, &rollbackError);
    // Keep the journal when the rollback failed, so the next launch tries the
    // recovery again instead of leaving the app half restored.
    NSString *cleanupError = nil;
    BOOL cleared = NO;
    if (rolledBack) cleared = cl_finish_restore_journal(&cleanupError);
    if (!rolledBack) cleanupError = @"kept for recovery at the next launch";
    cl_log(@"restore %@: rollback %@, journal %@", app.bundleID,
           rolledBack ? @"OK" : @"FAILED", cleared ? @"cleared" : cleanupError);
    *title = @"恢复失败";
    *message = rolledBack
        ? [NSString stringWithFormat:@"%@。之前的数据已放回。%@", error ?: @"部分文件无法写入",
           cleared ? @"" : @" 恢复记录无法删除，下次启动会再次尝试恢复。"]
        : [NSString stringWithFormat:@"%@，而且放回之前数据也失败了（%@）。它在备份 %@ 里，详见日志。%@",
           error ?: @"部分文件无法写入", rollbackError ?: @"详见日志", safety.lastPathComponent,
           cleared ? @"" : @" 下次启动会再次尝试恢复。"];
}

// Clears Documents + Library + tmp of app (like a fresh install). The caller
// asks about a backup first. Returns NO with *error when something remains.
BOOL cl_clear_app_data(CLAppItem *app, unsigned long long *freedOut, NSString **errorOut)
{
    unsigned long long freed = 0;
    NSString *error = nil;
    BOOL ok = cl_validate_container(app.container, app.bundleID, app.containerDevice, app.containerInode, &error);
    for (NSString *part in cl_app_data_parts()) {
        if (!ok) break;
        if (!cl_validate_container(app.container, app.bundleID, app.containerDevice, app.containerInode, &error) ||
            !cl_purge_and_verify([app.container stringByAppendingPathComponent:part], &freed, &error)) ok = NO;
    }
    if (ok && !cl_validate_container(app.container, app.bundleID, app.containerDevice, app.containerInode, &error)) ok = NO;
    cl_log(@"clear data: %@ freed %llu ok=%d", app.bundleID, freed, ok);
    if (freedOut) *freedOut = freed;
    if (errorOut) *errorOut = error;
    return ok;
}
