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

#pragma mark - 总开关/混音（v5.5：多候选路径读改写 + 每路径自证日志）

// v5.4 复测（diag(16) 10:42）：master/mix write ok=1 但 HUD 不反应。RE 已实锤
// HUD 观察通知并每次重读文件（FUN_00008c28 清缓存→FUN_00008b34 重载），所以
// 只剩"我们写的文件 ≠ HUD 读的文件"一种解释：旧面板/HUD 内嵌 libroot 运行时
// 重映射（_libroot_dyn_jbrootpath），我们面板不带 libroot——单路径写可能落在
// 另一个世界。v5.5 镜像引擎已实机的三候选模式（Tweak.xm VMMixConfigCandidates
// 同款：裸路径 / /var/jb 前缀 / /.jbroot 前缀），写全部候选 + 逐路径落日志 +
// 回读验证，无论 interposition 是否生效都能命中 HUD 的文件。

static NSString *VMPSunPrefsBase(void) {
    return @"/var/mobile/Library/Preferences/com.sunshinesong.volume-manager-prefs.plist";
}

static NSArray<NSString *> *VMPSunPrefsCandidates(void) {
    NSString *base = VMPSunPrefsBase();
    return @[ base,
              [@"/var/jb" stringByAppendingString:base],
              [@"/.jbroot" stringByAppendingString:base] ];
}

// 返回（候选路径, 逐路径 ok 数组）：全部尝试，失败路径照常记录
static BOOL VMPWriteSunPrefsAll(NSDictionary *dict, NSArray<NSString *> **usedPaths, NSMutableArray<NSNumber *> **oks) {
    BOOL any = NO;
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSMutableArray<NSNumber *> *results = [NSMutableArray array];
    for (NSString *p in VMPSunPrefsCandidates()) {
        @try {
            NSString *dir = [p stringByDeletingLastPathComponent];
            [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                      withIntermediateDirectories:YES attributes:nil error:NULL];
            BOOL ok = VMPWritePlist(dict, p);
            [paths addObject:p];
            [results addObject:@(ok ? 1 : 0)];
            if (ok) any = YES;
            VMPDiagLog(@"sunprefs write ok=%d path=%@", ok ? 1 : 0, p);
        } @catch (NSException *e) {
            [paths addObject:p];
            [results addObject:@0];
            VMPDiagLog(@"sunprefs write 异常 path=%@ err=%@", p, e.name);
        }
    }
    if (usedPaths) *usedPaths = paths;
    if (oks) *oks = results;
    return any;
}

// 读：第一个可读且含键的候选（同 VMPWhitelistRead 模式）
static id VMPSunPrefsValue(NSString *key) {
    for (NSString *p in VMPSunPrefsCandidates()) {
        @try {
            NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
            if (![d isKindOfClass:[NSDictionary class]]) continue;
            id v = d[key];
            if (v) return v;
        } @catch (NSException *e) { }
    }
    return nil;
}

static NSMutableDictionary *VMPSunPrefsLoadMutable(void) {
    for (NSString *p in VMPSunPrefsCandidates()) {
        @try {
            NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:p];
            if ([d isKindOfClass:[NSMutableDictionary class]]) return d;
        } @catch (NSException *e) { }
    }
    return [NSMutableDictionary dictionary];
}

BOOL VMPMasterEnabledRead(void) {
    @try {
        id v = VMPSunPrefsValue(@"isEnabledManagementAppVolume");
        if (!v) return YES;   // 键缺失 = 默认启用（与引擎 VMPrefsEnabled 同口径）
        return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : YES;
    } @catch (NSException *e) { return YES; }
}

BOOL VMPMasterEnabledWrite(BOOL enabled) {
    @try {
        NSMutableDictionary *d = VMPSunPrefsLoadMutable();
        d[@"isEnabledManagementAppVolume"] = @(enabled);
        BOOL ok = VMPWriteSunPrefsAll(d, NULL, NULL);
        // 回读自证：确认任一候选落盘后能读回新值
        id back = VMPSunPrefsValue(@"isEnabledManagementAppVolume");
        BOOL readback = [back respondsToSelector:@selector(boolValue)] ? [back boolValue] : !enabled;
        VMPDiagLog(@"master write=%d any-ok=%d readback=%d",
                   enabled ? 1 : 0, ok ? 1 : 0, readback ? 1 : 0);
        return ok;
    } @catch (NSException *e) {
        VMPDiagLog(@"master write 异常: %@", e);
        return NO;
    }
}

BOOL VMPMixEnabledRead(void) {
    @try {
        id v = VMPSunPrefsValue(@"vmMixEnabled");
        if (!v) return YES;
        return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : YES;
    } @catch (NSException *e) { return YES; }
}

