#import "../Core/CLSafety.h"
#import <stdio.h>
#import <stdlib.h>

static void CLRequire(BOOL condition, NSString *message)
{
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

int main(void)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *root = [CLSafetyCanonicalPath(NSTemporaryDirectory()) stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"wq-cache-safety-%u", arc4random()]];
    NSString *container = [root stringByAppendingPathComponent:@"container"];
    NSString *library = [container stringByAppendingPathComponent:@"Library"];
    NSString *caches = [library stringByAppendingPathComponent:@"Caches"];
    NSString *outside = [root stringByAppendingPathComponent:@"outside"];
    NSString *outsideCaches = [outside stringByAppendingPathComponent:@"Caches"];
    NSError *error = nil;
    CLRequire([fm createDirectoryAtPath:caches withIntermediateDirectories:YES attributes:nil error:&error],
              [NSString stringWithFormat:@"create fixture: %@", error]);
    CLRequire([fm createDirectoryAtPath:outsideCaches withIntermediateDirectories:YES attributes:nil error:&error],
              [NSString stringWithFormat:@"create outside fixture: %@", error]);

    CLRequire(CLSafetyHasNoSymlinkAncestry(container, NO), @"ordinary container ancestry accepted");
    CLRequire(CLSafetyTargetMatchesContainer(caches, container, @"Library/Caches"),
              @"ordinary target matches container");
    NSString *dotTarget = [container stringByAppendingPathComponent:@"Library/../Library/Caches"];
    CLRequire(!CLSafetyHasNoSymlinkAncestry(dotTarget, YES), @"dot-directory traversal rejected");
    CLRequire(!CLSafetyTargetMatchesContainer(dotTarget, container, @"Library/Caches"),
              @"dot-directory target rejected");

    CLRequire([fm removeItemAtPath:library error:&error], @"remove ordinary Library");
    CLRequire([fm createSymbolicLinkAtPath:library withDestinationPath:outside error:&error],
              [NSString stringWithFormat:@"create intermediate symlink: %@", error]);
    CLRequire(!CLSafetyHasNoSymlinkAncestry(caches, YES), @"intermediate symlink rejected");
    CLRequire(!CLSafetyTargetMatchesContainer(caches, container, @"Library/Caches"),
              @"intermediate symlink target rejected");

    CLRequire([fm removeItemAtPath:library error:&error], @"remove intermediate symlink");
    CLRequire([fm createDirectoryAtPath:library withIntermediateDirectories:YES attributes:nil error:&error],
              @"restore Library");
    CLRequire([fm createSymbolicLinkAtPath:caches withDestinationPath:outsideCaches error:&error],
              [NSString stringWithFormat:@"create final symlink: %@", error]);
    CLRequire(!CLSafetyHasNoSymlinkAncestry(caches, YES), @"final symlink rejected");
    CLRequire(!CLSafetyTargetMatchesContainer(caches, container, @"Library/Caches"),
              @"final symlink target rejected");

    CLRequire([fm removeItemAtPath:caches error:&error], @"remove final symlink");
    CLRequire(CLSafetyHasNoSymlinkAncestry(caches, YES), @"missing final target allowed");
    CLRequire(CLSafetyTargetMatchesContainer(caches, container, @"Library/Caches"),
              @"missing final target retains expected canonical shape");

    CLRequire([fm removeItemAtPath:library error:&error], @"remove missing ancestor");
    CLRequire(!CLSafetyHasNoSymlinkAncestry(caches, YES), @"missing ancestor rejected");
    CLRequire(!CLSafetyTargetMatchesContainer(caches, container, @"Library/Caches"),
              @"missing ancestor target rejected");

    [fm removeItemAtPath:root error:nil];
    printf("CLCacheSafetyTests: passed\n");
    return 0;
}
