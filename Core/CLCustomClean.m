//
//  CLCustomClean.m
//  Cleaner v2.3 — user-defined cleaning rules, presets and excludes.
//

#import "CLCustomClean.h"
#import "CLLaunchServices.h"

NSString *const CLCustomRuleIDKey = @"ruleID";
NSString *const CLCustomRuleBundleIDKey = @"bundleID";
NSString *const CLCustomRuleKindKey = @"kind";
NSString *const CLCustomRulePatternKey = @"pattern";
NSString *const CLCustomRuleEnabledKey = @"enabled";

NSString *const CLCustomPresetTitleKey = @"title";
NSString *const CLCustomPresetDetailKey = @"detail";
NSString *const CLCustomPresetRulesKey = @"rules";

static NSString *cl_custom_clean_plist_path(void)
{
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    return dir.length ? [dir stringByAppendingPathComponent:@"cl-custom-rules.plist"] : nil;
}

static NSDictionary *cl_custom_clean_load_plist(void)
{
    NSString *path = cl_custom_clean_plist_path();
    NSDictionary *d = path ? [NSDictionary dictionaryWithContentsOfFile:path] : nil;
    return [d isKindOfClass:NSDictionary.class] ? d : @{};
}

static void cl_custom_clean_save_plist(NSDictionary *d)
{
    NSString *path = cl_custom_clean_plist_path();
    if (path) [d writeToFile:path atomically:YES];
}

NSArray<NSDictionary *> *cl_custom_clean_rules(void)
{
    NSArray *rules = cl_custom_clean_load_plist()[@"rules"];
    return [rules isKindOfClass:NSArray.class] ? rules : @[];
}

void cl_custom_clean_save_rules(NSArray<NSDictionary *> *rules)
{
    NSMutableDictionary *d = [cl_custom_clean_load_plist() mutableCopy];
    d[@"rules"] = rules ?: @[];
    cl_custom_clean_save_plist(d);
}

NSArray<NSString *> *cl_custom_clean_excluded_apps(void)
{
    NSArray *apps = cl_custom_clean_load_plist()[@"excludes"][@"apps"];
    return [apps isKindOfClass:NSArray.class] ? apps : @[];
}

NSArray<NSString *> *cl_custom_clean_excluded_folders(void)
{
    NSArray *folders = cl_custom_clean_load_plist()[@"excludes"][@"folders"];
    return [folders isKindOfClass:NSArray.class] ? folders : @[];
}

void cl_custom_clean_save_excludes(NSArray<NSString *> *apps, NSArray<NSString *> *folders)
{
    NSMutableDictionary *d = [cl_custom_clean_load_plist() mutableCopy];
    d[@"excludes"] = @{ @"apps": apps ?: @[], @"folders": folders ?: @[] };
    cl_custom_clean_save_plist(d);
}

NSDictionary *cl_custom_clean_make_rule(NSString *bundleID, NSString *kind, NSString *pattern)
{
    return @{ CLCustomRuleIDKey: NSUUID.UUID.UUIDString,
              CLCustomRuleBundleIDKey: bundleID.length ? bundleID : @"*",
              CLCustomRuleKindKey: kind, CLCustomRulePatternKey: pattern,
              CLCustomRuleEnabledKey: @YES };
}

NSArray<NSDictionary *> *cl_custom_clean_presets(void)
{
    NSMutableArray *presets = [NSMutableArray new];
    NSArray *defs = @[
        @{ @"title": @"视频缓存", @"detail": @"扩展 .mp4 / .mov / .m3u8 / .ts（缓存与临时目录）",
           @"exts": @[@".mp4", @".mov", @".m3u8", @".ts"] },
        @{ @"title": @"图片缓存", @"detail": @"扩展 .jpg / .jpeg / .png / .webp / .heic / .gif（缓存与临时目录）",
           @"exts": @[@".jpg", @".jpeg", @".png", @".webp", @".heic", @".gif"] },
        @{ @"title": @"日志文件", @"detail": @"扩展 .log / .txt（缓存与临时目录）",
           @"exts": @[@".log", @".txt"] },
        @{ @"title": @"临时文件", @"detail": @"文件夹 tmp（整个临时目录）",
           @"folder": @"tmp" },
    ];
    for (NSDictionary *def in defs) {
        NSMutableArray *rules = [NSMutableArray new];
        for (NSString *ext in def[@"exts"]) {
            [rules addObject:cl_custom_clean_make_rule(@"*", @"extension", ext)];
        }
        if (def[@"folder"]) [rules addObject:cl_custom_clean_make_rule(@"*", @"folder", def[@"folder"])];
        [presets addObject:@{ CLCustomPresetTitleKey: def[@"title"],
                              CLCustomPresetDetailKey: def[@"detail"],
                              CLCustomPresetRulesKey: [rules copy] }];
    }
    return [presets copy];
}

NSString *cl_custom_clean_rule_summary(NSDictionary *rule)
{
    NSString *bid = rule[CLCustomRuleBundleIDKey];
    NSString *app = [bid isEqualToString:@"*"] ? @"全部应用" : (cl_display_name(bid) ?: bid);
    NSString *kind = rule[CLCustomRuleKindKey];
    NSString *pattern = rule[CLCustomRulePatternKey] ?: @"";
    NSString *what = [kind isEqualToString:@"folder"] ? [NSString stringWithFormat:@"文件夹 %@", pattern]
        : [kind isEqualToString:@"extension"] ? [NSString stringWithFormat:@"扩展 %@", pattern]
        : [NSString stringWithFormat:@"文件名含 %@", pattern];
    return [NSString stringWithFormat:@"%@ · %@", app, what];
}

