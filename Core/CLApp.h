//
//  CLApp.h
//  Cleaner v2 — app data backup, restore and clear (simplified).
//

#import <Foundation/Foundation.h>
#import "CLScan.h"

NS_ASSUME_NONNULL_BEGIN

@interface CLAppItem : NSObject
@property (nonatomic, copy) NSString *container;
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) unsigned long long bytes;
@property (nonatomic) BOOL sizeKnown;
@property (nonatomic) BOOL hasAccess;
@property (nonatomic) BOOL hasIdentity;
@property (nonatomic) dev_t containerDevice;
@property (nonatomic) ino_t containerInode;
@property (nonatomic, copy) NSArray<NSDictionary *> *backups;
@end

// Valid backups of bundleID, newest first (each: path, verified, reason).
NSArray<NSDictionary *> *cl_app_backups(NSString *bundleID);
// Display label of a backup dictionary from cl_app_backups.
NSString *cl_backup_label(NSDictionary *backup);

// Copies the app's Documents and Library into a new complete backup. Returns
// its path, or nil with *error (nothing is left behind then).
NSString *_Nullable cl_make_app_backup(NSString *bundleID, NSString *container, dev_t expectedDevice,
                                       ino_t expectedInode, NSString *_Nullable reason, NSString * _Nullable * _Nullable error);

// Restores app's Documents/Library from backup (validates, safety-backs up
// first, journals, rolls back on failure). Sets *title/*message in Chinese.
void cl_restore_app(CLAppItem *app, NSString *backup, NSString * _Nullable * _Nullable title, NSString * _Nullable * _Nullable message);

// Clears Documents + Library + tmp of app (like a fresh install). The caller
// asks about a backup first. Returns NO with *error when something remains.
BOOL cl_clear_app_data(CLAppItem *app, unsigned long long *_Nullable freedOut, NSString * _Nullable * _Nullable errorOut);

// Measures a container's size (cancellable); *completeOut is NO when the
// measurement was limited. Returns NO when cancelled. Used by the Apps scan.
BOOL cl_dir_size_cancellable(NSString *dir, CLScanCancellation *cancellation,
                             unsigned long long *sizeOut, BOOL *completeOut);

// Recovers an interrupted restore from its journal + safety backup at launch.
// Returns a description, or nil when there was nothing to recover.
NSString *_Nullable cl_recover_interrupted_restore(void);

NS_ASSUME_NONNULL_END
