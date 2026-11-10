//
//  CLCache.h
//  Cleaner v2 — cache measurement, validation and purge.
//

#import <Foundation/Foundation.h>
#import "CLScan.h"

NS_ASSUME_NONNULL_BEGIN

// Crash logs live in a system group, reachable through worse_query on iOS 27 only.
extern NSString *const CLCrashLogsPath;

typedef NS_ENUM(NSInteger, CLMeasureResult) {
    CLMeasureResultMissing,
    CLMeasureResultKnown,
    CLMeasureResultLimited,
    CLMeasureResultCancelled,
};

// Total byte size of regular files below dir. A missing directory is Missing
// (size 0); an unreadable subtree makes the result Limited instead of silently
// undercounting. Grants access when the root cannot be listed.
CLMeasureResult cl_measure_tree(NSString *dir, CLScanCancellation *_Nullable cancellation,
                                unsigned long long *_Nullable bytes);

// Deletes every item *inside* dir (dir itself stays). No backup — for caches.
// Adds freed bytes to *freed. A missing dir counts as done; NO if dir cannot
// be read or listed, ancestry contains links (except canonical /var), the target
// changes, or some items could not be removed. Child links are not followed.
BOOL cl_purge_contents(NSString *dir, unsigned long long *freed);
// Cancellable variant for long cache cleans; returns NO when cancelled.
BOOL cl_purge_contents_cancellable(NSString *dir, unsigned long long *freed,
                                   CLScanCancellation *_Nullable cancellation);

// fd-based size measurement of a tree, never following symlinks (v2.3,
// borrowed from YangJiiii/3105 — see docs/GITHUB-RESEARCH-v2.3.md). *bytes
// receives the total (0 when missing/limited); *subdirsOut, when non-NULL,
// receives the top-5 first-level subdirectories as @{@"name", @"bytes"}.
CLMeasureResult cl_measure_tree_subdirs(NSString *dir, CLScanCancellation *_Nullable cancellation,
                                        unsigned long long *bytes,
                                        NSArray<NSDictionary *> *_Nullable *_Nullable subdirsOut);

// Delete the contents of a folder inside a container (never the container
// itself, never through a symlink), for per-folder cleaning and custom
// cleaning. *freed receives the bytes removed. NO with *reason in Chinese.
BOOL cl_purge_folder_contents(NSString *path, NSString *container, unsigned long long *_Nullable freed,
                              NSString *_Nullable *_Nullable reason);

// Delete regular files matching extensions (e.g. @[@".mp4", @".log"]) or name
// substrings inside a container's Library/Caches and tmp only — the custom
// cleaning engine. Files under an excluded relative path are skipped.
// *freed receives the bytes removed; *failed the count of entries that
// could not be deleted.
BOOL cl_clean_matching_files(NSString *container, NSArray<NSString *> *_Nullable extensions,
                             NSArray<NSString *> *_Nullable nameSubstrings,
                             NSArray<NSString *> *_Nullable excludedRelativePaths,
                             unsigned long long *_Nullable freed, NSUInteger *_Nullable failed,
                             NSString *_Nullable *_Nullable reason);

// Filtered variant (v2.4): age filter (only files older than minAgeSeconds),
// size filter (minSize <= size <= maxSize, 0 = no bound), a subfolder scope
// (roots: container-relative paths under Library/Caches or tmp; nil = both),
// dry-run preview (count + sample, delete nothing) and cancellation.
// The result reports per-item accounting: freed / failed / skipped
// (pattern-matched but filtered out) / matched / matchedBytes, plus up to
// 50 matched relative paths for the preview, and up to 50 failed and
// skipped relative paths each, so no failure or skip is silent (v2.6).
// Matching rules (v2.6, exact — the preview set must equal the delete
// set): an extension matches only the file's real extension — the name
// must be LONGER than the extension (a bare ".mp4" dotfile does not
// match) and end with it, so ".mp4" never matches ".mp4.bak" or "xmp4";
// extension and name-substring matching are both case-insensitive (both
// sides lowercased). Preview and execution run the SAME walk with the
// same matcher; the only difference is dryRun (count vs unlink).
// The container identity is re-checked before every delete; if it
// changes mid-walk the walk stops.
typedef struct {
    NSTimeInterval minAgeSeconds;
    unsigned long long minSize;
    unsigned long long maxSize;
    NSArray<NSString *> *_Nullable roots;
    BOOL dryRun;
    CLScanCancellation *_Nullable cancellation;
    // v2.5: when YES, roots may be any container-relative directory, not
    // just Library/Caches or tmp. Only the custom-rule engine sets this,
    // only for a validated directory rule (the directory was picked in
    // the picker and passed cl_custom_clean_validate_rule); the fd walk
    // itself is equally safe anywhere inside the container (no-follow,
    // identity re-check before every delete). All other callers keep the
    // Caches/tmp restriction.
    BOOL rootsMayBeAnywhere;
} CLCleanMatchOptions;

typedef struct {
    unsigned long long freed;
    NSUInteger failed;
    NSUInteger skipped;
    NSUInteger matched;
    unsigned long long matchedBytes;
    NSArray<NSString *> *_Nullable samplePaths;
    // v2.6: every failed / skipped file, listed with its reason
    // ("rel/path · 删除失败", "rel/path · 太新", "rel/path · 太小/太大"),
    // capped at 50 each — a failed or skipped file is never silent.
    NSArray<NSString *> *_Nullable failedPaths;
    NSArray<NSString *> *_Nullable skippedPaths;
    BOOL limited;
} CLCleanMatchResult;