BOOL cl_custom_clean_validate_folder_pattern(NSString *pattern, NSString **reason)
{
    if (!pattern.length) {
        if (reason) *reason = @"文件夹路径为空";
        return NO;
    }
    if (pattern.isAbsolutePath) {
        if (reason) *reason = @"请填容器内的相对路径，例如 Library/Caches/xxx";
        return NO;
    }
    NSString *std = [pattern stringByStandardizingPath];
    for (NSString *component in std.pathComponents) {
        if ([component isEqualToString:@"."] || [component isEqualToString:@".."]) {
            if (reason) *reason = @"路径不能包含 . 或 ..";
            return NO;
        }
    }
    if ([std isEqualToString:@"Documents"] || [std isEqualToString:@"Library"]) {
        if (reason) *reason = @"不能直接清理 Documents 或 Library 本身——请用「清空数据」（会先备份）";
        return NO;
    }
    return YES;
}

// A folder target is user data when it is not under the disposable trees
// (Library/Caches, tmp). Cleaning it is allowed, but the run result warns.
static BOOL cl_custom_clean_folder_is_user_data(NSString *pattern)
{
    return ![pattern hasPrefix:@"Library/Caches"] && ![pattern isEqualToString:@"tmp"] &&
           ![pattern hasPrefix:@"tmp/"];
}

void cl_custom_clean_run(NSArray<CLCacheItem *> *apps, CLCustomCleanProgress progress,
                         void (^completion)(NSDictionary *result))
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NSDictionary *> *rules = cl_custom_clean_rules();
        NSArray<NSString *> *excludedApps = cl_custom_clean_excluded_apps();
        NSArray<NSString *> *excludedFolders = cl_custom_clean_excluded_folders();
        NSMutableArray *perRule = [NSMutableArray new];
        NSMutableArray *warnings = [NSMutableArray new];
        unsigned long long totalFreed = 0;
        NSUInteger totalFailed = 0;
        for (NSDictionary *rule in rules) {
            if (![rule[CLCustomRuleEnabledKey] boolValue]) continue;
            NSString *kind = rule[CLCustomRuleKindKey];
            NSString *pattern = rule[CLCustomRulePatternKey] ?: @"";
            NSString *bid = rule[CLCustomRuleBundleIDKey] ?: @"*";
            unsigned long long freed = 0;
            NSUInteger failed = 0;
            NSString *reason = nil;
            if (progress) progress([NSString stringWithFormat:@"正在清理 %@…", cl_custom_clean_rule_summary(rule)]);
            for (CLCacheItem *app in apps) {
                if (app.crashLogs || !app.containerPath.length) continue;
                if (![bid isEqualToString:@"*"] && ![app.bundleID isEqualToString:bid]) continue;
                if ([excludedApps containsObject:app.bundleID]) continue;
                NSString *container = app.containerPath;
                if ([kind isEqualToString:@"folder"]) {
                    if (!cl_custom_clean_validate_folder_pattern(pattern, &reason)) { failed++; continue; }
                    if ([excludedFolders containsObject:pattern]) continue;
                    if (cl_custom_clean_folder_is_user_data(pattern)) {
                        NSString *w = [NSString stringWithFormat:@"%@（%@）不是缓存目录，已按规则清理",
                                       pattern, app.name];
                        if (![warnings containsObject:w]) [warnings addObject:w];
                    }
                    NSString *target = [container stringByAppendingPathComponent:pattern];
                    unsigned long long removed = 0;
                    NSString *r = nil;
                    if (!cl_purge_folder_contents(target, container, &removed, &r)) {
                        failed++;
                        if (r.length) reason = r;
                    } else {
                        freed += removed;
                    }
                } else if ([kind isEqualToString:@"extension"] || [kind isEqualToString:@"name"]) {
                    NSString *ext = [kind isEqualToString:@"extension"] ? pattern : nil;
                    if (ext.length && ![ext hasPrefix:@"."]) ext = [@"." stringByAppendingString:ext];
                    NSString *name = [kind isEqualToString:@"name"] ? pattern : nil;
                    unsigned long long removed = 0;
                    NSUInteger failCount = 0;
                    NSString *r = nil;
                    cl_clean_matching_files(container, ext ? @[ext] : nil, name ? @[name] : nil,
                                            excludedFolders, &removed, &failCount, &r);
                    freed += removed;
                    failed += failCount;
                    if (r.length) reason = r;
                }
            }
            totalFreed += freed;
            totalFailed += failed;
            NSMutableDictionary *entry = [@{ @"rule": rule, @"freed": @(freed), @"failed": @(failed) } mutableCopy];
            if (reason.length) entry[@"reason"] = reason;
            [perRule addObject:entry];
        }
        if (completion) {
            completion(@{ @"freed": @(totalFreed), @"failed": @(totalFailed),
                          @"perRule": [perRule copy], @"warnings": [warnings copy] });
        }
    });
}
