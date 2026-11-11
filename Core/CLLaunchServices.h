//
//  WQLaunchServices.h
//  Cleaner
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Human app name for a bundle id, from LaunchServices' database (read from
// lsd's container), a built-in table of Apple services, or the parent app.
// v2.9: NEVER blocks the main thread. Loading the database enumerates the
// daemon containers (cl_find_ls_store -> cl_enumerate -> cl_shared_children,
// which waits for the daemon inode scan), so a main-thread call returns the
// already-loaded snapshot + built-in names immediately, without triggering
// a load and without waiting for one in progress. The background scan
// loads the names; lists refresh when its batches arrive.
NSString *_Nullable cl_display_name(NSString *_Nullable bundleID);

// Bundle id of an app or extension data container (/private/var/mobile/
// Containers/Data/...), from the same LaunchServices database. For iOS 27.2,
// where the containers' identifier attribute can't be read. Nil if unknown.
// v2.9: same main-thread rule as cl_display_name — nil when the names
// aren't loaded yet (or a load is in progress) instead of loading.
NSString *_Nullable cl_bundle_id_for_container(NSString *path);

// Whether the name database is loaded; loading it (blocking, off the main
// thread) the first time can take a while, so screens show a status for it.
// v2.9: on the main thread this returns NO while a load is in progress
// instead of waiting for the lock.
BOOL cl_display_names_loaded(void);
// v2.9: a main-thread call is a no-op — loading is owned by the background
// scan / launch warm-up, never by the UI thread.
void cl_load_display_names(void);
// After a user's refresh: search for a database that wasn't found before
// right away instead of waiting a day. v2.9: on the main thread this is
// skipped while a load holds the lock (the reset can wait; the load in
// progress will populate or fail on its own).
void cl_display_names_reset_miss(void);
// Every app and extension data container the LaunchServices database lists,
// read from storeHint (remembered when it parses) or the remembered location.
// Never scans. Nil when there's no usable database.
NSArray<NSString *> *_Nullable cl_ls_container_paths(NSString *_Nullable storeHint);
// The .app bundle of an installed app, from the same database (for icons
// where iOS won't hand them out). Nil if unknown. v2.9: same main-thread
// rule as cl_display_name.
NSString *_Nullable cl_bundle_path_for_id(NSString *bundleID);

#ifdef CL_ACCESS_TESTING
// Test hooks: how many times the loader was entered (any thread), and a way
// to hold the LS lock on a background thread so tests can prove main-thread
// callers return promptly instead of waiting for a load in progress.
NSUInteger cl_test_ls_load_attempt_count(void);
void cl_test_hold_ls_lock_for(NSTimeInterval seconds);
#endif

NS_ASSUME_NONNULL_END