BOOL cl_clean_matching_files_filtered(NSString *container, NSArray<NSString *> *_Nullable extensions,
                                      NSArray<NSString *> *_Nullable nameSubstrings,
                                      NSArray<NSString *> *_Nullable excludedRelativePaths,
                                      const CLCleanMatchOptions *_Nullable options,
                                      CLCleanMatchResult *_Nullable resultOut,
                                      NSString *_Nullable *_Nullable reason);

// fd-relative removal shared with CLGrant's copy_contents (same-file staging).
// *freed is optional (callers cleaning a partial stage pass NULL).
BOOL cl_remove_entry(int parent, NSString *name, NSString *path, unsigned long long *_Nullable freed,
                     CLScanCancellation *_Nullable cancellation);

@interface CLCacheTargetRecord : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *relativePath;
@property (nonatomic) BOOL existed;
@property (nonatomic) BOOL identityKnown;
@property (nonatomic) dev_t device;
@property (nonatomic) ino_t inode;
@property (nonatomic) mode_t mode;
@end

@interface CLCacheItem : NSObject
@property (nonatomic, copy) NSString *name;        // app name or "Crash Logs"
@property (nonatomic, copy) NSString *bundleID;    // for the icon; nil for logs
@property (nonatomic, copy) NSArray<NSString *> *targets;  // dirs to purge
@property (nonatomic) unsigned long long cacheBytes;
@property (nonatomic) unsigned long long tempBytes;
// Top-5 Caches subdirectories, each @{@"name": NSString, @"bytes": NSNumber}
// (v2.3) — the directory view shows them instead of guessing a folder's size.
@property (nonatomic, copy) NSArray<NSDictionary *> *cacheSubdirs;
@property (nonatomic) BOOL cacheKnown;
@property (nonatomic) BOOL tempKnown;
@property (nonatomic) BOOL limited;
@property (nonatomic) BOOL crashLogs;
@property (nonatomic, copy) NSString *containerPath;
@property (nonatomic) BOOL containerIdentityKnown;
@property (nonatomic) dev_t containerDevice;
@property (nonatomic) ino_t containerInode;
@property (nonatomic) mode_t containerMode;
@property (nonatomic, copy) NSArray<CLCacheTargetRecord *> *targetRecords;
@property (nonatomic) BOOL selected;
@property (nonatomic, readonly) unsigned long long bytes;
@end

typedef NS_ENUM(NSInteger, CLCacheMeasurementState) {
    CLCacheMeasurementMissing,
    CLCacheMeasurementKnown,
    CLCacheMeasurementLimited,
    CLCacheMeasurementCancelled,
};

// Re-validates a scanned item right before purging it; NO with *reason when
// the container or any target changed, or the path ancestry became unsafe.
BOOL CLCacheValidateItem(CLCacheItem *item, NSString * _Nullable * _Nullable reason);

// Last completed scan, shared by Home and the Cleaner page.
extern NSString *const CLCacheStoreDidUpdateNotification;

@interface CLCacheStore : NSObject
@property (nonatomic, copy, readonly) NSArray<CLCacheItem *> *items;
@property (nonatomic, readonly) unsigned long long totalBytes;
@property (nonatomic, readonly) NSUInteger appCount;
// Total DISTINCT APPS measured in the last scan (v2.5: distinct bundle
// ids of Application containers — one app can own several containers, so
// a container count is not an app count; v2.4 counted containers and
// showed 267 for 114 apps). Unlike appCount, this does not drop apps whose
// cache is under 64KB — so after a clean, when every app is ~0 bytes and
// appCount falls to 0, the home still shows the real app total (114).
// v2.3 counted every container and showed 1226. See REFACTOR-v2 §12.
@property (nonatomic, readonly) NSUInteger totalAppCount;
@property (nonatomic, readonly) BOOL limited;
@property (nonatomic, readonly) NSTimeInterval lastScanFinished;
// YES while any page is scanning (Home skips starting a second scan).
@property (nonatomic) BOOL scanning;
+ (instancetype)shared;
- (void)updateWithItems:(NSArray<CLCacheItem *> *)items limited:(BOOL)limited totalApps:(NSUInteger)totalApps;
// Forget the shared container scan + name database, and mark the store's
// last scan as stale, so the next scan is fresh.
- (void)invalidateScan;
@end

// One cache scan at a time; starting cancels the previous one. Progress and
// completion run off the main thread; the caller hops to main. Completion is
// always called, including when the scan was cancelled (cancelled=YES, items
// nil) — callers must reset their scanning state in that branch instead of
// assuming a later completion will arrive.
@interface CLCacheScanner : NSObject
// progress is optional (Home passes nil; all call sites nil-check it).
- (void)startWithProgress:(void (^_Nullable)(NSString *status))progress
               completion:(void (^)(NSArray<CLCacheItem *> *items, BOOL limited, NSString *note, BOOL cancelled, NSUInteger totalApps))completion;
// Same scan, but finished items are also delivered in batches (sorted by
// size, largest first) as soon as they are measured, so rows appear while
// the scan is still running instead of all at once at the end. itemsUpdate
// is optional (nil = behave exactly like startWithProgress:completion:).
// Batches are a preview: the final completion still delivers the complete,
// fully sorted list, which the caller treats as authoritative.
- (void)startWithProgress:(void (^_Nullable)(NSString *status))progress
              itemsUpdate:(void (^_Nullable)(NSArray<CLCacheItem *> *newItems))itemsUpdate
               completion:(void (^)(NSArray<CLCacheItem *> *items, BOOL limited, NSString *note, BOOL cancelled, NSUInteger totalApps))completion;
- (void)cancel;
@end

NS_ASSUME_NONNULL_END