BOOL VMPMixEnabledWrite(BOOL enabled) {
    @try {
        NSMutableDictionary *d = VMPSunPrefsLoadMutable();
        d[@"vmMixEnabled"] = @(enabled);
        d[@"isEnabledMixable"] = @(enabled);
        BOOL ok = VMPWriteSunPrefsAll(d, NULL, NULL);
        id back = VMPSunPrefsValue(@"vmMixEnabled");
        BOOL readback = [back respondsToSelector:@selector(boolValue)] ? [back boolValue] : !enabled;
        VMPDiagLog(@"mix write=%d any-ok=%d readback=%d",
                   enabled ? 1 : 0, ok ? 1 : 0, readback ? 1 : 0);
        return ok;
    } @catch (NSException *e) {
        VMPDiagLog(@"mix write 异常: %@", e);
        return NO;
    }
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
        // 逐条防御（v5.2）：255 个元素里混有非 LSApplicationProxy 的占位对象，
        // 直接调属性会 unrecognized selector（v5.1 实机：异常被 @try 吞掉→0 项）
        // v5.4：bundleURL 先探后调（v5.3 实机 255/255 全抛 NSInvalidArgumentException
        // 的疑点，见台账 06 待解#1）；@catch 落 reason 指认抛点 selector。
        for (id proxy in apps) {
            @try {
                if (![proxy respondsToSelector:@selector(bundleIdentifier)]) {
                    skipped++;
                    VMPDiagLog(@"scan: 跳过 无bundleIdentifier选择器 cls=%@",
                               NSStringFromClass([proxy class]));
                    continue;
                }
                NSString *bid = [proxy bundleIdentifier];
                if (!bid.length) {
                    skipped++;
                    VMPDiagLog(@"scan: 跳过 空bid cls=%@", NSStringFromClass([proxy class]));
                    continue;
                }
                VMPAppEntry *e = [VMPAppEntry new];
                e.bid = bid;
                e.name = [proxy respondsToSelector:@selector(localizedName)]
                         ? ([proxy localizedName] ?: bid) : bid;
                e.icon = VMPIconForBid(bid);
                NSURL *burl = [proxy respondsToSelector:@selector(bundleURL)]
                              ? [proxy bundleURL] : nil;
                NSString *path = [burl path] ?: @"";
                e.isSystem = [path hasPrefix:@"/System/"];
                // v5.5：iOS 17.2 的 infoDictionary 返回 _LSDataBackedPropertyList，
                // 不实现 objectForKeyedSubscript:（v5.4 diag(16) 255/255 异常 reason
                // 实锤：`-[_LSDataBackedPropertyList objectForKeyedSubscript:]`
                // unrecognized selector）——下标语法换成守卫式 objectForKey:，
                // 不支持就放弃该标志（列表照常渲染，只影响音频类标记）
                id modes = nil;
                if ([proxy respondsToSelector:@selector(infoDictionary)]) {
                    id info = [proxy infoDictionary];
                    if ([info respondsToSelector:@selector(objectForKey:)]) {
                        modes = [info objectForKey:@"UIBackgroundModes"];
                    }
                }
                e.hasAudioMode = [modes isKindOfClass:[NSArray class]]
                                 && [(NSArray *)modes containsObject:@"audio"];
                [out addObject:e];
            } @catch (NSException *pe) {
                skipped++;
                VMPDiagLog(@"scan: 单条跳过 name=%@ reason=%@",
                           pe.name ?: @"(nil)",
                           pe.reason ?: [pe.callStackSymbols firstObject] ?: @"(nil)");
            }
        }
        // volumeInfo 已配置标记 + 默认排序（先非系统按名排序，系统应用垫底）
        NSDictionary *vol = VMPVolumeInfoReadMutable();
        for (VMPAppEntry *e in out) e.configured = (vol[e.bid] != nil);
        VMPDiagLog(@"scan: 有效 %lu 项（无 bid/异常跳过 %d）", (unsigned long)out.count, skipped);
        VMPDiagLog(@"scan: 有效 %lu 项（无 bid 跳过 %d）", (unsigned long)out.count, skipped);
        [out sortUsingComparator:^NSComparisonResult(VMPAppEntry *a, VMPAppEntry *b) {
            if (a.isSystem != b.isSystem) return a.isSystem ? NSOrderedDescending : NSOrderedAscending;
            return [a.name caseInsensitiveCompare:b.name];
        }];
    } @catch (NSException *e) {
        VMPDiagLog(@"scan: 整体异常 %@", e);
    }
    return out;
}
