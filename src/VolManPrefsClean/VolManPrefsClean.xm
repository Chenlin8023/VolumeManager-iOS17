/*
 * VolManPrefsClean v1.0.1（自诊断版）
 * ============================================================================
 * v1.0.1 变更 —— 解决「装上去毫无反应、连日志都没有」无法定位的问题：
 *   1. 模块加载瞬间（%ctor）立刻写一条日志，先证明「有没有被注入」。
 *   2. 日志目录改为「逐条实测可写」再选用，候选含 jbroot 派生路径与应用自身
 *      tmp 目录；全都不行时至少 NSLog 仍有输出。选中的路径本身也写进日志。
 *   3. 除 Swift 面板类的 -specifiers 外，同时挂钩 PSListController 的
 *      -specifiers，覆盖「面板并非由 RootListController 提供」这一可能。
 *   4. 首次遇到疑似面板页时，把该页**全部条目的 label / identifier** 原样
 *      写进日志，用于比对判定表。每个类只 dump 一次，不会刷屏。
 *   5. 轮询超时会明确记一行「仍未找到面板类」，不再静默退出。
 *
 * 作用：清理 VolumeManager 设置面板（VolumeManagerPrefs.bundle）中作者遗留的
 *       推广信息，包括：
 *         · 支付宝打赏条目与收款链接
 *         · GitHub 主页 / 关注 / 查看源码 条目
 *         · Sileo 源条目
 *         · 反盗版声明
 *         · 面板末尾那段针对其他插件作者的长篇攻击文字
 *       功能性条目（总开关、HUD 显示条件、混音选项、应用音量列表）一律保留。
 *
 * 原理：
 *   原作设置面板是 Swift 编译产物，这些文案硬编码在 __TEXT,__cstring 中，
 *   且是 FAT 双切片（arm64 + arm64e），静态改写容易踩到 Swift 字符串长度字段，
 *   故采用运行时方案：拦下 RootListController 的 -specifiers，
 *   在返回给 Preferences 框架之前把目标条目从数组里摘掉。
 *
 *   条目判定优先用「逐字精确文案」（从原作二进制里 dump 出来的原文），
 *   另有宽松兜底（含 (支付宝)、(GitHub)、ugly-soul 等片段即判为推广条目），
 *   防止作者改版换文案。footerText 只做文本清理，不参与删除判定 ——
 *   否则「HUD 显示条件」那条的说明文字里提到 GitHub，会被误删功能项。
 *
 * 注入范围：只注入 com.apple.Preferences 进程，与音频模块完全隔离。
 * ============================================================================
 */

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <stdarg.h>
#import <limits.h>
#import <sys/stat.h>
#import <sys/types.h>
#import <time.h>

// 本文件按 ObjC++ 编译，必须显式 C 链接，否则符号会被 mangle 成
// __Z15MSHookMessageEx... 而链接不到 libsubstrate 里的 C 符号。
// 若 Logos 已从 substrate.h 引入过同签名声明，这里的重复声明是合法的。
#ifdef __cplusplus
extern "C" {
#endif
extern void MSHookMessageEx(Class cls, SEL selector, IMP replacement, IMP *result);
#ifdef __cplusplus
}
#endif

static const char *kTag = "[VolManPrefsClean]";

#pragma mark - 日志

// 日志体积上限：超过上限时只保留尾部，而非整份清空。
// 诊断日志的价值全在「最近发生了什么」，所以丢头部、留尾部。
#define VMLOG_MAX_BYTES   (128 * 1024)
#define VMLOG_KEEP_BYTES  ( 64 * 1024)

