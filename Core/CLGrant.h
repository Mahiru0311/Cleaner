//
//  CLGrant.h
//  Cleaner v2 — worse_query sandbox grants (App Group + container token).
//

#import <Foundation/Foundation.h>
#import <sys/stat.h>

NS_ASSUME_NONNULL_BEGIN

// Log shared with the UI.
void cl_log(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
NSString *cl_log_text(void);

// Small errno helpers shared by Core (purge/scan paths).
NSString *cl_errno(int err);
BOOL cl_is_denied(int err);
// Canonical path form shared by Core (container identity + scan).
NSString *cl_norm(NSString *path);

// Test hook (CL_ACCESS_TESTING only): called at copy/purge stages so tests
// can inject races. Compiled out of the app build.
#ifdef CL_ACCESS_TESTING
extern void (^cl_test_tree_hook)(NSString *stage, NSString *path);
#define CL_TREE_HOOK(stage, path) do { if (cl_test_tree_hook) cl_test_tree_hook(stage, path); } while (0)
#else
#define CL_TREE_HOOK(stage, path) do {} while (0)
#endif

// Picks the app group the signer actually gave us. Nil when there is none.
NSString *_Nullable cl_app_group(void);

// Asks for a sandbox extension covering path (once per path). Returns YES
// when one is held for it.
BOOL cl_grant(NSString *path);

// NO on iOS 26: there worse_query can't reach System Data, the system groups
// or the App Groups parent folder (only the individual containers).
BOOL cl_system_areas_reachable(void);

// lstat with access retry. Returns NO if the item does not exist.
BOOL cl_stat(NSString *path, struct stat *st);

// Directory listing; asks for access when the plain call is refused.
NSArray<NSString *> *_Nullable cl_list(NSString *dir, NSString *_Nullable *_Nullable errorText);

// Reads a whole file (up to maxBytes; 0 = no limit).
NSData *_Nullable cl_read(NSString *path, NSUInteger maxBytes, NSString *_Nullable *_Nullable errorText);

// Why a sandbox refusal (EPERM) differs from plain Unix permissions (EACCES).
NSString *_Nullable cl_permission_hint(NSString *path, BOOL forWriting);

// Copies every item inside srcDir into dstDir (replacing same-named items).
BOOL cl_copy_contents(NSString *srcDir, NSString *dstDir, NSString *_Nullable *_Nullable errorText);

// MCM container identifier (bundle or group id) of a container folder.
NSString *_Nullable cl_container_label(NSString *dir);
void cl_set_container_list_provider(NSArray<NSString *> *_Nullable (*_Nullable provider)(NSString *_Nullable storeHint));
void cl_set_container_label_resolver(NSString *_Nullable (*_Nullable resolver)(NSString *path));

// Backups live in Documents/Backups; app backups in Documents/AppBackups.
NSString *cl_backup_root(void);
NSString *cl_app_backup_root(void);
BOOL cl_is_backup_storage_path(NSString *path);

// Opens a directory without following links (grants access when refused).
int cl_open_directory(NSString *path);

NS_ASSUME_NONNULL_END
