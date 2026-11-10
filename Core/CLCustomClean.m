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
// v2.4 filters (extension/name rules only; absent = no filter):
NSString *const CLCustomRuleMinAgeDaysKey = @"minAgeDays";  // NSNumber days: only files older than this
NSString *const CLCustomRuleMinSizeKey = @"minSize";        // NSNumber bytes: only files at least this big
NSString *const CLCustomRuleMaxSizeKey = @"maxSize";        // NSNumber bytes: only files at most this big
NSString *const CLCustomRuleSubfolderKey = @"subfolder";    // NSString: only under this subfolder
                                                            // (e.g. "Library/Caches/com.foo", or a bare
                                                            // name = a subfolder of Library/Caches)
// v2.5 directory rules:
NSString *const CLCustomRuleScopeKey = @"scope";
NSString *const CLCustomRuleScopeAll = @"all";
NSString *const CLCustomRuleScopeFiltered = @"filtered";
NSString *const CLCustomRuleExtensionsKey = @"extensions";  // NSString CSV, e.g. ".mp4,.mov"
NSString *const CLCustomRuleNameKey = @"name";              // NSString filename substring

NSString *const CLCustomPresetTitleKey = @"title";
NSString *const CLCustomPresetDetailKey = @"detail";
NSString *const CLCustomPresetRulesKey = @"rules";

#ifdef CL_ACCESS_TESTING
static NSString *cl_custom_clean_plist_override = nil;
void cl_custom_clean_set_plist_path_for_testing(NSString *path) { cl_custom_clean_plist_override = [path copy]; }
#endif

static NSString *cl_custom_clean_plist_path(void)
{
#ifdef CL_ACCESS_TESTING
    if (cl_custom_clean_plist_override.length) return cl_custom_clean_plist_override;
#endif
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
    return cl_custom_clean_make_rule_full(bundleID, kind, pattern, nil, nil, nil, nil);
}

NSDictionary *cl_custom_clean_make_rule_full(NSString *bundleID, NSString *kind, NSString *pattern,
                                             NSNumber *minAgeDays, NSNumber *minSize,
                                             NSNumber *maxSize, NSString *subfolder)
{
    NSMutableDictionary *rule = [@{ CLCustomRuleIDKey: NSUUID.UUID.UUIDString,
                                    CLCustomRuleBundleIDKey: bundleID.length ? bundleID : @"*",
                                    CLCustomRuleKindKey: kind, CLCustomRulePatternKey: pattern,
                                    CLCustomRuleEnabledKey: @YES } mutableCopy];
    if (minAgeDays) rule[CLCustomRuleMinAgeDaysKey] = minAgeDays;
    if (minSize) rule[CLCustomRuleMinSizeKey] = minSize;
    if (maxSize) rule[CLCustomRuleMaxSizeKey] = maxSize;
    if (subfolder.length) rule[CLCustomRuleSubfolderKey] = subfolder;
    return [rule copy];
}

// v2.5: one directory rule. scope @"all" takes no conditions; scope
// @"filtered" takes at least one (validated by cl_custom_clean_validate_rule).
NSDictionary *cl_custom_clean_make_directory_rule(NSString *bundleID, NSString *pattern, NSString *scope,
                                                  NSString *extensionsCSV, NSString *name,
                                                  NSNumber *minAgeDays, NSNumber *minSize,
                                                  NSNumber *maxSize)
{
    NSMutableDictionary *rule = [@{ CLCustomRuleIDKey: NSUUID.UUID.UUIDString,
                                    CLCustomRuleBundleIDKey: bundleID.length ? bundleID : @"*",
                                    CLCustomRuleKindKey: @"directory",
                                    CLCustomRulePatternKey: pattern,
                                    CLCustomRuleScopeKey: scope.length ? scope : CLCustomRuleScopeAll,
                                    CLCustomRuleEnabledKey: @YES } mutableCopy];
    if (extensionsCSV.length) rule[CLCustomRuleExtensionsKey] = extensionsCSV;
    if (name.length) rule[CLCustomRuleNameKey] = name;
    if (minAgeDays) rule[CLCustomRuleMinAgeDaysKey] = minAgeDays;
    if (minSize) rule[CLCustomRuleMinSizeKey] = minSize;
    if (maxSize) rule[CLCustomRuleMaxSizeKey] = maxSize;
    return [rule copy];
}

