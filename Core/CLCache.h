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
@property (nonatomic, readonly) BOOL limited;
@property (nonatomic, readonly) NSTimeInterval lastScanFinished;
// YES while any page is scanning (Home skips starting a second scan).
@property (nonatomic) BOOL scanning;
+ (instancetype)shared;
- (void)updateWithItems:(NSArray<CLCacheItem *> *)items limited:(BOOL)limited;
// Forget the shared container scan + name database, so the next scan is fresh.
- (void)invalidateScan;
@end

// One cache scan at a time; starting cancels the previous one. Progress and
// completion run off the main thread; the caller hops to main. Completion is
// always called, including when the scan was cancelled (cancelled=YES, items
// nil) — callers must reset their scanning state in that branch instead of
// assuming a later completion will arrive.
@interface CLCacheScanner : NSObject
- (void)startWithProgress:(void (^)(NSString *status))progress
               completion:(void (^)(NSArray<CLCacheItem *> *items, BOOL limited, NSString *note, BOOL cancelled))completion;
- (void)cancel;
@end

NS_ASSUME_NONNULL_END
