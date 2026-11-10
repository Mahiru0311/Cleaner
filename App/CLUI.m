//
//  CLUI.m
//  Cleaner v2 — extracted from WQUI.m (v0.1, commit 201591c8), renamed.
//  Cleaner shared UI helpers
//  GPL-3.0-or-later.
//

#import "CLUI.h"
#import "CLGrant.h"
#import "CLLaunchServices.h"
#import <sys/sysctl.h>
#import <sys/utsname.h>

// "iPhone 17 Pro Max (iPhone18,2)\niOS 27.0.1 (24A446)"
NSString *cl_device_line(void)
{
    struct utsname u;
    NSString *machine = (uname(&u) == 0) ? @(u.machine) : @"unknown";
    char build[64] = {0};
    size_t len = sizeof(build);
    NSString *buildStr = (sysctlbyname("kern.osversion", build, &len, NULL, 0) == 0) ? @(build) : nil;
    NSDictionary *names = @{
        @"iPhone17,1": @"iPhone 16 Pro", @"iPhone17,2": @"iPhone 16 Pro Max",
        @"iPhone17,3": @"iPhone 16", @"iPhone17,4": @"iPhone 16 Plus", @"iPhone17,5": @"iPhone 16e",
        @"iPhone18,1": @"iPhone 17 Pro", @"iPhone18,2": @"iPhone 17 Pro Max",
        @"iPhone18,3": @"iPhone 17", @"iPhone18,4": @"iPhone Air",
    };
    NSString *marketing = names[machine];
    NSString *model = marketing ? [NSString stringWithFormat:@"%@ (%@)", marketing, machine] : machine;
    NSString *ver = UIDevice.currentDevice.systemVersion;
    return buildStr ? [NSString stringWithFormat:@"%@ · iOS %@ (%@)", model, ver, buildStr]
                    : [NSString stringWithFormat:@"%@ · iOS %@", model, ver];
}

// A small centered label with the device/iOS line, for a table header.
UIView *cl_device_header(CGFloat width)
{
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 50)];
    UILabel *header = [UILabel new];
    header.numberOfLines = 0;
    header.textAlignment = NSTextAlignmentCenter;
    header.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightMedium];
    header.textColor = UIColor.secondaryLabelColor;
    header.backgroundColor = UIColor.secondarySystemBackgroundColor;
    header.text = cl_device_line();
    header.frame = CGRectMake(0, 0, width, 34);
    header.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [box addSubview:header];  // 16 pt of clear space below the strip
    return box;
}

// Private: app icon by bundle id (in UIKit; guarded with respondsToSelector).
@interface UIImage (CLPrivate)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bid format:(int)fmt scale:(CGFloat)scale;
@end

// Small grey fingerprint of an icon, to recognise iOS's blank placeholder.
static NSData *cl_icon_fingerprint(UIImage *img)
{
    const size_t s = 12;
    uint8_t px[12 * 12 * 4] = {0};
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, s, s, 8, s * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) return nil;
    if (img.CGImage) CGContextDrawImage(ctx, CGRectMake(0, 0, s, s), img.CGImage);
    CGContextRelease(ctx);
    return [NSData dataWithBytes:px length:sizeof(px)];
}

// Device scale, cached once from the foreground scene. Lists warm icons
// from background queues, where the scene walk is unavailable — the old code
// then fell back to 2.0 and asked iOS for a 120px icon on a 3x phone.
// iPhone 17 Pro Max is 3x; default to 3.0 so a background load still gets
// the largest icon (180px for the 60pt format).
static CGFloat cl_device_scale(void)
{
    static CGFloat scale = 0;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        scale = 3.0;
        if (NSThread.isMainThread) {
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if ([scene isKindOfClass:UIWindowScene.class] && scene.activationState == UISceneActivationStateForegroundActive) {
                    scale = ((UIWindowScene *)scene).screen.scale;
                    break;
                }
            }
        }
    });
    return scale;
}

static UIImage *cl_raw_icon_format(NSString *bundleID, int format)
{
    if (![UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)]) return nil;
    return [UIImage _applicationIconImageForBundleIdentifier:bundleID format:format scale:cl_device_scale()];
}