// Split an extensions CSV on commas (half-width, full-width) and spaces;
// each entry is trimmed, lowercased, and given a leading "." when missing.
NSArray<NSString *> *cl_custom_clean_parse_extensions(NSString *csv)
{
    if (!csv.length) return @[];
    NSCharacterSet *separators = [NSCharacterSet characterSetWithCharactersInString:@",， \t\n"];
    NSMutableArray<NSString *> *out = [NSMutableArray new];
    for (NSString *part in [csv componentsSeparatedByCharactersInSet:separators]) {
        NSString *ext = [part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!ext.length) continue;
        if (![ext hasPrefix:@"."]) ext = [@"." stringByAppendingString:ext];
        ext = ext.lowercaseString;
        if (![out containsObject:ext]) [out addObject:ext];
    }
    return [out copy];
}

// Resolve a pasted/typed directory path to an app + container-relative
// path. An absolute path (the directory view's "复制路径" copies one) is
// matched against the scanned apps' containers; a relative path is
// resolved under the given app. The container root itself ("", ".", or the
// container path) is refused — a rule must target a subdirectory.
BOOL cl_custom_clean_resolve_pasted_path(NSString *path, NSArray<CLCacheItem *> *apps,
                                        NSString *bundleID,
                                        NSString **bundleIDOut,
                                        NSString **relativeOut,
                                        NSString **reason)
{
    NSString *trimmed = [path stringByTrimmingCharactersInSet:
                         NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length) {
        if (reason) *reason = @"路径为空";
        return NO;
    }
    if (trimmed.isAbsolutePath) {
        NSString *std = [trimmed stringByStandardizingPath];
        // Longest container prefix wins (containers never nest, but a
        // group container could share a prefix with an app container).
        CLCacheItem *best = nil;
        for (CLCacheItem *app in apps) {
            if (app.crashLogs || !app.containerPath.length) continue;
            NSString *container = [app.containerPath stringByStandardizingPath];
            if ([std isEqualToString:container] || [std hasPrefix:[container stringByAppendingString:@"/"]]) {
                if (!best || container.length > best.containerPath.length) best = app;
            }
        }
        if (!best) {
            if (reason) *reason = @"这条路径不属于任何已扫描应用的容器（请先去清理页扫描一次）";
            return NO;
        }
        NSString *container = [best.containerPath stringByStandardizingPath];
        if ([std isEqualToString:container]) {
            if (reason) *reason = @"不能直接选容器根目录，请选里面的一个子目录";
            return NO;
        }
        if (bundleIDOut) *bundleIDOut = best.bundleID;
        if (relativeOut) *relativeOut = [std substringFromIndex:container.length + 1];
        return YES;
    }
    if (!bundleID.length) {
        if (reason) *reason = @"相对路径需要先选一个应用";
        return NO;
    }
    NSString *std = [trimmed stringByStandardizingPath];
    for (NSString *component in std.pathComponents) {
        if ([component isEqualToString:@"."] || [component isEqualToString:@".."]) {
            if (reason) *reason = @"路径不能包含 . 或 ..";
            return NO;
        }
    }
    if ([std isEqualToString:@"."] || !std.length) {
        if (reason) *reason = @"不能直接选容器根目录，请选里面的一个子目录";
        return NO;
    }
    if (bundleIDOut) *bundleIDOut = bundleID;
    if (relativeOut) *relativeOut = std;
    return YES;
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

// Small size formatter for rule summaries (Core must not depend on App's
// cl_size_text).
static NSString *cl_custom_clean_size_text(unsigned long long size)
{
    if (size < 1024) return [NSString stringWithFormat:@"%lluB", size];
    if (size < 1024ull * 1024) return [NSString stringWithFormat:@"%.0fKB", size / 1024.0];
    if (size < 1024ull * 1024 * 1024) return [NSString stringWithFormat:@"%.1fMB", size / 1048576.0];
    return [NSString stringWithFormat:@"%.2fGB", size / 1073741824.0];
}

NSString *cl_custom_clean_rule_summary(NSDictionary *rule)
{
    NSString *bid = rule[CLCustomRuleBundleIDKey];
    NSString *app = [bid isEqualToString:@"*"] ? @"全部应用" : (cl_display_name(bid) ?: bid);
    NSString *kind = rule[CLCustomRuleKindKey];
    NSString *pattern = rule[CLCustomRulePatternKey] ?: @"";
    NSString *what;
    if ([kind isEqualToString:@"folder"]) {
        what = [NSString stringWithFormat:@"文件夹 %@", pattern];
    } else if ([kind isEqualToString:@"directory"]) {
        // v2.5: "微信 · 目录 Library/Caches/xxx（全部）" or
        // "微信 · 目录 … · 扩展 .mp4,.mov · 名字含 thumb · 30天前".
        NSString *scope = rule[CLCustomRuleScopeKey];
        what = [NSString stringWithFormat:@"目录 %@（%@）", pattern,
                [scope isEqualToString:CLCustomRuleScopeFiltered] ? @"按条件" : @"全部"];
        NSString *exts = rule[CLCustomRuleExtensionsKey];
        if (exts.length) what = [what stringByAppendingFormat:@" · 扩展 %@", exts];
        NSString *name = rule[CLCustomRuleNameKey];
        if (name.length) what = [what stringByAppendingFormat:@" · 名字含 %@", name];
        NSMutableString *s = [NSMutableString stringWithFormat:@"%@ · %@", app, what];
        NSNumber *age = rule[CLCustomRuleMinAgeDaysKey];
        if (age) [s appendFormat:@" · %@天前", age];
        NSNumber *minSize = rule[CLCustomRuleMinSizeKey];
        if (minSize && minSize.unsignedLongLongValue > 0)
            [s appendFormat:@" · >%@", cl_custom_clean_size_text(minSize.unsignedLongLongValue)];
        NSNumber *maxSize = rule[CLCustomRuleMaxSizeKey];
        if (maxSize && maxSize.unsignedLongLongValue > 0)
            [s appendFormat:@" · <%@",
             cl_custom_clean_size_text(maxSize.unsignedLongLongValue)];
        return [s copy];
    } else if ([kind isEqualToString:@"extension"]) {
        what = [NSString stringWithFormat:@"扩展 %@", pattern];
    } else {
        what = [NSString stringWithFormat:@"文件名含 %@", pattern];
    }
    NSMutableString *s = [NSMutableString stringWithFormat:@"%@ · %@", app, what];
    NSNumber *age = rule[CLCustomRuleMinAgeDaysKey];
    if (age) [s appendFormat:@" · %@天前", age];
    NSNumber *minSize = rule[CLCustomRuleMinSizeKey];
    if (minSize && minSize.unsignedLongLongValue > 0)
        [s appendFormat:@" · >%@", cl_custom_clean_size_text(minSize.unsignedLongLongValue)];
    NSNumber *maxSize = rule[CLCustomRuleMaxSizeKey];
    if (maxSize && maxSize.unsignedLongLongValue > 0)
        [s appendFormat:@" · <%@",
         cl_custom_clean_size_text(maxSize.unsignedLongLongValue)];
    NSString *sub = rule[CLCustomRuleSubfolderKey];
    if (sub.length) [s appendFormat:@" · 于 %@", sub];
    return [s copy];
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

// Resolves a subfolder scope to a full container-relative path. A bare
// name means a subfolder of Library/Caches, except "tmp" which means the
// tmp directory itself (not Library/Caches/tmp).
static NSString *cl_custom_clean_resolve_subfolder(NSString *sub)
{
    NSString *std = [sub stringByStandardizingPath];
    if ([std containsString:@"/"]) return std;
    if ([std isEqualToString:@"tmp"]) return @"tmp";
    return [@"Library/Caches" stringByAppendingPathComponent:std];
}

// A subfolder scope for extension/name rules: a container-relative path
// under Library/Caches or tmp. A bare name ("com.foo") means a subfolder
// of Library/Caches.
static BOOL cl_custom_clean_validate_subfolder(NSString *sub, NSString **reason)
{
    if (sub.isAbsolutePath) {
        if (reason) *reason = @"子目录请填容器内的相对路径，例如 Library/Caches/xxx";
        return NO;
    }
    NSString *std = [sub stringByStandardizingPath];
    for (NSString *component in std.pathComponents) {
        if ([component isEqualToString:@"."] || [component isEqualToString:@".."]) {
            if (reason) *reason = @"子目录不能包含 . 或 ..";
            return NO;
        }
    }
    NSString *full = cl_custom_clean_resolve_subfolder(sub);
    if (![full isEqualToString:@"Library/Caches"] && ![full hasPrefix:@"Library/Caches/"] &&
        ![full isEqualToString:@"tmp"] && ![full hasPrefix:@"tmp/"]) {
        if (reason) *reason = @"子目录只能在 Library/Caches 或 tmp 之下";
        return NO;
    }
    return YES;
}

static NSArray<NSString *> *cl_custom_clean_roots_for_subfolder(NSString *sub)
{
    if (!sub.length) return nil;  // nil = the default roots (Caches + tmp)
    return @[cl_custom_clean_resolve_subfolder(sub)];
}

// Age/size sanity, shared by extension, name and directory rules.
static BOOL cl_custom_clean_validate_age_size(NSDictionary *rule, NSString **reason)
{
    NSNumber *age = rule[CLCustomRuleMinAgeDaysKey];
    if (age && (age.doubleValue < 0 || age.doubleValue > 3650)) {
        if (reason) *reason = @"保留天数应在 0–3650 天之间";
        return NO;
    }
    NSNumber *minSize = rule[CLCustomRuleMinSizeKey];
    NSNumber *maxSize = rule[CLCustomRuleMaxSizeKey];
    if (minSize && minSize.unsignedLongLongValue > (1ull << 40)) {
        if (reason) *reason = @"最小大小不合理（超过 1TB）";
        return NO;
    }
    if (maxSize && maxSize.unsignedLongLongValue > (1ull << 40)) {
        if (reason) *reason = @"最大大小不合理（超过 1TB）";
        return NO;
    }
    if (minSize && maxSize && maxSize.unsignedLongLongValue > 0 &&
        minSize.unsignedLongLongValue > maxSize.unsignedLongLongValue) {
        if (reason) *reason = @"最小大小不能大于最大大小";
        return NO;
    }
    return YES;
}

// Validate a whole rule: kind + pattern + every filter. Folder rules
// purge a whole folder's contents, so age/size/subfolder filters do not
// apply to them and are refused rather than silently ignored.
BOOL cl_custom_clean_validate_rule(NSDictionary *rule, NSString **reason)
{
    NSString *kind = rule[CLCustomRuleKindKey];
    NSString *pattern = rule[CLCustomRulePatternKey] ?: @"";
    if (![kind isEqualToString:@"folder"] && ![kind isEqualToString:@"extension"] &&
        ![kind isEqualToString:@"name"] && ![kind isEqualToString:@"directory"]) {
        if (reason) *reason = @"规则类型不对（应为 folder / extension / name / directory）";
        return NO;
    }
    if ([kind isEqualToString:@"folder"]) {
        if (!cl_custom_clean_validate_folder_pattern(pattern, reason)) return NO;
        if (rule[CLCustomRuleMinAgeDaysKey] || rule[CLCustomRuleMinSizeKey] ||
            rule[CLCustomRuleMaxSizeKey] || rule[CLCustomRuleSubfolderKey]) {
            if (reason) *reason = @"文件夹规则不支持年龄/大小/子目录筛选";
            return NO;
        }
        return YES;
    }
    if ([kind isEqualToString:@"directory"]) {
        // v2.5: the directory was picked in the picker. The pattern is a
        // container-relative directory path (container root, Documents and
        // Library themselves are refused by the folder-pattern check).
        if (!cl_custom_clean_validate_folder_pattern(pattern, reason)) return NO;
        NSString *scope = rule[CLCustomRuleScopeKey];
        if (!scope.length) scope = CLCustomRuleScopeAll;
        if (![scope isEqualToString:CLCustomRuleScopeAll] &&
            ![scope isEqualToString:CLCustomRuleScopeFiltered]) {
            if (reason) *reason = @"规则范围不对（应为全部或按条件）";
            return NO;
        }
        if (rule[CLCustomRuleSubfolderKey]) {
            if (reason) *reason = @"目录规则本身就是一个目录，不需要再加子目录";
            return NO;
        }
        NSString *exts = rule[CLCustomRuleExtensionsKey];
        NSString *name = rule[CLCustomRuleNameKey];
        BOOL hasCondition = exts.length > 0 || name.length > 0 ||
            rule[CLCustomRuleMinAgeDaysKey] || rule[CLCustomRuleMinSizeKey] ||
            rule[CLCustomRuleMaxSizeKey];
        if ([scope isEqualToString:CLCustomRuleScopeAll]) {
            if (hasCondition) {
                if (reason) *reason = @"清空整个目录的规则不能再加筛选条件";
                return NO;
            }
            return YES;
        }
        // Filtered scope: at least one condition, and each one sane.
        if (!hasCondition) {
            if (reason) *reason = @"按条件删至少要设一个条件（扩展名、文件名、年龄或大小）";
            return NO;
        }
        if (exts.length) {
            NSArray<NSString *> *parsed = cl_custom_clean_parse_extensions(exts);
            if (!parsed.count) {
                if (reason) *reason = @"扩展名填得不对（例如 .mp4,.mov）";
                return NO;
            }
        }
        if (name.length && ([name containsString:@"/"] || [name containsString:@".."])) {
            if (reason) *reason = @"文件名不能包含 / 或 ..";
            return NO;
        }
        return cl_custom_clean_validate_age_size(rule, reason);
    }
    if (!pattern.length) {
        if (reason) *reason = @"匹配内容为空";
        return NO;
    }
    if ([pattern containsString:@"/"] || [pattern containsString:@".."]) {
        if (reason) *reason = @"扩展名/文件名不能包含 / 或 ..";
        return NO;
    }
    if (!cl_custom_clean_validate_age_size(rule, reason)) return NO;
    NSString *sub = rule[CLCustomRuleSubfolderKey];
    if (sub.length && !cl_custom_clean_validate_subfolder(sub, reason)) return NO;
    return YES;
}

// A folder target is user data when it is not under the disposable trees
// (Library/Caches, tmp). Cleaning it is allowed, but the run result warns.
static BOOL cl_custom_clean_folder_is_user_data(NSString *pattern)
{
    return ![pattern hasPrefix:@"Library/Caches"] && ![pattern isEqualToString:@"tmp"] &&
           ![pattern hasPrefix:@"tmp/"];
}

// Applies ONE rule to the scanned apps. dryRun counts + samples without
// deleting. Returns @{freed, failed, skipped, matched, matchedBytes,
// sample, apps, reason (optional)}. A folder rule's dry-run measures the
// folder instead of purging it. Warnings (non-cache targets that were, or
// would be, cleaned) go to warnings. Per-item accounting throughout:
// matched/skipped are counted per file, so a re-run after a successful
// run matches 0 files and frees 0 with no errors (idempotent), and a
// cancelled run leaves the remaining files for the next run (interrupt
// safe — deletes are per-file unlinkat, there is no half-deleted state).
static NSDictionary *cl_custom_clean_apply_rule(NSArray<CLCacheItem *> *apps, NSDictionary *rule, BOOL dryRun,
                                                CLScanCancellation *cancellation,
                                                NSArray<NSString *> *excludedApps,
                                                NSArray<NSString *> *excludedFolders,
                                                CLCustomCleanProgress progress,
                                                NSMutableArray<NSString *> *warnings)
{
    NSString *kind = rule[CLCustomRuleKindKey];
    NSString *pattern = rule[CLCustomRulePatternKey] ?: @"";
    NSString *bid = rule[CLCustomRuleBundleIDKey] ?: @"*";
    unsigned long long freed = 0, matchedBytes = 0;
    NSUInteger failed = 0, skipped = 0, matched = 0, appsHit = 0;
    NSMutableArray<NSString *> *sample = [NSMutableArray new];
    NSString *reason = nil;
    if (progress) progress([NSString stringWithFormat:@"正在%@ %@…", dryRun ? @"预览" : @"清理",
                            cl_custom_clean_rule_summary(rule)]);
    for (CLCacheItem *app in apps) {
        if (cancellation.isCancelled) break;
        if (app.crashLogs || !app.containerPath.length) continue;
        if (![bid isEqualToString:@"*"] && ![app.bundleID isEqualToString:bid]) continue;
        if ([excludedApps containsObject:app.bundleID]) continue;
        NSString *container = app.containerPath;
        NSUInteger matchedBefore = matched;
        if ([kind isEqualToString:@"folder"] ||
            ([kind isEqualToString:@"directory"] &&
             ![rule[CLCustomRuleScopeKey] isEqualToString:CLCustomRuleScopeFiltered])) {
            // Folder rules, and directory rules with scope "all" (absent
            // scope also means all): purge the whole directory's contents.
            if (!cl_custom_clean_validate_folder_pattern(pattern, &reason)) { failed++; continue; }
            if ([excludedFolders containsObject:pattern]) continue;
            if (cl_custom_clean_folder_is_user_data(pattern)) {
                NSString *w = [NSString stringWithFormat:@"%@（%@）不是缓存目录，已按规则清理",
                               pattern, app.name];
                if (![warnings containsObject:w]) [warnings addObject:w];
            }
            NSString *target = [container stringByAppendingPathComponent:pattern];
            if (dryRun) {
                unsigned long long bytes = 0;
                CLMeasureResult state = cl_measure_tree(target, cancellation, &bytes);
                if (state == CLMeasureResultKnown) {
                    matched++;
                    matchedBytes += bytes;
                    if (sample.count < 50) {
                        [sample addObject:[NSString stringWithFormat:@"%@ · %@", app.name, pattern]];
                    }
                } else if (state == CLMeasureResultLimited) {
                    failed++;
                    reason = @"部分文件夹无法测量";
                }
                // Missing = the folder does not exist: nothing to clean.
            } else {
                unsigned long long removed = 0;
                NSString *r = nil;
                if (!cl_purge_folder_contents(target, container, &removed, &r)) {
                    failed++;
                    if (r.length) reason = r;
                } else {
                    freed += removed;
                    matched++;
                    matchedBytes += removed;
                }
            }
        } else if ([kind isEqualToString:@"directory"]) {
            // v2.5: directory rule, scope "filtered" — delete only files
            // matching the conditions inside that one directory. The walk
            // is the same fd-based no-follow walk as extension rules, but
            // rooted at the picked directory (rootsMayBeAnywhere: the rule
            // was validated, and the directory may be anywhere inside the
            // container, e.g. Documents/Downloads).
            if (!cl_custom_clean_validate_folder_pattern(pattern, &reason)) { failed++; continue; }
            if ([excludedFolders containsObject:pattern]) continue;
            if (cl_custom_clean_folder_is_user_data(pattern)) {
                NSString *w = [NSString stringWithFormat:@"%@（%@）不是缓存目录，已按规则清理",
                               pattern, app.name];
                if (![warnings containsObject:w]) [warnings addObject:w];
            }
            NSArray<NSString *> *exts = cl_custom_clean_parse_extensions(rule[CLCustomRuleExtensionsKey]);
            NSString *name = rule[CLCustomRuleNameKey];
            NSNumber *ageDays = rule[CLCustomRuleMinAgeDaysKey];
            NSNumber *minSize = rule[CLCustomRuleMinSizeKey];
            NSNumber *maxSize = rule[CLCustomRuleMaxSizeKey];
            CLCleanMatchOptions opts = {
                .minAgeSeconds = ageDays ? ageDays.doubleValue * 86400.0 : 0,
                .minSize = minSize ? minSize.unsignedLongLongValue : 0,
                .maxSize = maxSize ? maxSize.unsignedLongLongValue : 0,
                .roots = @[pattern],
                .rootsMayBeAnywhere = YES,
                .dryRun = dryRun,
                .cancellation = cancellation,
            };
            CLCleanMatchResult r;
            NSString *walkReason = nil;
            cl_clean_matching_files_filtered(container, exts.count ? exts : nil,
                                             name.length ? @[name] : nil,
                                             excludedFolders, &opts, &r, &walkReason);
            freed += r.freed;
            failed += r.failed;
            skipped += r.skipped;
            matched += r.matched;
            matchedBytes += r.matchedBytes;
            for (NSString *s in r.samplePaths) {
                if (sample.count < 50) {
                    [sample addObject:[NSString stringWithFormat:@"%@ · %@", app.name, s]];
                }
            }
            if (walkReason.length) reason = walkReason;
        } else if ([kind isEqualToString:@"extension"] || [kind isEqualToString:@"name"]) {
            NSString *ext = [kind isEqualToString:@"extension"] ? pattern : nil;
            if (ext.length && ![ext hasPrefix:@"."]) ext = [@"." stringByAppendingString:ext];
            NSString *name = [kind isEqualToString:@"name"] ? pattern : nil;
            NSNumber *ageDays = rule[CLCustomRuleMinAgeDaysKey];
            NSNumber *minSize = rule[CLCustomRuleMinSizeKey];
            NSNumber *maxSize = rule[CLCustomRuleMaxSizeKey];
            CLCleanMatchOptions opts = {
                .minAgeSeconds = ageDays ? ageDays.doubleValue * 86400.0 : 0,
                .minSize = minSize ? minSize.unsignedLongLongValue : 0,
                .maxSize = maxSize ? maxSize.unsignedLongLongValue : 0,
                .roots = cl_custom_clean_roots_for_subfolder(rule[CLCustomRuleSubfolderKey]),
                .dryRun = dryRun,
                .cancellation = cancellation,
            };
            CLCleanMatchResult r;
            NSString *walkReason = nil;
            cl_clean_matching_files_filtered(container, ext ? @[ext] : nil, name ? @[name] : nil,
                                             excludedFolders, &opts, &r, &walkReason);
            freed += r.freed;
            failed += r.failed;
            skipped += r.skipped;
            matched += r.matched;
            matchedBytes += r.matchedBytes;
            for (NSString *s in r.samplePaths) {
                if (sample.count < 50) {
                    [sample addObject:[NSString stringWithFormat:@"%@ · %@", app.name, s]];
                }
            }
            if (walkReason.length) reason = walkReason;
        }
        if (matched > matchedBefore) appsHit++;
    }
    NSMutableDictionary *entry = [@{ @"freed": @(freed), @"failed": @(failed), @"skipped": @(skipped),
                                    @"matched": @(matched), @"matchedBytes": @(matchedBytes),
                                    @"sample": [sample copy], @"apps": @(appsHit) } mutableCopy];
    if (reason.length) entry[@"reason"] = reason;
    return [entry copy];
}

void cl_custom_clean_run_with_cancellation(NSArray<CLCacheItem *> *apps, CLScanCancellation *cancellation,
                                           CLCustomCleanProgress progress,
                                           void (^completion)(NSDictionary *result))
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NSDictionary *> *rules = cl_custom_clean_rules();
        NSArray<NSString *> *excludedApps = cl_custom_clean_excluded_apps();
        NSArray<NSString *> *excludedFolders = cl_custom_clean_excluded_folders();
        NSMutableArray *perRule = [NSMutableArray new];
        NSMutableArray *warnings = [NSMutableArray new];
        unsigned long long totalFreed = 0, totalMatchedBytes = 0;
        NSUInteger totalFailed = 0, totalSkipped = 0, totalMatched = 0;
        for (NSDictionary *rule in rules) {
            if (cancellation.isCancelled) break;
            if (![rule[CLCustomRuleEnabledKey] boolValue]) continue;
            NSString *reason = nil;
            if (!cl_custom_clean_validate_rule(rule, &reason)) {
                // An invalid rule is skipped and reported, never executed.
                totalFailed++;
                [perRule addObject:@{ @"rule": rule, @"freed": @0, @"failed": @1, @"skipped": @0,
                                      @"matched": @0, @"matchedBytes": @0, @"sample": @[], @"apps": @0,
                                      @"reason": reason ?: @"规则无效" }];
                continue;
            }
            NSDictionary *entry = cl_custom_clean_apply_rule(apps, rule, NO, cancellation,
                                                             excludedApps, excludedFolders, progress, warnings);
            totalFreed += [entry[@"freed"] unsignedLongLongValue];
            totalFailed += [entry[@"failed"] unsignedIntegerValue];
            totalSkipped += [entry[@"skipped"] unsignedIntegerValue];
            totalMatched += [entry[@"matched"] unsignedIntegerValue];
            totalMatchedBytes += [entry[@"matchedBytes"] unsignedLongLongValue];
            NSMutableDictionary *e = [entry mutableCopy];
            e[@"rule"] = rule;
            [perRule addObject:e];
        }
        if (completion) {
            completion(@{ @"freed": @(totalFreed), @"failed": @(totalFailed),
                          @"skipped": @(totalSkipped), @"matched": @(totalMatched),
                          @"matchedBytes": @(totalMatchedBytes),
                          @"cancelled": @(cancellation.isCancelled),
                          @"perRule": [perRule copy], @"warnings": [warnings copy] });
        }
    });
}

