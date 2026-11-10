//
//  CLLaunchServicesTests.m
//  Portable LaunchServices parser/cache regression tests.
//

#import <Foundation/Foundation.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>
#import "../Core/CLGrant.h"
#import "../Core/CLScan.h"
#import "../Core/CLLaunchServices.h"

SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator) { (void)allocator; return NULL; }
CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement, CFErrorRef *error)
{ (void)task; (void)entitlement; (void)error; return NULL; }

static int failures;

#define CLCheck(condition) do { \
    if (!(condition)) { \
        fprintf(stderr, "FAIL %s:%d: %s\n", __func__, __LINE__, #condition); \
        failures++; \
    } \
} while (0)

static void Put32(NSMutableData *data, NSUInteger offset, uint32_t value)
{
    memcpy((uint8_t *)data.mutableBytes + offset, &value, sizeof(value));
}

static NSData *StoreWithName(NSString *displayName)
{
    const NSUInteger recordOffset = 0x200;
    const NSUInteger idOffset = 0x1000;
    const NSUInteger nameOffset = 0x1040;
    const NSUInteger displayOffset = 0x1080;
    NSMutableData *data = [NSMutableData dataWithLength:0x2000];
    uint8_t *bytes = data.mutableBytes;
    memcpy(bytes, "bdsl", 4);
    Put32(data, recordOffset + 4, 0x250);
    Put32(data, recordOffset + 8 + 0x0c, 1u << 2);
    Put32(data, recordOffset + 8 + 0x6c, 2u << 2);
    Put32(data, recordOffset + 8 + 0x74, 3u << 2);

    NSArray<NSString *> *values = @[@"com.example.international", @"Example", displayName];
    NSArray<NSNumber *> *offsets = @[@(idOffset), @(nameOffset), @(displayOffset)];
    for (NSUInteger i = 0; i < values.count; i++) {
        NSData *utf8 = [values[i] dataUsingEncoding:NSUTF8StringEncoding];
        NSUInteger offset = offsets[i].unsignedIntegerValue;
        Put32(data, offset, (uint32_t)(i + 1));
        Put32(data, offset + 4, (uint32_t)utf8.length);
        memcpy(bytes + offset + 8, utf8.bytes, utf8.length);
        bytes[offset + 8 + utf8.length] = 0;
    }
    return data;
}

static NSData *StoreWithTruncatedDisplayName(void)
{
    const NSUInteger recordOffset = 0x200;
    const NSUInteger idOffset = 0x1000;
    const NSUInteger truncatedOffset = 0x1ff0;
    NSMutableData *data = [NSMutableData dataWithLength:0x2000];
    uint8_t *bytes = data.mutableBytes;
    memcpy(bytes, "bdsl", 4);
    Put32(data, recordOffset + 4, 0x250);
    Put32(data, recordOffset + 8 + 0x0c, 1u << 2);
    Put32(data, recordOffset + 8 + 0x6c, 3u << 2);
    Put32(data, recordOffset + 8 + 0x74, 3u << 2);

    NSData *bundleID = [@"com.example.international" dataUsingEncoding:NSUTF8StringEncoding];
    Put32(data, idOffset, 1u);
    Put32(data, idOffset + 4, (uint32_t)bundleID.length);
    memcpy(bytes + idOffset + 8, bundleID.bytes, bundleID.length);
    bytes[idOffset + 8 + bundleID.length] = 0;

    const char *truncated = "Truncate";
    Put32(data, truncatedOffset, 3u);
    Put32(data, truncatedOffset + 4, 8u);
    memcpy(bytes + truncatedOffset + 8, truncated, 8);
    return data;
}

static NSString *TemporaryStorePath(void)
{
    return [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"CLLaunchServicesTests-%d.csstore", getpid()]];
}

static void WriteData(NSData *data, NSString *path)
{
    NSError *error = nil;
    CLCheck([data writeToFile:path options:NSDataWritingAtomic error:&error]);
    CLCheck(!error);
}

static void TestRetryAfterDiscoveryFailure(NSString *path)
{
    NSMutableData *invalid = [NSMutableData dataWithLength:0x0fff];
    memcpy(invalid.mutableBytes, "bdsl", 4);
    WriteData(invalid, path);
    [NSUserDefaults.standardUserDefaults setObject:path forKey:@"WQLaunchServicesStore"];
    CLCheck(cl_display_name(@"com.example.international") == nil);

    WriteData(StoreWithName(@"Retry 日本"), path);
    sleep(2); // The bounded retry backoff starts at one second.
    CLCheck([cl_display_name(@"com.example.international") isEqualToString:@"Retry 日本"]);
}

static void TestRefreshAndUnicodeSafety(NSString *path)
{
    WriteData(StoreWithName(@"Cafe\u0301 日本 \u202Eevil"), path);
    CLCheck([cl_display_name(@"com.example.international") isEqualToString:@"Café 日本 �evil"]);

    WriteData(StoreWithTruncatedDisplayName(), path);
    CLCheck(cl_display_name(@"com.example.international") == nil);

    WriteData(StoreWithName(@"Fresh name"), path);
    CLCheck([cl_display_name(@"com.example.international") isEqualToString:@"Fresh name"]);
}

