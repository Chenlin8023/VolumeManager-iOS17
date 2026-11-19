/*
 * VMPShared.m —— VolManPrefsPanel 公共层实现
 * 路径字面量与引擎同款（rootless 形态；roothide 转换器改写二进制路径字符串）。
 */
#import "VMPShared.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <time.h>

#pragma mark - 路径

NSArray<NSString *> *VMPDataDirs(void) {
    return @[ @"/var/jb/var/mobile/Library/VolumeManager-sunshinesong",
              @"/var/mobile/Library/VolumeManager-sunshinesong",
              @"/.jbroot/var/mobile/Library/VolumeManager-sunshinesong" ];
}

// 数据目录取第一个候选（Settings 为 mobile 用户，该目录 postinst 已 777 可写）
static NSString *VMPDataPath(NSString *file) {
    NSString *d = VMPDataDirs().firstObject ?: @"";
    return [d stringByAppendingPathComponent:file];
}

NSString *VMPWhitelistDataPath(void)   { return VMPDataPath(@"appwhitelist.plist"); }
NSString *VMPWhitelistSyncedPath(void) {
    return @"/var/mobile/Library/Preferences/com.local.volmanaudioqueue.appwhitelist.plist";
}
NSString *VMPVolumeDataPath(void)    { return VMPDataPath(@"volumeInfo.plist"); }
NSString *VMPVolumeSyncedPath(void)  { return @"/var/mobile/Library/Preferences/com.local.volmanaudioqueue.appvolume.plist"; }
NSString *VMPMixDataPath(void)       { return VMPDataPath(@"mixInfo.plist"); }
NSString *VMPMixSyncedPath(void)     { return @"/var/mobile/Library/Preferences/com.local.volmanaudioqueue.mix.plist"; }
NSString *VMPSunPrefsPath(void)      { return @"/var/mobile/Library/Preferences/com.sunshinesong.volume-manager-prefs.plist"; }

BOOL VMPWritePlist(id plist, NSString *path) {
    if (!plist || !path.length) return NO;
    @try {
        return [(NSDictionary *)plist writeToFile:path atomically:YES];
    } @catch (NSException *e) {
        return NO;
    }
}

#pragma mark - 总开关

BOOL VMPMasterEnabledRead(void) {
    @try {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:VMPSunPrefsPath()];
        id v = d[@"isEnabledManagementAppVolume"];
        return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : YES;
    } @catch (NSException *e) { return YES; }
}

BOOL VMPMasterEnabledWrite(BOOL enabled) {
    @try {
        NSMutableDictionary *d = [[NSDictionary dictionaryWithContentsOfFile:VMPSunPrefsPath()]
                                  mutableCopy] ?: [NSMutableDictionary dictionary];
        d[@"isEnabledManagementAppVolume"] = @(enabled);
        return VMPWritePlist(d, VMPSunPrefsPath());
    } @catch (NSException *e) { return NO; }
}

#pragma mark - 混音

BOOL VMPMixEnabledRead(void) {
    @try {
        for (NSString *p in @[ VMPMixDataPath(), VMPMixSyncedPath() ]) {
            NSDictionary *r = [NSDictionary dictionaryWithContentsOfFile:p];
            if (![r isKindOfClass:[NSDictionary class]]) continue;
            if (r[@"vmMixEnabled"]) return [r[@"vmMixEnabled"] boolValue];
        }
        return YES;   // 无配置 = 默认开（与引擎默认一致）
    } @catch (NSException *e) { return YES; }
}

BOOL VMPMixEnabledWrite(BOOL enabled) {
    @try {
        BOOL ok = YES;
        for (NSString *p in @[ VMPMixDataPath(), VMPMixSyncedPath() ]) {
            NSMutableDictionary *d = [[NSDictionary dictionaryWithContentsOfFile:p] mutableCopy]
                                     ?: [NSMutableDictionary dictionary];
            d[@"vmMixEnabled"] = @(enabled);
            if (![d writeToFile:p atomically:YES]) ok = NO;
        }
        return ok;
    } @catch (NSException *e) { return NO; }
}

#pragma mark - 白名单

NSArray<NSString *> *VMPWhitelistRead(void) {
    @try {
        for (NSString *p in @[ VMPDataPath(@"appwhitelist.plist"), VMPWhitelistSyncedPath() ]) {
            NSDictionary *r = [NSDictionary dictionaryWithContentsOfFile:p];
            if (![r isKindOfClass:[NSDictionary class]]) continue;
            NSArray *en = r[@"enabled"];
            if ([en isKindOfClass:[NSArray class]]) return en;
        }
        return @[];
    } @catch (NSException *e) { return @[]; }
}

