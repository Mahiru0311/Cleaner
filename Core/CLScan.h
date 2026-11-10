//
//  CLScan.h
//  Cleaner v2 — fsgetpath container enumeration + persistent scan cache.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Thread-safe cancellation for expensive filesystem scans.
@interface CLScanCancellation : NSObject
@property (atomic, readonly, getter=isCancelled) BOOL cancelled;
- (void)cancel;
@end

// Discovers direct children of dir by brute-forcing inode numbers with
// fsgetpath (not sandbox-gated), the way KAMUI/bad_query_list do. Needs no
// token on dir. maxInode bounds the scan (0 = up to the newest id on the
// volume); progress is called off the main thread, from several threads.
// Returns absolute child paths, sorted, or nil on failure/cancellation.
// With maxInode 0, the App Data, Extensions and Internal Daemons parents are
// scanned together in one pass, reused for 10 minutes (or until
// cl_enumerate_invalidate) and saved: later scans only check the ids created
// since the saved one (a full scan runs weekly). The scan keeps running when
// its caller cancels; concurrent callers wait for that one scan.
NSArray<NSString *> *_Nullable cl_enumerate(NSString *dir, int64_t maxInode,
                                            CLScanCancellation *_Nullable cancellation,
                                            void (^_Nullable progress)(int64_t done, int64_t total, NSUInteger found));

// Forget the shared container scan, so the next cl_enumerate of those scans
// the ids created since. Call on a user's refresh.
void cl_enumerate_invalidate(void);

NS_ASSUME_NONNULL_END