void cl_custom_clean_run(NSArray<CLCacheItem *> *apps, CLCustomCleanProgress progress,
                         void (^completion)(NSDictionary *result))
{
    cl_custom_clean_run_with_cancellation(apps, nil, progress, completion);
}

// Dry-run preview for ONE rule: what it would delete, without deleting
// anything. Result: @{matched, bytes, sample, skipped, apps, failed,
// reason (optional)}.
void cl_custom_clean_dry_run(NSArray<CLCacheItem *> *apps, NSDictionary *rule,
                             CLCustomCleanProgress progress,
                             void (^completion)(NSDictionary *result))
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *reason = nil;
        if (!cl_custom_clean_validate_rule(rule, &reason)) {
            if (completion) completion(@{ @"matched": @0, @"bytes": @0, @"sample": @[], @"skipped": @0,
                                          @"apps": @0, @"failed": @1, @"reason": reason ?: @"规则无效" });
            return;
        }
        NSMutableArray *warnings = [NSMutableArray new];
        NSDictionary *entry = cl_custom_clean_apply_rule(apps, rule, YES, nil,
                                                         cl_custom_clean_excluded_apps(),
                                                         cl_custom_clean_excluded_folders(), progress, warnings);
        if (completion) {
            completion(@{ @"matched": entry[@"matched"], @"bytes": entry[@"matchedBytes"],
                          @"sample": entry[@"sample"], @"skipped": entry[@"skipped"],
                          @"apps": entry[@"apps"], @"failed": entry[@"failed"],
                          @"warnings": [warnings copy] });
        }
    });
}

// Run ONE rule (the dry-run preview's confirm button). Result: the same
// per-rule entry as the full run, plus warnings.
void cl_custom_clean_run_one_rule(NSArray<CLCacheItem *> *apps, NSDictionary *rule,
                                  CLCustomCleanProgress progress,
                                  void (^completion)(NSDictionary *result))
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *reason = nil;
        if (!cl_custom_clean_validate_rule(rule, &reason)) {
            if (completion) completion(@{ @"freed": @0, @"failed": @1, @"skipped": @0, @"matched": @0,
                                          @"matchedBytes": @0, @"sample": @[], @"apps": @0,
                                          @"reason": reason ?: @"规则无效", @"warnings": @[] });
            return;
        }
        NSMutableArray *warnings = [NSMutableArray new];
        NSDictionary *entry = cl_custom_clean_apply_rule(apps, rule, NO, nil,
                                                         cl_custom_clean_excluded_apps(),
                                                         cl_custom_clean_excluded_folders(), progress, warnings);
        NSMutableDictionary *result = [entry mutableCopy];
        result[@"warnings"] = [warnings copy];
        if (completion) completion([result copy]);
    });
}