BOOL VMPWhitelistWrite(NSArray<NSString *> *enabled) {
    @try {
        // 数据目录那份要先确保目录存在（Settings 是 mobile 用户，目录 postinst 已 777）
        BOOL ok = YES;
        NSDictionary *root = @{ @"version": @1,
                                @"mode": @"whitelist",
                                @"enabled": enabled ?: @[] };
        for (NSString *p in @[ VMPDataPath(@"appwhitelist.plist"), VMPWhitelistSyncedPath() ]) {
            NSString *dir = [p stringByDeletingLastPathComponent];
            [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                      withIntermediateDirectories:YES attributes:nil error:NULL];
            if (!VMPWritePlist(root, p)) ok = NO;
        }
        return ok;
    } @catch (NSException *e) { return NO; }
}

#pragma mark - volumeInfo

NSMutableDictionary *VMPVolumeInfoReadMutable(void) {
    @try {
        for (NSString *p in @[ VMPVolumeDataPath(), VMPVolumeSyncedPath() ]) {
            NSDictionary *r = [NSDictionary dictionaryWithContentsOfFile:p];
            if ([r isKindOfClass:[NSDictionary class]] && r.count > 0)
                return [r mutableCopy];
        }
    } @catch (NSException *e) { }
    return [NSMutableDictionary dictionary];
}

BOOL VMPVolumeInfoFlush(NSDictionary *root) {
    @try {
        BOOL ok = YES;
        for (NSString *p in @[ VMPVolumeDataPath(), VMPVolumeSyncedPath() ]) {
            if (!VMPWritePlist(root, p)) ok = NO;
        }
        return ok;
    } @catch (NSException *e) { return NO; }
}

double VMPVolumeInfoGetVolume(NSDictionary *root, NSString *bid, BOOL *matched) {
    if (matched) *matched = NO;
    if (![root isKindOfClass:[NSDictionary class]] || !bid.length) return 1.0;
    id v = root[bid][@"volume"];
    if (!v) return 1.0;
    if (matched) *matched = YES;
    double d = [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : 1.0;
    if (d < 0.0) d = 0.0;
    if (d > 1.0) d = 1.0;
    return d;
}

#pragma mark - 通知

void VMPPostSettingChanged(void) {
    @try {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFSTR("com.sunshinesong.volume-manager-prefs.settingOnChanged"),
            NULL, NULL, TRUE);
    } @catch (NSException *e) { }
}

void VMPDiagLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[VMP] %@", msg);
    NSString *line = [NSString stringWithFormat:@"[%@] %@",
        [NSDate date], msg];
    // 四通道：jbroot 文件 / /tmp 镜像 / Settings 自有 defaults 域（cfprefsd
    // 通道沙箱必通）/ NSLog。任何一路静默失败都不影响其他路。
    @try {
        FILE *fp = fopen(VMPDataPath(@"vmp-panel-diag.log").fileSystemRepresentation, "a");
        if (fp) {
            fprintf(fp, "%s\n", line.UTF8String ?: "");
            fclose(fp);
        }
    } @catch (NSException *e) { }
    @try {
        FILE *fp = fopen("/tmp/vmp-panel-diag.log", "a");
        if (fp) {
            fprintf(fp, "%s\n", line.UTF8String ?: "");
            fclose(fp);
        }
    } @catch (NSException *e) { }
    @try {
        // defaults 域留尾部 40 行，防止无限膨胀
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        NSMutableArray *lines = [[d stringArrayForKey:@"VMPDiagLog"] mutableCopy]
                                ?: [NSMutableArray array];
        [lines addObject:line];
        while (lines.count > 40) [lines removeObjectAtIndex:0];
        [d setObject:lines forKey:@"VMPDiagLog"];
        [d synchronize];
    } @catch (NSException *e) { }
}