// The real icon for bundleID, or nil when iOS only has its placeholder.
// Format 2 is the 60pt icon (180px @3x). On some releases iOS hands out the
// placeholder for one format but a real icon for another, so the formats are
// tried largest-first before giving up to the bundle fallback.
static UIImage *cl_real_icon(NSString *bundleID)
{
    static NSData *placeholder;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ placeholder = cl_icon_fingerprint(cl_raw_icon_format(@"com.mahiru.cleaner.no-such-app", 2)); });
    static const int formats[] = {2, 3, 1, 0, 4};
    for (size_t i = 0; i < sizeof(formats) / sizeof(formats[0]); i++) {
        UIImage *raw = cl_raw_icon_format(bundleID, formats[i]);
        if (!raw || !raw.CGImage) continue;
        NSData *fp = cl_icon_fingerprint(raw);
        if (!placeholder || fp.length != placeholder.length) return raw;
        // Near-identical to the placeholder (allow small rendering differences).
        const uint8_t *a = fp.bytes, *b = placeholder.bytes;
        unsigned long diff = 0;
        for (NSUInteger j = 0; j < fp.length; j++) diff += (unsigned long)abs((int)a[j] - (int)b[j]);
        if (diff / fp.length >= 8) return raw;
    }
    return nil;
}

// The icon from the app's own bundle, for when iOS only hands out its
// placeholder (iOS 26 refuses this app's icon requests). Reads the primary
// icon names from Info.plist and loads the matching PNG files.
static UIImage *cl_bundle_icon(NSString *bundleID)
{
    NSString *path = cl_bundle_path_for_id(bundleID);
    if (!path.length) return nil;
    NSString *plistPath = [path stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    if (!info && cl_grant(path)) info = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    if (![info isKindOfClass:NSDictionary.class]) return nil;
    NSMutableArray<NSString *> *names = [NSMutableArray new];
    for (NSString *key in @[@"CFBundleIcons", @"CFBundleIcons~ipad"]) {
        NSDictionary *primary = [info[key] isKindOfClass:NSDictionary.class] ? info[key][@"CFBundlePrimaryIcon"] : nil;
        if (![primary isKindOfClass:NSDictionary.class]) continue;
        if ([primary[@"CFBundleIconName"] isKindOfClass:NSString.class]) [names addObject:primary[@"CFBundleIconName"]];
        NSArray *files = [primary[@"CFBundleIconFiles"] isKindOfClass:NSArray.class] ? primary[@"CFBundleIconFiles"] : @[];
        for (id file in files.reverseObjectEnumerator) if ([file isKindOfClass:NSString.class]) [names addObject:file];
    }
    if ([info[@"CFBundleIconFile"] isKindOfClass:NSString.class]) [names addObject:info[@"CFBundleIconFile"]];
    [names addObjectsFromArray:@[@"AppIcon60x60", @"AppIcon"]];
    // Only the PNG files apps ship next to their asset catalog. Loading from
    // the catalog (UIImage imageNamed:inBundle:) aborts inside UIKit when an
    // entry exists but can't be rendered (crash on 27.0.1, build 21).
    for (NSString *name in names) {
        NSString *base = name.stringByDeletingPathExtension;
        for (NSString *suffix in @[@"@3x.png", @"@2x.png", @"@2x~ipad.png", @"~ipad.png", @".png"]) {
            UIImage *image = [UIImage imageWithContentsOfFile:[path stringByAppendingPathComponent:[base stringByAppendingString:suffix]]];
            if (image.CGImage) return image;
        }
    }
    return nil;
}

// Filza-style app icon: the app's REAL icon at its native resolution,
// cropped to a square (aspect-fill, never stretched) and masked with the
// iOS continuous squircle — the same curve SpringBoard uses (CALayer
// cornerCurve = continuous, radius 22.37% of the side). The old code drew
// the icon into a fixed 40pt bitmap with a plain UIBezierPath rounded rect
// (circular arcs, not a squircle) and stretched non-square sources into a
// square — that is what made the icons look soft and wrong next to Filza.
// The output keeps the source's pixel size (180px for a 60pt@3x icon) so
// the 36pt rows downscale from full resolution instead of upscaling a
// 40pt thumbnail.
static UIImage *cl_round_icon(UIImage *raw)
{
    if (!raw || !raw.CGImage) return raw;
    CGFloat scale = raw.scale > 0 ? raw.scale : cl_device_scale();
    CGFloat side = MIN(raw.size.width, raw.size.height);
    if (side <= 0) return raw;
    // Aspect-fill center crop: the largest centered square of the source.
    CGFloat px = raw.size.width * scale, py = raw.size.height * scale;
    CGFloat crop = MIN(px, py);
    CGRect sourceRect = CGRectMake((px - crop) / 2, (py - crop) / 2, crop, crop);
    CGImageRef cropped = CGImageCreateWithImageInRect(raw.CGImage, sourceRect);
    if (!cropped) return raw;
    CALayer *layer = [CALayer layer];
    layer.frame = CGRectMake(0, 0, side, side);
    layer.contents = (__bridge id)cropped;
    // Without this the layer renders its contents at 1x into the 3x context
    // and the icon comes out blurry — the whole point of this rewrite.
    layer.contentsScale = scale;
    layer.contentsGravity = kCAGravityResizeAspectFill;
    layer.cornerRadius = side * 0.2237;
    layer.cornerCurve = kCACornerCurveContinuous;
    layer.masksToBounds = YES;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = scale;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:format];
    UIImage *out = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [layer renderInContext:ctx.CGContext];
    }];
    CGImageRelease(cropped);
    return out;
}