// 追加一行；若文件已超上限，先把尾部搬进新文件再追加。
// 全程用 C 文件 API，不经 NSString 路径，避开 libroot 就地改写缓冲区的问题。
static void VMAppendLine(const char *path, const char *line) {
    if (!path || !path[0] || !line) return;

    FILE *fp = fopen(path, "a");
    if (!fp) return;

    fseek(fp, 0, SEEK_END);
    long size = ftell(fp);
    if (size <= VMLOG_MAX_BYTES) {
        fputs(line, fp);
        fclose(fp);
        return;
    }
    fclose(fp);

    // —— 超限：读尾部 VMLOG_KEEP_BYTES 字节 ——
    FILE *in = fopen(path, "rb");
    if (!in) return;
    fseek(in, 0, SEEK_END);
    long total = ftell(in);
    long start = total > VMLOG_KEEP_BYTES ? total - VMLOG_KEEP_BYTES : 0;
    fseek(in, start, SEEK_SET);
    size_t want = (size_t)(total - start);
    char *tail = (char *)malloc(want + 1);
    if (!tail) { fclose(in); return; }
    size_t got = fread(tail, 1, want, in);
    tail[got] = '\0';
    fclose(in);

    // 丢弃第一行残片，保证从完整行开始
    size_t skip = 0;
    while (skip < got && tail[skip] != '\n') skip++;
    if (skip < got) skip++;
    else skip = 0;

    FILE *out = fopen(path, "w");
    if (!out) { free(tail); return; }
    fprintf(out, "=== 日志超过 %d KB，已丢弃较早内容，以下为最近 %d KB ===\n",
            VMLOG_MAX_BYTES / 1024, VMLOG_KEEP_BYTES / 1024);
    fwrite(tail + skip, 1, got - skip, out);
    fputs(line, out);
    fclose(out);
    free(tail);
}

// 选中的日志路径（C 字符串，避免 libroot 就地改写 NSString 缓冲区导致路径变形）
static char gLogPath[PATH_MAX] = {0};
static char gLogDir[PATH_MAX]  = {0};
static char gMirrorPath[PATH_MAX] = {0};   // /tmp 镜像，主路径落空时唯一可见痕迹

static BOOL VMCanAppend(const char *path) {
    if (!path || !path[0]) return NO;
    char buf[PATH_MAX];
    strncpy(buf, path, sizeof(buf) - 1);
    buf[sizeof(buf) - 1] = '\0';
    FILE *fp = fopen(buf, "a");
    if (!fp) return NO;
    fclose(fp);
    return YES;
}

// 目录不存在就建一级（父级必须已存在）。
// Preferences 以 mobile 身份运行，/var/mobile/Library 下通常可写。
// libroot 的 stat 钩子会就地改写调用方的 C 缓冲区，所以每次调用前都重新拷贝。
static BOOL VMEnsureDir(const char *dir) {
    if (!dir || !dir[0]) return NO;
    char buf[PATH_MAX];
    struct stat st;

    strncpy(buf, dir, sizeof(buf) - 1);
    buf[sizeof(buf) - 1] = '\0';
    if (stat(buf, &st) == 0 && S_ISDIR(st.st_mode)) return YES;

    mkdir(dir, 0755);

    strncpy(buf, dir, sizeof(buf) - 1);
    buf[sizeof(buf) - 1] = '\0';
    return (stat(buf, &st) == 0 && S_ISDIR(st.st_mode));
}

// 逐条实测「建目录 + 打开-追加」是否成功，取第一条真正可写的作为主日志。
// 另在 /tmp 固定再写一份镜像：即便主路径全部落空，用户仍能在 Filza 里找到痕迹。
static void VMResolveLogPath(void) {
    if (gLogPath[0]) return;

    NSMutableArray<NSString *> *dirs = [NSMutableArray array];
    [dirs addObject:@"/var/jb/var/mobile/Library/VolumeManager-sunshinesong"];
    [dirs addObject:@"/var/mobile/Library/VolumeManager-sunshinesong"];

    NSString *home = NSHomeDirectory();
    if (home.length) {
        // roothide 下 home 形如 <jbroot>/var/mobile，插件数据目录就在其 Library 下
        [dirs addObject:[home stringByAppendingPathComponent:@"Library/VolumeManager-sunshinesong"]];
    }

    for (NSString *d in dirs) {
        const char *dp = [d fileSystemRepresentation];
        if (!dp) continue;

        char dbuf[PATH_MAX];
        strncpy(dbuf, dp, sizeof(dbuf) - 1);
        dbuf[sizeof(dbuf) - 1] = '\0';

        if (!VMEnsureDir(dbuf)) continue;

        NSString *cand = [d stringByAppendingPathComponent:@"vm-prefsclean.log"];
        const char *p = [cand fileSystemRepresentation];
        if (!p) continue;

        char buf[PATH_MAX];
        strncpy(buf, p, sizeof(buf) - 1);
        buf[sizeof(buf) - 1] = '\0';
        if (!VMCanAppend(buf)) continue;

        strncpy(gLogPath, buf, sizeof(gLogPath) - 1);
        strncpy(gLogDir, dbuf, sizeof(gLogDir) - 1);
        break;
    }

    // 镜像：固定 /tmp 一份
    char mbuf[PATH_MAX];
    strncpy(mbuf, "/tmp/vm-prefsclean.log", sizeof(mbuf) - 1);
    mbuf[sizeof(mbuf) - 1] = '\0';
    if (VMCanAppend(mbuf)) {
        if (!gLogPath[0] || strcmp(gLogPath, mbuf) != 0) {
            strncpy(gMirrorPath, mbuf, sizeof(gMirrorPath) - 1);
        }
    }
}

