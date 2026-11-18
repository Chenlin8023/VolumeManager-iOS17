/*
 * VolManHUDPatch v0.1 —— 音量面板（HUD）透明化运行时补丁（v2.0 步骤②，docs/05 §四.2）
 * ============================================================================
 * 为什么是独立模块而不是引擎分支：引擎是 arm64 单切片，SpringBoard/设置等
 * arm64e 系统进程会静默拒载（硬规则 3；2026-11-18 实测定案——中央日志从未
 * 生成过、PrefsClean 运行时层从未在设置跑过，rootless 线 dylib 只进 App 进程）。
 * 本模块必须以 FAT 双切片（arm64+arm64e）进入 SpringBoard，且必须由 Apple
 * 工具链构建（硬规则 8；本地 clang19 的 arm64e 切片过不了 PAC 关）。
 * 构建入口 = .github/workflows/hudpatch.yml；产物人工下载到
 * tools/hudpatch-prebuilt/ 由 build-rootless.sh 打入 full 包。
 *
 * 职责：
 *   ① 探针（开关：数据目录放空文件 vmaq-hud-debug；ctor 读取，改后需 respring）
 *      dump 闭源 HUD（VolumeManagerSBHUD）的视图层次到日志，为透明化定挂点。
 *      一次性（每次 respring 只 dump 首次呼出）。
 *   ② 透明化（默认生效；数据目录放空文件 vmaq-hud-opaque = 恢复原样）：
 *      - 所有 UIVisualEffectView 的 effect 置 nil（磨砂玻璃摘除，保留布局占位）
 *      - HUD 自有类（类名含 VolumeManagerSBHUD）与窗口背景色清透明
 *      - 内部功能元素（音量条填充、文字颜色等 Apple 类）不动
 *   挂点：VMViewController viewDidAppear:/viewDidLoad、VMHUDView didMoveToWindow；
 *   method_setImplementation 手动挂钩；带「方法须由类自身实现」防误伤守卫
 *   （防 Swift 类未覆写目标方法时误挂父类 → 把 SpringBoard 全部视图一锅端）。
 *
 * 日志：NSLog + 中央数据目录 vmaq-hudpatch.log + /tmp 镜像双写
 *      （SpringBoard 为 root，中央可写；/tmp 镜像沿用 PrefsClean 双写惯例）。
 * ============================================================================
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <stdio.h>

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

    NSString *line = [NSString stringWithFormat:@"[%@] %@\n",
        [[NSDate date] descriptionWithLocale:nil], msg];

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
static IMP gOrigVCAppear   = NULL;
static IMP gOrigVCLoad     = NULL;
static IMP gOrigViewMove   = NULL;
static int gAttached       = 0;
static int gDumpDone       = 0;

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
// 钩子实现（orig 先行，后处理）
// ===========================================================================
static void VHPVCAppearHook(id self, SEL _cmd, BOOL animated) {
    if (gOrigVCAppear) ((void (*)(id, SEL, BOOL))gOrigVCAppear)(self, _cmd, animated);
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

// 对已加载的 HUD 类装挂钩。挂点优先级：
//   VMViewController.viewDidAppear:（窗口已挂、层次最全）
//   → VMViewController.viewDidLoad → VMHUDView.didMoveToWindow
static void VHPAttach(void) {
    if (gAttached) return;
    Class vc   = objc_getClass("_TtC18VolumeManagerSBHUD16VMViewController");
    Class view = objc_getClass("_TtC18VolumeManagerSBHUD9VMHUDView");

    if (vc) {
        IMP o = VHPSwizzle(vc, @selector(viewDidAppear:), (IMP)&VHPVCAppearHook);
        if (o) { gOrigVCAppear = o; gAttached = 1;
                 VHPLog(@"已挂 VMViewController viewDidAppear:"); return; }
        o = VHPSwizzle(vc, @selector(viewDidLoad), (IMP)&VHPVCLoadHook);
        if (o) { gOrigVCLoad = o; gAttached = 1;
                 VHPLog(@"已挂 VMViewController viewDidLoad"); return; }
    }
    if (view) {
        IMP o = VHPSwizzle(view, @selector(didMoveToWindow), (IMP)&VHPViewMoveHook);
        if (o) { gOrigViewMove = o; gAttached = 1;
                 VHPLog(@"已挂 VMHUDView didMoveToWindow"); return; }
    }
    VHPLog(@"HUD 类已加载但没有可挂方法（需换挂点）");
}

// dyld 镜像回调（C 函数指针）：HUD 镜像一出现即装
static void VHPImageAdded(const struct mach_header *mh, intptr_t slide) {
    Dl_info info;
    if (dladdr((const void *)mh, &info) && info.dli_fname &&
        strstr(info.dli_fname, "/VolumeManagerSBHUD.dylib")) {
        VHPAttach();
    }
}

static void VHPInstall(void) {
    const char *suffix = "/VolumeManagerSBHUD.dylib";
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *n = _dyld_get_image_name(i);
        if (n && strstr(n, suffix)) {
            VHPLog(@"HUD 镜像已加载，直接挂");
            VHPAttach();
            return;
        }
    }
    _dyld_register_func_for_add_image(VHPImageAdded);
    VHPLog(@"等待 VolumeManagerSBHUD.dylib 加载（dyld 回调已挂）");
}

// ===========================================================================
// 入口
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

        VHPLog(@"注入 pid=%d 透明补丁=%d dump探针=%d",
               (int)[[NSProcessInfo processInfo] processIdentifier],
               gVHPPatch, gVHPDump);
        VHPInstall();
    }
}