// Symbol tile for system services and extensions that have no icon at all,
// picked from keywords in the bundle id.
static UIImage *cl_service_tile(NSString *bundleID)
{
    static NSArray<NSArray *> *rules;
    static NSCache *tiles;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        tiles = [NSCache new];
        UIColor *blue = UIColor.systemBlueColor, *green = UIColor.systemGreenColor, *red = UIColor.systemRedColor,
                *orange = UIColor.systemOrangeColor, *purple = UIColor.systemPurpleColor, *indigo = UIColor.systemIndigoColor,
                *teal = UIColor.systemTealColor, *pink = UIColor.systemPinkColor, *gray = UIColor.systemGrayColor;
        // keywords (lower case, any match), symbol, colour
        rules = @[
            @[@[@"emoji"], @"face.smiling.inverse", orange],
            @[@[@"keyboard", @"inputui", @"textinput", @"dictation"], @"keyboard.fill", gray],
            @[@[@"airdrop", @"sharing", @"sharesheet"], @"antenna.radiowaves.left.and.right", blue],
            @[@[@"widget", @"chrono"], @"square.grid.2x2.fill", blue],
            @[@[@"screenshot", @"screencapture", @"screenrecord"], @"camera.viewfinder", indigo],
            @[@[@"poster", @"wallpaper"], @"photo.on.rectangle.angled", purple],
            @[@[@"siri", @"assistant"], @"waveform", indigo],
            @[@[@"camera"], @"camera.fill", gray],
            @[@[@"photo"], @"photo.fill", orange],
            @[@[@"music", @"audio", @"shazam", @"musicrecognition"], @"music.note", pink],
            @[@[@"headphone", @"airpods", @"bluetooth"], @"headphones", gray],
            @[@[@"hearing"], @"ear.fill", blue],
            @[@[@"weather"], @"cloud.sun.fill", teal],
            @[@[@"location", @"maps", @"navigation"], @"location.fill", blue],
            @[@[@"health", @"fitness", @"workout"], @"heart.fill", red],
            @[@[@"pay", @"wallet", @"passbook", @"cash", @"finance"], @"creditcard.fill", green],
            @[@[@"mail"], @"envelope.fill", blue],
            @[@[@"message", @"sms", @"imessage"], @"message.fill", green],
            @[@[@"facetime", @"video"], @"video.fill", green],
            @[@[@"phone", @"call", @"telephony"], @"phone.fill", green],
            @[@[@"notification", @"usernotification", @"bulletin"], @"bell.fill", red],
            @[@[@"shortcut", @"workflow", @"intent"], @"square.on.square", indigo],
            @[@[@"safari", @"web"], @"safari.fill", blue],
            @[@[@"news", @"stocks"], @"newspaper.fill", red],
            @[@[@"calendar", @"event"], @"calendar", red],
            @[@[@"note", @"paper"], @"note.text", orange],
            @[@[@"reminder"], @"checklist", blue],
            @[@[@"game"], @"gamecontroller.fill", purple],
            @[@[@"auth", @"account", @"appsso", @"password", @"keychain", @"tcc", @"privacy"], @"lock.fill", gray],
            @[@[@"print"], @"printer.fill", gray],
            @[@[@"clarity", @"accessib"], @"accessibility", blue],
            @[@[@"home"], @"house.fill", orange],
            @[@[@"findmy", @"fmd", @"fmip"], @"location.circle.fill", green],
            @[@[@"carplay", @"carradio", @"cartrip", @"car."], @"car.fill", gray],
            @[@[@"tvremote", @"tvsetup", @"com.apple.tv"], @"tv.fill", gray],
            @[@[@"book"], @"book.fill", orange],
            @[@[@"podcast"], @"mic.fill", purple],
            @[@[@"spotlight", @"search"], @"magnifyingglass", gray],
            @[@[@"diagnostic", @"logging", @"crash", @"analytics"], @"stethoscope", gray],
            @[@[@"font"], @"textformat", gray],
            @[@[@"translate"], @"character.bubble.fill", blue],
            @[@[@"file", @"document", @"cloud"], @"folder.fill", blue],
            @[@[@"setup", @"buddy", @"onboarding"], @"gearshape.2.fill", gray],
        ];
    });
    NSString *key = bundleID.lowercaseString;
    NSString *symbol = @"gearshape.fill";
    UIColor *color = UIColor.systemGrayColor;
    for (NSArray *rule in rules) {
        BOOL hit = NO;
        for (NSString *word in rule[0]) if ([key containsString:word]) { hit = YES; break; }
        if (hit) { symbol = rule[1]; color = rule[2]; break; }
    }
    NSString *cacheKey = [symbol stringByAppendingString:color.description];
    UIImage *tile = [tiles objectForKey:cacheKey];
    if (tile) return tile;
    // Draw the tile square and unrounded, then mask it with the same
    // continuous squircle as real icons (cl_round_icon) — one curve
    // everywhere, instead of the old plain rounded rect here.
    CGFloat s = 60;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = cl_device_scale();
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(s, s) format:format];
    UIColor *fill = [color resolvedColorWithTraitCollection:[UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleLight]];
    UIImage *square = [r imageWithActions:^(UIGraphicsImageRendererContext *__unused ctx) {
        [fill setFill];
        UIRectFill(CGRectMake(0, 0, s, s));
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:28 weight:UIImageSymbolWeightSemibold];
        UIImage *g = [[UIImage systemImageNamed:symbol withConfiguration:cfg] ?: [UIImage systemImageNamed:@"gearshape.fill" withConfiguration:cfg]
                      imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
        [g drawInRect:CGRectMake((s - g.size.width) / 2, (s - g.size.height) / 2, g.size.width, g.size.height)];
    }];
    tile = cl_round_icon(square);
    [tiles setObject:tile forKey:cacheKey];
    return tile;
}