static void VMLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSLog(@"%s %@", kTag, msg);

    static dispatch_once_t once;
    dispatch_once(&once, ^{ VMResolveLogPath(); });
    if (!gLogPath[0] && !gMirrorPath[0]) return;

    // 时间戳改用 C 接口：%ctor 在 dyld 初始化阶段执行，
    // NSDateFormatter 依赖 ICU/locale，此时初始化未必就绪，有崩溃风险。
    char ts[32] = "?";
    time_t tt = time(NULL);
    struct tm tmv;
    if (localtime_r(&tt, &tmv)) {
        strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", &tmv);
    }

    char line[4096];
    snprintf(line, sizeof(line), "[%s] %s\n", ts, msg.UTF8String ?: "");

    // 主路径与 /tmp 镜像各写一份；两份内容相同，任一份可见即可诊断。
    if (gLogPath[0]) {
        char b1[PATH_MAX];
        strncpy(b1, gLogPath, sizeof(b1) - 1);
        b1[sizeof(b1) - 1] = '\0';
        VMAppendLine(b1, line);
    }
    if (gMirrorPath[0]) {
        char b2[PATH_MAX];
        strncpy(b2, gMirrorPath, sizeof(b2) - 1);
        b2[sizeof(b2) - 1] = '\0';
        VMAppendLine(b2, line);
    }
}

#pragma mark - 判定表

// 逐字精确匹配（取自原作二进制 __TEXT,__cstring 的原文，含全角/半角标点）
static NSArray<NSString *> *VMExactLabels(void) {
    static NSArray *a = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        a = @[
            @"请杯咖啡, 动力十足。(thanks)!",
            @"请我喝杯咖啡(支付宝)",
            @"follow me.(GitHub)",
            @"关注我(GitHub)",
            @"查看源码(GitHub)",
            @"拒绝盗版，从我做起!",
            @"在Sileo添加我的源",
        ];
    });
    return a;
}

// 前缀匹配（末尾那段长篇攻击文字是一整个含换行的字符串）
static NSArray<NSString *> *VMTextPrefixes(void) {
    static NSArray *a = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        a = @[ @"说在最后的话" ];
    });
    return a;
}

// 宽松兜底：文案被改版也不放过
static NSArray<NSString *> *VMFallbackKeywords(void) {
    static NSArray *a = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        a = @[
            @"(支付宝)", @"（支付宝）", @"AliPay", @"alipay",
            @"(GitHub)", @"（GitHub）", @"(github)",
            @"followGithubAccount", @"ugly-soul", @"ugly-soul.github.io",
            @"打赏", @"赞助", @"捐赠", @"喝杯咖啡",
        ];
    });
    return a;
}

// footer 里需要抹掉的整句
static NSString *VMFooterSentenceToRemove(void) {
    return @"如果选择其他方式，则可以通过其他插件控制显示，具体适配方式后续我会在GitHub上说明。";
}

#pragma mark - PSSpecifier 取值

