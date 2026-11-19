/*
 * VolManHUDPatch v0.5 —— 音量面板（HUD）透明化 + 列表白名单过滤运行时补丁
 * ============================================================================
 * v0.5 新增（2026-11-19）：HUD 列表白名单过滤（v2.0 步骤②追加需求，实机反馈：
 *   未勾选/系统应用也出现在 HUD 滑杆列表）。RE 定案（Ghidra hud_decomp.c）：
 *   列表重建 FUN_0000dd94 = [UIApplication.sharedApplication runningAppProcesses]
 *   （经 FUN_00008170）→ 按 taskState==2 && isApplicationProcess 过滤 → 直接
 *   生成滑杆行，无任何名单语义。修法 = 挂钩 runningAppProcesses，按
 *   appwhitelist.plist 过滤返回数组：
 *   · 三态与引擎 VMWhitelistDecide 对齐：文件缺失/无 enabled = 兼容模式 =
 *     不过滤（老用户升级零行为变化）；fail-closed 不适用（列表过滤走 fail-open，
 *     读不到名单绝不隐藏行）。
 *   · 名单每次调用现读（音量键节频，无缓存）→ 面板改名单即时生效，无需重启。
 *   · 单条 bid 取不到 → 保留该行（宁多勿崩）。
 *   · 旁路开关 vmaq-hud-allowall = 关闭过滤。
 *   · 预期副作用（即产品语义）：未勾选应用内按音量键，HUD 找不到该进程 →
 *     回落系统音量条。
 *
 * v0.4  时序修正（2026-11-18）：v0.3 实机实锤 dyld add_image 回调时 ObjC 类
 *       尚未注册（已知类清单 0/10 全部"类未注册"）——dyld 回调机制整体弃用，
 *       挂载与方法表 dump 挂靠扫描周期（类就绪后第一个 0.3s tick 自动完成，
 *       dump 不再依赖呼出 HUD；补丁关也不影响 dump）。透明化已实机达成。
 * 为什么是独立模块而不是引擎分支：引擎是 arm64 单切片，SpringBoard/设置等
 * arm64e 系统进程会静默拒载（硬规则 3）。本模块必须以 FAT 双切片
 * （arm64+arm64e）进入 SpringBoard，且必须由 Apple 工具链构建（硬规则 8）。
 * 构建入口 = .github/workflows/hudpatch.yml；产物人工下载到
 * tools/hudpatch-prebuilt/ 由 build-rootless.sh 打入 full 包。
 *
 * 日志：NSLog + 中央数据目录 vmaq-hudpatch.log + /tmp 镜像双写。
 * ============================================================================
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>
#import <stdio.h>
#import <time.h>

// ===========================================================================
// 路径与开关
//   字面量前缀与引擎同款（rootless 形态）；roothide 转换器会改写二进制里的
//   路径字符串（AGENTS 硬规则 4），与引擎约定保持一致。
// ===========================================================================
static NSArray<NSString *> *VHPDirs(void) {
    return @[ @"/var/jb/var/mobile/Library/VolumeManager-sunshinesong",
              @"/var/mobile/Library/VolumeManager-sunshinesong",
              @"/.jbroot/var/mobile/Library/VolumeManager-sunshinesong" ];
}

static BOOL VHPFilePresent(NSString *name) {
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *d in VHPDirs()) {
            if ([fm fileExistsAtPath:[d stringByAppendingPathComponent:name]]) return YES;
        }
        return NO;
    } @catch (NSException *e) {
        return NO;
    }
}

// ===========================================================================
// 日志（NSLog + 中央文件 + /tmp 镜像；量极小，不做轮转）
// ===========================================================================
static void VHPAppendFile(NSString *path, NSString *line) {
    FILE *fp = fopen(path.fileSystemRepresentation, "a");
    if (!fp) return;
    fputs(line.UTF8String ?: "", fp);
    fclose(fp);
}

static void VHPLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[VolManHUDPatch] %@", msg);

    // 本地 24 小时制时间戳（strftime/localtime_r，与引擎日志同款；
    // v0.2 用 descriptionWithLocale 打出的是 UTC，用户要求随系统 24h）
    char ts[32] = "?";
    time_t tt = time(NULL);
    struct tm tmv;
    if (localtime_r(&tt, &tmv)) {
        strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", &tmv);
    }
    NSString *line = [NSString stringWithFormat:@"[%s] %@\n", ts, msg];

    for (NSString *d in VHPDirs()) {
        VHPAppendFile([d stringByAppendingPathComponent:@"vmaq-hudpatch.log"], line);
    }
    VHPAppendFile(@"/tmp/vmaq-hudpatch.log", line);
}

// ===========================================================================
// 全局状态
// ===========================================================================
static int gVHPDump        = 0;   // 探针开关（vmaq-hud-debug）
static int gVHPPatch       = 1;   // 透明化开关（默认开；vmaq-hud-opaque 关闭）
static int gVHPFilter      = 1;   // 列表白名单过滤（v0.5 默认开；vmaq-hud-allowall 关闭）
static IMP gOrigVCAppear   = NULL;
static IMP gOrigVCAppearW  = NULL;
static IMP gOrigVCLoad     = NULL;
static IMP gOrigViewMove   = NULL;
static IMP gOrigViewLayout = NULL;
static IMP gOrigRunningProcs = NULL;
static int gAttached       = 0;
static int gFilterAttached = 0;
static int gFilterLogCount = 0;
static int gDumpDone       = 0;
static dispatch_source_t gVHPSweep = nil;
static int gVHPSweepHits   = 0;

// 前向声明（v0.5 过滤块在守卫定义之前引用它）
static IMP VHPSwizzle(Class cls, SEL sel, IMP imp);

// ===========================================================================
// v0.5 列表白名单过滤
//   数据源 = -[UIApplication runningAppProcesses]（HUD 列表重建 FUN_0000dd94
//   的唯一来源，经 VMProcess 助手 FUN_00008170 调用）。
//   名单 = 数据目录 appwhitelist.plist 的 enabled 数组；文件缺失/不可解析 =
//   兼容模式 = 不过滤（与引擎 VMWhitelistDecide 的 legacy 语义一致，老用户
//   零行为变化）。名单每次调用现读——面板改名单即时生效。
// ===========================================================================
static NSArray<NSString *> *VHPWhitelistBids(NSString **outWhy) {
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *d in VHPDirs()) {
            NSString *p = [d stringByAppendingPathComponent:@"appwhitelist.plist"];
            NSDictionary *r = [NSDictionary dictionaryWithContentsOfFile:p];
            if (![r isKindOfClass:[NSDictionary class]]) continue;
            NSArray *en = r[@"enabled"];
            if (![en isKindOfClass:[NSArray class]]) continue;
            if (outWhy) *outWhy = [NSString stringWithFormat:@"%@（%lu 项）", p, (unsigned long)en.count];
            return en;
        }
        if (outWhy) *outWhy = @"未初始化（无 appwhitelist.plist）→ 兼容模式不过滤";
        return nil;
    } @catch (NSException *e) {
        if (outWhy) *outWhy = [NSString stringWithFormat:@"读取异常 %@ → 不过滤", e.name];
        return nil;
    }
}

static NSArray *VHPRunningProcsHook(id self, SEL _cmd) {
    NSArray *orig = gOrigRunningProcs
        ? ((NSArray *(*)(id, SEL))gOrigRunningProcs)(self, _cmd) : nil;
    @try {
        if (!gVHPFilter || !orig) return orig;
        NSString *why = nil;
        NSArray<NSString *> *bids = VHPWhitelistBids(&why);
        if (!bids) {
            // 兼容模式 / 读不到名单：绝不隐藏行（fail-open），只记一次原因
            if (gFilterLogCount < 3) {
                gFilterLogCount++;
                VHPLog(@"runningAppProcesses 不过滤：%@", why);
            }
            return orig;
        }
        NSMutableArray *keep = [NSMutableArray array];
        int dropped = 0;
        for (id proc in orig) {
            @try {
                NSString *bid = nil;
                if ([proc respondsToSelector:@selector(bundleIdentifier)]) {
                    bid = [proc bundleIdentifier];
                }
                if (!bid.length || [bids containsObject:bid]) {
                    [keep addObject:proc];   // bid 取不到 → 保留（宁多勿崩）
                } else {
                    dropped++;
                }
            } @catch (NSException *e) {
                [keep addObject:proc];
            }
        }
        gFilterLogCount++;
        if (gFilterLogCount <= 3) {
            VHPLog(@"runningAppProcesses 过滤：%lu → %lu（剔除 %d）名单=%@",
                   (unsigned long)orig.count, (unsigned long)keep.count, dropped, why);
        }
        return keep;
    } @catch (NSException *e) {
        VHPLog(@"runningAppProcesses 过滤异常: %@", e);
        return orig;
    }
}

// UIApplication 是 Apple 常驻类，ctor 后必已注册——独立于 HUD 类的挂载时机，
// 挂靠同一扫描周期（主队列 tick），挂一次即止。
static void VHPAttachFilter(void) {
    if (gFilterAttached) return;
    Class ui = objc_getClass("UIApplication");
    if (!ui) return;   // 理论不可达（SpringBoard 有 UIKit），等下个 tick
    IMP o = VHPSwizzle(ui, @selector(runningAppProcesses), (IMP)&VHPRunningProcsHook);
    if (o) {
        gOrigRunningProcs = o;
        gFilterAttached = 1;
        VHPLog(@"已挂 UIApplication runningAppProcesses（列表过滤=%d）", gVHPFilter);
    } else {
        // 防误伤守卫拒绝（方法非 UIApplication 自有实现）——记日志并放弃，
        // 透明化扫描式不受影响。
        gFilterAttached = 1;
        VHPLog(@"runningAppProcesses 挂钩被守卫拒绝（非自有实现）→ 过滤不生效");
    }
}

// ===========================================================================
// 手动挂钩（防误伤守卫：方法必须由类自身实现，继承来的拒绝——
// 否则 class_getInstanceMethod 返回父类方法，换 IMP 会波及 SpringBoard 全部视图）
// ===========================================================================
static IMP VHPSwizzle(Class cls, SEL sel, IMP imp) {
    if (!cls || !sel || !imp) return NULL;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NULL;
    Method pm = class_getInstanceMethod(class_getSuperclass(cls), sel);
    if (pm && method_getImplementation(pm) == method_getImplementation(m)) return NULL;
    return method_setImplementation(m, imp);
}

// ===========================================================================
// 透明化：遍历子树
//   规则① UIVisualEffectView → effect=nil（磨砂摘除）
//   规则② HUD 自有类（类名含 VolumeManagerSBHUD）→ 背景清透明
//   规则③ UIWindow → 背景清透明
//   其余（Apple 类：音量条填充、文字等）不动。
//   幂等：每次 HUD 呼出都执行，代价为一次浅树遍历。
// ===========================================================================
static void VHPWalkClear(UIView *v) {
    if (!v) return;
    @try {
        if ([v isKindOfClass:[UIVisualEffectView class]]) {
            ((UIVisualEffectView *)v).effect = nil;
        }
        NSString *cn = NSStringFromClass([v class]) ?: @"";
        BOOL isVM = [cn rangeOfString:@"VolumeManagerSBHUD"].location != NSNotFound;
        if (isVM || [v isKindOfClass:[UIWindow class]]) {
            v.backgroundColor = [UIColor clearColor];
        }
        for (UIView *s in [v subviews]) VHPWalkClear(s);
    } @catch (NSException *e) { }
}

static void VHPPatchHUD(id selfVC) {
    @try {
        SEL vsel = @selector(view);
        if (![selfVC respondsToSelector:vsel]) return;
        UIView *root = ((UIView *(*)(id, SEL))objc_msgSend)(selfVC, vsel);
        if (!root) return;
        VHPWalkClear(root);
        UIView *win = root.window;
        if (win && win != root) VHPWalkClear(win);   // 窗口层 + VC 树外兄弟视图
    } @catch (NSException *e) {
        VHPLog(@"透明补丁异常: %@", e);
    }
}

// ===========================================================================
// 探针：一次性 dump（触发 VC 视图树 + VM 前缀窗口树）
// ===========================================================================
static void VHPDumpOnce(id selfVC) {
    if (gDumpDone) return;
    gDumpDone = 1;   // 失败也不再重试，避免每次呼出刷屏
    @try {
        NSMutableString *rep = [NSMutableString
            stringWithFormat:@"=== HUD 视图树 dump（触发 VC=%@）===\n",
            NSStringFromClass([selfVC class]) ?: @"(nil)"];

        SEL vsel = @selector(view);
        if ([selfVC respondsToSelector:vsel]) {
            UIView *root = ((UIView *(*)(id, SEL))objc_msgSend)(selfVC, vsel);
            if (root && [root respondsToSelector:@selector(recursiveDescription)]) {
                [rep appendFormat:@"--- VC.view ---\n%@\n",
                    ((id (*)(id, SEL))objc_msgSend)(root, @selector(recursiveDescription))];
            }
        }

        id app = ((id (*)(id, SEL))objc_msgSend)(objc_getClass("UIApplication"),
                                                 @selector(sharedApplication));
        if ([app respondsToSelector:@selector(windows)]) {
            NSArray *wins = ((NSArray *(*)(id, SEL))objc_msgSend)(app, @selector(windows));
            for (UIView *w in wins) {
                NSString *cn = NSStringFromClass([w class]) ?: @"";
                if ([cn rangeOfString:@"VMHUD"].location == NSNotFound &&
                    [cn rangeOfString:@"VolumeManager"].location == NSNotFound) continue;
                if ([w respondsToSelector:@selector(recursiveDescription)]) {
                    [rep appendFormat:@"--- window(%@) ---\n%@\n", cn,
                        ((id (*)(id, SEL))objc_msgSend)(w, @selector(recursiveDescription))];
                }
            }
        }
        VHPLog(@"%@", rep);
    } @catch (NSException *e) {
        VHPLog(@"dump 异常: %@", e);
    }
}

// ===========================================================================
// 扫描式补丁（v0.2 主力）：0.3s 主队列定时器，发现 VM HUD 窗口即清理。
// 零生命周期假设——v0.1 实机证明闭源 Swift 类不覆写任何系统生命周期方法，
// 精确挂钩必须等方法表 dump 出来再定；扫描式先保证透明化必定生效。
// 只在主队列运行（UIKit 访问安全）；无 VM 窗口时一次空扫 ≈ 一个 windows
// 数组遍历，代价可忽略。命中日志只记前 3 次，避免刷屏。
// ===========================================================================
// 前向声明（扫描事件处理器在类就绪时调用后文的挂载/ dump——文件序靠后）
static void VHPAttach(void);
static void VHPDumpImageMethods(void);

static void VHPStartSweep(void) {
    if (gVHPSweep) return;
    dispatch_queue_t q = dispatch_get_main_queue();
    gVHPSweep = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(gVHPSweep, DISPATCH_TIME_NOW,
                              (uint64_t)(0.3 * NSEC_PER_SEC), 0);
    dispatch_source_set_event_handler(gVHPSweep, ^{
        @try {
            // v0.5：列表过滤挂钩独立挂载（UIApplication 常驻，首个 tick 即完成）
            VHPAttachFilter();

            // v0.4：挂载与方法表 dump 挂靠扫描周期——HUD 类注册完成后的
            // 第一个 tick 自动完成（dyld add_image 回调时 ObjC 类尚未注册，
            // v0.3 实机 0/10 实锤）。补丁关（vmaq-hud-opaque）也不影响 dump。
            if (!gAttached) {
                Class vc   = objc_getClass("_TtC18VolumeManagerSBHUD16VMViewController");
                Class view = objc_getClass("_TtC18VolumeManagerSBHUD9VMHUDView");
                if (vc || view) {
                    VHPAttach();
                    if (gVHPDump && !gDumpDone) VHPDumpImageMethods();
                }
            }

            if (!gVHPPatch) return;
            id app = ((id (*)(id, SEL))objc_msgSend)(objc_getClass("UIApplication"),
                                                     @selector(sharedApplication));
            if (![app respondsToSelector:@selector(windows)]) return;
            NSArray *wins = ((NSArray *(*)(id, SEL))objc_msgSend)(app, @selector(windows));
            BOOL found = NO;
            for (UIView *w in wins) {
                NSString *cn = NSStringFromClass([w class]) ?: @"";
                if ([cn rangeOfString:@"VolumeManagerSBHUD"].location == NSNotFound &&
                    [cn rangeOfString:@"VMHUD"].location == NSNotFound) continue;
                found = YES;
                VHPWalkClear(w);
            }
            if (found) {
                gVHPSweepHits++;
                if (gVHPSweepHits <= 3) {
                    VHPLog(@"扫描补丁：命中 VM 窗口并清理（第 %d 次）", gVHPSweepHits);
                }
            }
        } @catch (NSException *e) { }
    });
    dispatch_resume(gVHPSweep);
}

// ===========================================================================
// 方法表 dump（v0.3）：按已知类名清单直接枚举。
// v0.2 的 objc_copyClassNamesForImage 在实机静默返回空且我写了静默 return
// （违反「静默失败必须留日志」）——改为已知类名（10 个，来自 v0.1 期二进制
// 分析）逐一 objc_getClass + class_copyMethodList（不含继承），每步有日志。
// class_copyMethodList 不含继承——这就是真实可挂表面。
// ===========================================================================
static const char *VHPKnownClasses[] = {
    "_TtC18VolumeManagerSBHUD11VMHUDWindow",
    "_TtC18VolumeManagerSBHUD16VMViewController",
    "_TtC18VolumeManagerSBHUD9VMHUDView",
    "_TtC18VolumeManagerSBHUD20VMHUDScrollContainer",
    "_TtC18VolumeManagerSBHUD15SpringBoardHook",
    "_TtC18VolumeManagerSBHUD19SBVolumeControlHook",
    "_TtC18VolumeManagerSBHUD7VMPrefs",
    "_TtC18VolumeManagerSBHUD9VMProcess",
    "_TtC18VolumeManagerSBHUD5VMXpc",
    "_TtC18VolumeManagerSBHUD13VMFileManager",
};

static void VHPDumpImageMethods(void) {
    @try {
        int total = (int)(sizeof(VHPKnownClasses) / sizeof(VHPKnownClasses[0]));
        VHPLog(@"方法表：开始枚举（已知类清单 %d 个）", total);
        NSMutableString *rep = [NSMutableString
            stringWithString:@"=== HUD 镜像类与方法表（自有实例方法，不含继承）===\n"];
        int registered = 0;
        for (int i = 0; i < total; i++) {
            Class c = objc_getClass(VHPKnownClasses[i]);
            [rep appendFormat:@"— %s —\n", VHPKnownClasses[i]];
            if (!c) { [rep appendString:@"   (类未注册)\n"]; continue; }
            registered++;
            unsigned int m = 0;
            Method *ms = class_copyMethodList(c, &m);
            for (unsigned int j = 0; j < m; j++) {
                [rep appendFormat:@"   %@\n",
                    NSStringFromSelector(method_getName(ms[j]))];
            }
            if (ms) free(ms);
            if (m == 0) [rep appendString:@"   (无自有实例方法)\n"];
        }
        [rep appendFormat:@"=== 已注册 %d/%d 类 ===\n", registered, total];
        VHPLog(@"%@", rep);
    } @catch (NSException *e) {
        VHPLog(@"方法表 dump 异常: %@", e);
    }
}

// ===========================================================================
// 钩子实现（orig 先行，后处理）——命中即精确补丁；未命中由扫描式兜底
// ===========================================================================
static void VHPVCAppearHook(id self, SEL _cmd, BOOL animated) {
    if (gOrigVCAppear) ((void (*)(id, SEL, BOOL))gOrigVCAppear)(self, _cmd, animated);
    if (gVHPPatch) VHPPatchHUD(self);
    if (gVHPDump)  VHPDumpOnce(self);
}
static void VHPVCAppearWHook(id self, SEL _cmd, BOOL animated) {
    if (gOrigVCAppearW) ((void (*)(id, SEL, BOOL))gOrigVCAppearW)(self, _cmd, animated);
    if (gVHPPatch) VHPPatchHUD(self);
    if (gVHPDump)  VHPDumpOnce(self);
}
static void VHPVCLoadHook(id self, SEL _cmd) {
    if (gOrigVCLoad) ((void (*)(id, SEL))gOrigVCLoad)(self, _cmd);
    if (gVHPPatch) VHPPatchHUD(self);
    if (gVHPDump)  VHPDumpOnce(self);
}
static void VHPViewMoveHook(id self, SEL _cmd) {
    if (gOrigViewMove) ((void (*)(id, SEL))gOrigViewMove)(self, _cmd);
    if (gVHPPatch) VHPPatchHUD(self);
    if (gVHPDump)  VHPDumpOnce(self);
}
static void VHPViewLayoutHook(id self, SEL _cmd) {
    if (gOrigViewLayout) ((void (*)(id, SEL))gOrigViewLayout)(self, _cmd);
    if (gVHPPatch) VHPPatchHUD(self);
    if (gVHPDump)  VHPDumpOnce(self);
}

// 对已加载的 HUD 类装挂钩（防误伤守卫过滤后按优先级取第一个命中的）。
// 挂点候选：VMViewController.viewDidAppear:/viewWillAppear:/viewDidLoad、
//           VMHUDView.didMoveToWindow/layoutSubviews。
// 调用时机由扫描周期把控：类未注册（objc_getClass 全 nil）时**静默返回**——
// v0.3 实机证明 dyld add_image 回调时 ObjC 类尚未注册，此前的
// 「HUD 类已加载但…」日志在类未就绪时也会打出，属误导，v0.4 修正。
static void VHPAttach(void) {
    if (gAttached) return;
    Class vc   = objc_getClass("_TtC18VolumeManagerSBHUD16VMViewController");
    Class view = objc_getClass("_TtC18VolumeManagerSBHUD9VMHUDView");
    if (!vc && !view) return;   // 类未注册，等下一个扫描周期

    if (vc) {
        IMP o = VHPSwizzle(vc, @selector(viewDidAppear:), (IMP)&VHPVCAppearHook);
        if (o) { gOrigVCAppear = o; gAttached = 1;
                 VHPLog(@"已挂 VMViewController viewDidAppear:"); return; }
        o = VHPSwizzle(vc, @selector(viewWillAppear:), (IMP)&VHPVCAppearWHook);
        if (o) { gOrigVCAppearW = o; gAttached = 1;
                 VHPLog(@"已挂 VMViewController viewWillAppear:"); return; }
        o = VHPSwizzle(vc, @selector(viewDidLoad), (IMP)&VHPVCLoadHook);
        if (o) { gOrigVCLoad = o; gAttached = 1;
                 VHPLog(@"已挂 VMViewController viewDidLoad"); return; }
    }
    if (view) {
        IMP o = VHPSwizzle(view, @selector(didMoveToWindow), (IMP)&VHPViewMoveHook);
        if (o) { gOrigViewMove = o; gAttached = 1;
                 VHPLog(@"已挂 VMHUDView didMoveToWindow"); return; }
        o = VHPSwizzle(view, @selector(layoutSubviews), (IMP)&VHPViewLayoutHook);
        if (o) { gOrigViewLayout = o; gAttached = 1;
                 VHPLog(@"已挂 VMHUDView layoutSubviews"); return; }
    }
    VHPLog(@"HUD 类已注册但无可挂生命周期方法（扫描式补丁接管）");
}

// ===========================================================================
// 入口
//   v0.4：dyld add_image 回调机制整体弃用——回调时 ObjC 类尚未注册
//   （v0.3 实机 0/10），挂载/ dump 全部由扫描周期在类就绪后接管。
// ===========================================================================
%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
        if (![bid isEqualToString:@"com.apple.springboard"]) {
            NSLog(@"[VolManHUDPatch] 跳过 pid=%d bundle=%@（只服务 SpringBoard）",
                  (int)[[NSProcessInfo processInfo] processIdentifier], bid);
            return;
        }

        gVHPDump  = VHPFilePresent(@"vmaq-hud-debug");
        if (VHPFilePresent(@"vmaq-hud-opaque")) gVHPPatch = 0;
        if (VHPFilePresent(@"vmaq-hud-allowall")) gVHPFilter = 0;

        VHPLog(@"注入 pid=%d 透明补丁=%d 列表过滤=%d dump探针=%d（补丁=扫描式0.3s）",
               (int)[[NSProcessInfo processInfo] processIdentifier],
               gVHPPatch, gVHPFilter, gVHPDump);

        // 扫描周期承担四件事：过滤挂钩（首个 tick）→ 挂载（类就绪后）→
        // 方法表 dump（开关开时）→ 窗口清理（补丁开时）。主队列启动。
        if (gVHPPatch || gVHPDump || gVHPFilter) {
            dispatch_async(dispatch_get_main_queue(), ^{ VHPStartSweep(); });
        }
    }
}