// Rounded app icon for a bundle id, cached. Falls back to the closest parent
// app's icon (extensions: com.foo.app.widget -> com.foo.app), then to a
// neutral service tile. Nil only without a bundle id.
UIImage *cl_app_icon(NSString *bundleID)
{
    if (!bundleID.length) return nil;
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; });
    UIImage *cached = [cache objectForKey:bundleID];
    if (cached) return cached;
    // The bundle fallback reads files and may ask for access: never on the
    // main thread. Lists warm the cache from their background passes; a
    // main-thread miss gets the tile without caching it.
    BOOL background = !NSThread.isMainThread;
    UIImage *raw = cl_real_icon(bundleID) ?: (background ? cl_bundle_icon(bundleID) : nil);
    NSArray *parts = [bundleID componentsSeparatedByString:@"."];
    for (NSInteger n = (NSInteger)parts.count - 1; !raw && n >= 3; n--)
    {
        NSString *parent = [[parts subarrayWithRange:NSMakeRange(0, (NSUInteger)n)] componentsJoinedByString:@"."];
        raw = cl_real_icon(parent) ?: (background ? cl_bundle_icon(parent) : nil);
    }
    UIImage *icon = raw ? cl_round_icon(raw) : cl_service_tile(bundleID);
    if (raw || background) [cache setObject:icon forKey:bundleID];
    return icon;
}

dispatch_queue_t cl_io(void)
{
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("wqfiles.io", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

void cl_alert(UIViewController *host, NSString *title, NSString *message)
{
    if (!host || !host.isViewLoaded || !host.view.window) return;
    UIWindowScene *scene = host.view.window.windowScene;
    if (scene && scene.activationState != UISceneActivationStateForegroundActive) return;
    UINavigationController *nav = host.navigationController;
    if (nav && nav.topViewController != host) return;
    if (host.presentedViewController && !host.presentedViewController.isBeingDismissed) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [host presentViewController:alert animated:YES completion:nil];
}

NSString *cl_size_text(unsigned long long size)
{
    if (size == 0) return @"0 KB";
    return [NSByteCountFormatter stringFromByteCount:(long long)size countStyle:NSByteCountFormatterCountStyleFile];
}