static void PutString(NSMutableData *data, NSUInteger offset, uint32_t sid, NSString *value)
{
    NSData *utf8 = [value dataUsingEncoding:NSUTF8StringEncoding];
    Put32(data, offset, sid);
    Put32(data, offset + 4, (uint32_t)utf8.length);
    memcpy((uint8_t *)data.mutableBytes + offset + 8, utf8.bytes, utf8.length);
    // No terminator when the length is a multiple of 4, like the real store;
    // fill the next word so a missing-terminator bug would read garbage.
    if (utf8.length % 4 == 0) ((uint8_t *)data.mutableBytes)[offset + 8 + utf8.length] = 0x30;
    else ((uint8_t *)data.mutableBytes)[offset + 8 + utf8.length] = 0;
}

static NSString *const kAppPath = @"/private/var/mobile/Containers/Data/Application/4CE791DB-6B04-4A39-8F59-AF32BA61D494";
static NSString *const kPluginPath = @"/private/var/mobile/Containers/Data/PluginKitPlugin/42D859EB-1323-451C-88F6-01AEE4F45958";
static NSString *const kSharedPath = @"/private/var/mobile/Containers/Data/PluginKitPlugin/051B043F-07C6-4AB6-9B43-F70BFA8B1A81";

// Bundle record: +0x0c id, +0x68 container path, +0x6c name, +0x74 display
// name. Plugin records (0x118 bytes): +0x00 id, +0x54 container path.
static NSData *StoreWithContainers(void)
{
    NSMutableData *data = [NSMutableData dataWithLength:0x3000];
    memcpy(data.mutableBytes, "bdsl", 4);
    const NSUInteger bundle = 0x200, plugin = 0x500, other = 0x700, third = 0x900;
    Put32(data, bundle + 4, 0x250);
    Put32(data, bundle + 8 + 0x0c, 1u << 2);
    Put32(data, bundle + 8 + 0x68, 2u << 2);
    Put32(data, bundle + 8 + 0x6c, 3u << 2);
    Put32(data, bundle + 8 + 0x74, 3u << 2);
    Put32(data, plugin + 4, 0x118);
    Put32(data, plugin + 8 + 0x00, 4u << 2);
    Put32(data, plugin + 8 + 0x54, 5u << 2);
    // Two extensions claiming the same container: neither is trusted.
    Put32(data, other + 4, 0x118);
    Put32(data, other + 8 + 0x00, 4u << 2);
    Put32(data, other + 8 + 0x54, 6u << 2);
    Put32(data, third + 4, 0x118);
    Put32(data, third + 8 + 0x00, 7u << 2);
    Put32(data, third + 8 + 0x54, 6u << 2);
    PutString(data, 0x1000, 1, @"com.example.app");
    PutString(data, 0x1080, 2, kAppPath);                       // 84 bytes
    PutString(data, 0x1100, 3, @"AppName8");                    // 8 bytes
    PutString(data, 0x1180, 4, @"com.example.app.widget");
    PutString(data, 0x1200, 5, kPluginPath);                    // 88 bytes
    PutString(data, 0x1280, 6, kSharedPath);
    PutString(data, 0x1300, 7, @"com.example.other");
    return data;
}

static void TestContainerMapping(NSString *path)
{
    WriteData(StoreWithContainers(), path);
    [NSUserDefaults.standardUserDefaults setObject:path forKey:@"WQLaunchServicesStore"];
    CLCheck([cl_bundle_id_for_container(kAppPath) isEqualToString:@"com.example.app"]);
    CLCheck([cl_bundle_id_for_container([kAppPath substringFromIndex:8]) isEqualToString:@"com.example.app"]);  // /var/...
    CLCheck([cl_bundle_id_for_container(kPluginPath) isEqualToString:@"com.example.app.widget"]);
    CLCheck(cl_bundle_id_for_container(kSharedPath) == nil);
    CLCheck(cl_bundle_id_for_container(@"/private/var/mobile/Containers/Data/Application/not-a-uuid") == nil);
    // A display name whose length is a multiple of 4 has no terminator.
    CLCheck([cl_display_name(@"com.example.app") isEqualToString:@"AppName8"]);
}

static void TestOversizedStoreFailsClosed(NSString *path)
{
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    CLCheck(fd >= 0);
    if (fd < 0) return;
    off_t size = (off_t)(64u * 1024u * 1024u + 1u);
    CLCheck(ftruncate(fd, size) == 0);
    CLCheck(write(fd, "bdsl", 4) == 4);
    close(fd);
    CLCheck(cl_display_name(@"com.example.international") == nil);
}

int main(void)
{
    @autoreleasepool {
        NSString *path = TemporaryStorePath();
        id oldPreference = [NSUserDefaults.standardUserDefaults objectForKey:@"WQLaunchServicesStore"];
        @try {
            [NSUserDefaults.standardUserDefaults removeObjectForKey:@"WQLaunchServicesStore"];
            TestRetryAfterDiscoveryFailure(path);
            TestRefreshAndUnicodeSafety(path);
            TestContainerMapping(path);
            TestOversizedStoreFailsClosed(path);
        } @finally {
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            if (oldPreference) [NSUserDefaults.standardUserDefaults setObject:oldPreference forKey:@"WQLaunchServicesStore"];
            else [NSUserDefaults.standardUserDefaults removeObjectForKey:@"WQLaunchServicesStore"];
        }
        if (failures) {
            fprintf(stderr, "%d LaunchServices regression check(s) failed\n", failures);
            return 1;
        }
        puts("All LaunchServices regression tests passed.");
    }
    return 0;
}