static id VMProp(id sp, NSString *key) {
    if (!sp || !key) return nil;
    SEL sel = @selector(propertyForKey:);
    if (![sp respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(sp, sel, key);
}

static NSString *VMStringProp(id sp, NSString *key) {
    id v = VMProp(sp, key);
    return [v isKindOfClass:[NSString class]] ? (NSString *)v : nil;
}

static BOOL VMIsGroupSpecifier(id sp) {
    static Class groupCls = Nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        groupCls = NSClassFromString(@"PSGroupSpecifier");
    });
    if (groupCls && [sp isKindOfClass:groupCls]) return YES;

    id cc = VMProp(sp, @"cellClass");
    if (!cc) return NO;
    NSString *n = [cc isKindOfClass:[NSString class]]
                    ? (NSString *)cc
                    : NSStringFromClass((Class)cc);
    return [n containsString:@"Group"];
}

#pragma mark - 面板识别与整页 dump（v1.0.1 诊断用）

// 判定「这一页可能是我们要处理的面板」：类名或条目文案命中任一标记即可
static BOOL VMLooksLikeTargetPage(id self, NSArray *list) {
    NSString *cn = NSStringFromClass([self class]);
    if (cn.length) {
        if ([cn rangeOfString:@"VolumeManager" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
        if ([cn rangeOfString:@"RootList"      options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    if (![list isKindOfClass:[NSArray class]]) return NO;

    NSArray *marks = @[ @"咖啡", @"GitHub", @"Sileo", @"支付宝", @"打赏", @"盗版",
                        @"说在最后", @"alipay", @"ugly-soul", @"HUD", @"音量" ];
    for (id sp in list) {
        NSString *lb  = VMStringProp(sp, @"label");
        NSString *idn = VMStringProp(sp, @"identifier");
        for (NSString *m in marks) {
            if (lb.length && [lb rangeOfString:m options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
            if (idn.length && [idn rangeOfString:m options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
        }
    }
    return NO;
}

// 每个类只 dump 一次：把面板上真实存在的条目原样写进日志，供比对判定表
static void VMDumpPage(id self, NSArray *list, NSString *source) {
    if (![list isKindOfClass:[NSArray class]]) return;

    static NSMutableSet *seen = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ seen = [NSMutableSet set]; });

    NSString *cn = NSStringFromClass([self class]) ?: @"(未知)";
    @synchronized (seen) {
        if ([seen containsObject:cn]) return;
        [seen addObject:cn];
    }

    VMLog(@"===== 面板 dump ===== 类=%@ 来源=%@ 条目=%lu 日志目录=%s",
          cn, source, (unsigned long)list.count, gLogDir[0] ? gLogDir : "(无)");

    NSUInteger i = 0;
    for (id sp in list) {
        if (i >= 80) {
            VMLog(@"  …… 余下 %lu 项省略", (unsigned long)(list.count - i));
            break;
        }
        VMLog(@"  [%02lu] label=%@ | id=%@ | group=%d",
              (unsigned long)i,
              VMStringProp(sp, @"label") ?: @"-",
              VMStringProp(sp, @"identifier") ?: @"-",
              VMIsGroupSpecifier(sp) ? 1 : 0);
        i++;
    }
    VMLog(@"===== dump 结束 =====");
}

static BOOL VMShouldDrop(id sp) {
    if (!sp) return NO;
    NSString *label = VMStringProp(sp, @"label");
    NSString *ident = VMStringProp(sp, @"identifier");
    if (!label && !ident) return NO;

    for (NSString *exact in VMExactLabels()) {
        if (label && [label isEqualToString:exact]) return YES;
        if (ident && [ident isEqualToString:exact]) return YES;
    }
    for (NSString *pfx in VMTextPrefixes()) {
        if (label && [label hasPrefix:pfx]) return YES;
        if (ident && [ident hasPrefix:pfx]) return YES;
    }
    for (NSString *kw in VMFallbackKeywords()) {
        if (label && [label rangeOfString:kw].location != NSNotFound) return YES;
        if (ident && [ident rangeOfString:kw].location != NSNotFound) return YES;
    }
    return NO;
}

#pragma mark - 文本清理（只改内容，不删条目）

static void VMApplyTextCleanup(id sp) {
    if (!sp) return;
    NSString *ft = VMStringProp(sp, @"footerText");
    if (ft.length == 0) return;

    NSString *cleaned = nil;
    if ([ft rangeOfString:@"说在最后的话"].location != NSNotFound) {
        cleaned = @"";
    } else {
        NSString *bad = VMFooterSentenceToRemove();
        if ([ft rangeOfString:bad].location != NSNotFound) {
            cleaned = [[ft stringByReplacingOccurrencesOfString:bad withString:@""]
                        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }
    }
    if (!cleaned || [cleaned isEqualToString:ft]) return;

    if ([sp respondsToSelector:@selector(setProperty:forKey:)]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(sp, @selector(setProperty:forKey:), cleaned, @"footerText");
        VMLog(@"footerText 已清理");
    }
}

#pragma mark - 过滤器

static NSArray *VMFilterSpecifiers(NSArray *input) {
    if (![input isKindOfClass:[NSArray class]] || input.count == 0) return input;

    NSMutableArray *out = [NSMutableArray arrayWithCapacity:input.count];
    id pendingGroup = nil;          // 尚未确认「后面还有成员」的分组头
    NSUInteger dropped = 0;

    for (id sp in input) {
        if (VMShouldDrop(sp)) {
            dropped++;
            VMLog(@"移除条目: label=%@ id=%@",
                  VMStringProp(sp, @"label") ?: @"-",
                  VMStringProp(sp, @"identifier") ?: @"-");
            continue;
        }
        if (VMIsGroupSpecifier(sp)) {
            // 上一个分组头若没等到成员，就是空组头，直接丢掉
            pendingGroup = sp;
            continue;
        }
        if (pendingGroup) {
            VMApplyTextCleanup(pendingGroup);
            [out addObject:pendingGroup];
            pendingGroup = nil;
        }
        VMApplyTextCleanup(sp);
        [out addObject:sp];
    }
    // 循环结束仍是 pendingGroup：说明它是队尾的孤立分组头，丢弃

    if (dropped == 0) return input;   // 没有改动就原样返回，避免多余拷贝
    VMLog(@"过滤完成: 原 %lu 项 -> 新 %lu 项 (移除 %lu)",
          (unsigned long)input.count, (unsigned long)out.count, (unsigned long)dropped);
    return out;
}

#pragma mark - Hook 安装

// --- 基类兜底挂钩（v1.0.1）----------------------------------------------
// RootListController 若自己实现了 -specifiers，挂基类拦不到；反之若面板
// 其实是别的 PSListController 子类，挂 Swift 类又拦不到。两条都挂上。
static IMP gOrigBaseSpecifiers = NULL;
static BOOL gBaseHooked = NO;

static NSArray *VMBaseSpecifiersHook(id self, SEL _cmd) {
    if (!gOrigBaseSpecifiers) return nil;
    id r = ((id (*)(id, SEL))gOrigBaseSpecifiers)(self, _cmd);
    @try {
        if (VMLooksLikeTargetPage(self, (NSArray *)r)) {
            VMDumpPage(self, (NSArray *)r, @"PSListController");
            NSArray *f = VMFilterSpecifiers((NSArray *)r);
            if (f != (NSArray *)r) return f;
        }
    } @catch (NSException *e) {
        VMLog(@"基类 specifiers 异常: %@", e);
    }
    return (NSArray *)r;
}

static void VMTryBaseHook(void) {
    if (gBaseHooked) return;
    Class cls = objc_getClass("PSListController");
    if (!cls) return;
    SEL sel = @selector(specifiers);
    if (!class_getInstanceMethod(cls, sel)) return;
    IMP orig = NULL;
    MSHookMessageEx(cls, sel, (IMP)&VMBaseSpecifiersHook, &orig);
    if (orig) {
        gOrigBaseSpecifiers = orig;
        gBaseHooked = YES;
        VMLog(@"已挂钩 PSListController -specifiers");
    }
}

// --- 面板类挂钩 ----------------------------------------------------------
static IMP gOrigSpecifiers = NULL;
static BOOL gInstalled = NO;

static NSArray *VMSpecifiersHook(id self, SEL _cmd) {
    if (!gOrigSpecifiers) return nil;
    id r = ((id (*)(id, SEL))gOrigSpecifiers)(self, _cmd);
    @try {
        VMDumpPage(self, (NSArray *)r, @"面板类");
        NSArray *f = VMFilterSpecifiers((NSArray *)r);
        if (f != (NSArray *)r) return f;
    } @catch (NSException *e) {
        VMLog(@"过滤异常: %@", e);
    }
    return (NSArray *)r;
}

static void VMTryInstall(void) {
    if (gInstalled) return;
    Class cls = objc_getClass("_TtC18VolumeManagerPrefs18RootListController");
    if (!cls) {
        static int miss = 0;
        miss++;
        // 只在 1 / 20 / 60 / 120 次各记一行，避免刷屏，但足以看出「一直没出现」
        if (miss == 1 || miss == 20 || miss == 60 || miss == 120) {
            VMLog(@"等待面板类… 第 %d 次未见 RootListController", miss);
        }
        return;
    }
    SEL sel = @selector(specifiers);
    if (!class_getInstanceMethod(cls, sel)) {
        VMLog(@"找到类但缺少 -specifiers");
        return;
    }
    IMP orig = NULL;
    MSHookMessageEx(cls, sel, (IMP)&VMSpecifiersHook, &orig);
    if (orig) {
        gOrigSpecifiers = orig;
        gInstalled = YES;
        VMLog(@"已挂钩 %s -specifiers", class_getName(cls));
    } else {
        VMLog(@"MSHookMessageEx 失败");
    }
}

static void VMPoll(int remaining);

static void VMPoll(int remaining) {
    if (gInstalled && gBaseHooked) return;
    if (remaining <= 0) {
        Class cls = objc_getClass("_TtC18VolumeManagerPrefs18RootListController");
        VMLog(@"轮询超时：面板类%s，基类挂钩%s",
              cls ? "已出现" : "始终未出现",
              gBaseHooked ? "成功" : "失败");
        return;
    }
    VMTryBaseHook();
    VMTryInstall();
    if (gInstalled && gBaseHooked) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        VMPoll(remaining - 1);
    });
}

#pragma mark - 入口

// 面板出现前一定会走 viewDidLoad，此时 bundle 已 dlopen，类已注册 —— 主路径
@interface PSListController : NSObject
- (void)viewDidLoad;
@end

%hook PSListController
- (void)viewDidLoad {
    // 只对疑似面板页记类名，避免把每个设置页都写进日志
    NSString *cn = NSStringFromClass([self class]) ?: @"?";
    if ([cn rangeOfString:@"VolumeManager" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [cn rangeOfString:@"RootList"      options:NSCaseInsensitiveSearch].location != NSNotFound) {
        VMLog(@"viewDidLoad 命中疑似面板类=%@", cn);
    }
    VMTryBaseHook();
    VMTryInstall();
    %orig;
}
%end

// 兜底：万一某条路径没走到 viewDidLoad，用轮询补上（最多 60 秒）
%ctor {
    @autoreleasepool {
        // 加载瞬间先落一条，用于区分「没被注入」与「注入但没找到面板」。
        // 过滤器已改为 UIKit（与音频模块同款，已验证可注入），因此每个 App 都会
        // 走到这里；非目标进程只记一行，避免日志被刷满。
        NSString *pn = [[NSProcessInfo processInfo] processName] ?: @"?";
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"?";
        BOOL isTarget = ([bid isEqualToString:@"com.apple.Preferences"] ||
                         [pn isEqualToString:@"Preferences"]);

        VMLog(@"注入 pid=%d 进程=%@ bundle=%@ 目标=%@",
              (int)[[NSProcessInfo processInfo] processIdentifier],
              pn, bid, isTarget ? @"是" : @"否");

        if (!isTarget) return;

        VMLog(@"主日志=%s", gLogPath[0] ? gLogPath : "(无)");
        VMLog(@"镜像日志=%s", gMirrorPath[0] ? gMirrorPath : "(无)");

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            VMPoll(120);
        });
    }
}