// 类层级诊断：沿链打印 + 两个关键断言（是否 UIViewController / 是否响应崩溃 setter）
void VMPDiagHierarchy(id obj, NSString *tag) {
    @try {
        Class c = [obj class];
        NSMutableString *chain = [NSMutableString string];
        Class cur = c;
        int depth = 0;
        while (cur && depth < 6) {
            [chain appendFormat:@"%@ <- ", NSStringFromClass(cur) ?: @"(nil)"];
            cur = class_getSuperclass(cur);
            depth++;
        }
        [chain appendString:@"..."];
        VMPDiagLog(@"[%@] class=%@ | chain=%@ | isVC=%d respSetExt=%d",
            tag,
            c ? NSStringFromClass(c) : @"(nil)",
            chain,
            (int)[obj isKindOfClass:[UIViewController class]],
            (int)[obj respondsToSelector:@selector(setExtendedLayoutIncludesOpaqueBars:)]);
    } @catch (NSException *e) {
        VMPDiagLog(@"[%@] 层级诊断异常: %@", tag, e);
    }
}

#pragma mark - 扫描

// 私有框架声明（ LSApplicationWorkspace / LSApplicationProxy ）
@interface LSApplicationProxy : NSObject
@property (nonatomic, readonly, copy) NSString *bundleIdentifier;
@property (nonatomic, readonly, copy) NSString *localizedName;
@property (nonatomic, readonly, copy) NSDictionary *infoDictionary;
@property (nonatomic, readonly, strong) NSURL *bundleURL;
@end

// UIImage 私有图标接口（类方法引用只产生 selector 引用，无链接符号问题）
@interface UIImage (VMPPrivateIcon)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bid
                                               format:(NSString *)format
                                                scale:(CGFloat)scale;
@end

static UIImage *VMPIconForBid(NSString *bid) {
    if (!bid.length) return nil;
    // 闭源面板同款私有 API；取不到就用 nil（行内显示占位）
    @try {
        return [UIImage _applicationIconImageForBundleIdentifier:bid
                                                          format:@"29x29"
                                                           scale:2.0];
    } @catch (NSException *e) {
        return nil;
    }
}

@implementation VMPAppEntry
@end

NSArray<VMPAppEntry *> *VMPScanApps(void) {
    NSMutableArray<VMPAppEntry *> *out = [NSMutableArray array];
    @try {
        // 运行时取类（不产生链接符号引用；方法体内部消息全走动态派发）
        Class wsCls = objc_getClass("LSApplicationWorkspace");
        if (!wsCls) { VMPDiagLog(@"scan: LSApplicationWorkspace 类未找到"); return out; }
        id ws = ((id (*)(id, SEL))objc_msgSend)((id)wsCls, @selector(defaultWorkspace));
        // CI 头适配：不依赖 id 接收器的隐式 selector 声明，显式运行时调用
        SEL allSel = @selector(allInstalledApplications);
        if (![ws respondsToSelector:allSel]) { VMPDiagLog(@"scan: ws 不响应 allInstalledApplications"); return out; }
        NSArray *apps = ((NSArray *(*)(id, SEL))objc_msgSend)(ws, allSel);
        VMPDiagLog(@"scan: allInstalledApplications=%lu 项", (unsigned long)apps.count);
        int skipped = 0;
        for (id proxy in apps) {
            NSString *bid = [proxy bundleIdentifier];
            if (!bid.length) { skipped++; continue; }
            VMPAppEntry *e = [VMPAppEntry new];
            e.bid = bid;
            e.name = [proxy localizedName] ?: bid;
            e.icon = VMPIconForBid(bid);
            NSString *path = [[proxy bundleURL] path] ?: @"";
            e.isSystem = [path hasPrefix:@"/System/"];
            id modes = [proxy infoDictionary][@"UIBackgroundModes"];
            e.hasAudioMode = [modes isKindOfClass:[NSArray class]]
                             && [(NSArray *)modes containsObject:@"audio"];
            [out addObject:e];
        }
        // volumeInfo 已配置标记 + 默认排序（先非系统按名排序，系统应用垫底）
        NSDictionary *vol = VMPVolumeInfoReadMutable();
        for (VMPAppEntry *e in out) e.configured = (vol[e.bid] != nil);
        VMPDiagLog(@"scan: 有效 %lu 项（无 bid 跳过 %d）", (unsigned long)out.count, skipped);
        [out sortUsingComparator:^NSComparisonResult(VMPAppEntry *a, VMPAppEntry *b) {
            if (a.isSystem != b.isSystem) return a.isSystem ? NSOrderedDescending : NSOrderedAscending;
            return [a.name caseInsensitiveCompare:b.name];
        }];
    } @catch (NSException *e) { }
    return out;
}
