/*
 * VolManPrefsClean v1.1.0
 * ============================================================================
 * 作用：清理 VolumeManager 设置面板（VolumeManagerPrefs.bundle）里原作者遗留的
 *       推广信息与攻击性文字：
 *         · 支付宝打赏 / 收款二维码链接
 *         · GitHub 关注、查看源码链接
 *         · Sileo 源链接
 *         · 反盗版声明
 *         · 面板末尾那段针对其他插件作者的长篇攻击文字
 *       功能性条目（总开关、混音开关、HUD 显示条件、应用音量列表）一律保留。
 *
 * v1.1.0 相比 1.0.3 的改动：
 *   1. 双保险：
 *        静态层 —— 打包时由 vm-fix-full/tools/redact_prefs.py 把原版面板二进制里的
 *                  推广文案 / 链接 / 攻击长文按「等长」原则整段清空（见 06-build-full.sh）。
 *        运行层 —— 本模块在内存里把整条 specifier 摘掉，并拦截残留按钮与链接。
 *      任何一层生效，都不会再看到那些内容。
 *   2. 挂钩点补齐：
 *        -[PSListController setSpecifiers:]   ← 数组存进去的那一刻就过滤，
 *                                               后续内部取用拿不到脏数据
 *        -[PSListController specifiers]       ← 兜底（有些版本不走 setter）
 *        -[RootListController specifiers]     ← 面板自己重写 getter 时也拦得到
 *        -[RootListController buttonEvent:]   ← 漏网按钮点不下去
 *        -[UIApplication openURL:options:completionHandler:] ← 最后一道锁
 *   3. 判定更狠：原始文案精确匹配 + 关键词匹配 + 「已被静态清空成空白的按钮行」，
 *      空分组头、只含推广行的分组一并消失。
 *   4. 去掉作者遗留的调试后缀：「启用混响(isEnabled mixable)」→「启用混音」。
 *   5. 日志落 /tmp/vm-prefsclean.log 与沙箱临时目录，每个面板类 dump 一次条目表
 *      （文案截断到 60 字，避免把攻击长文再抄进日志）。
 *
 * 注入范围：Bundles = com.apple.UIKit（与主模块同款，已验证可注入 Preferences）。
 *           非 Preferences 进程在 %ctor 里立刻 return，只多一次 bundle id 判断。
 * ============================================================================
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
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

// 不依赖 MSHookMessageEx（否则本模块没有其它 Logos 钩子时链接不到 libsubstrate）。
// method_setImplementation 与 MSHookMessageEx 的语义一致：替换 IMP 并返回旧 IMP，
// 由我们自己在钩子里直接调用旧实现，效果相同且零外部符号依赖。
static IMP VMReplace(Class cls, SEL sel, IMP imp) {
    if (!cls || !sel || !imp) return NULL;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NULL;
    return method_setImplementation(m, imp);
}

static const char *kTag = "[VolManPrefsClean]";

#pragma mark - 日志

#define VMLOG_MAX_BYTES   (128 * 1024)
#define VMLOG_KEEP_BYTES  ( 64 * 1024)

static char gLogPath[PATH_MAX];
static char gMirrorPath[PATH_MAX];

static BOOL VMCanAppend(const char *path) {
    if (!path || !path[0]) return NO;
    FILE *fp = fopen(path, "a");
    if (!fp) return NO;
    fclose(fp);
    return YES;
}

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

    // 超过上限：保留尾部，丢头部（诊断价值都在最近发生了什么）
    FILE *in = fopen(path, "rb");
    if (!in) return;
    fseek(in, 0, SEEK_END);
    long total = ftell(in);
    long from = total > VMLOG_KEEP_BYTES ? total - VMLOG_KEEP_BYTES : 0;
    fseek(in, from, SEEK_SET);
    char *buf = (char *)malloc((size_t)(total - from) + 1);
    if (!buf) { fclose(in); return; }
    size_t n = fread(buf, 1, (size_t)(total - from), in);
    fclose(in);
    buf[n] = '\0';
    char *nl = strchr(buf, '\n');
    if (nl) memmove(buf, nl + 1, strlen(nl + 1) + 1);

    FILE *out = fopen(path, "wb");
    if (out) {
        fputs("=== 日志超过 128KB，已丢弃较早内容 ===\n", out);
        fputs(buf, out);
        fputs(line, out);
        fclose(out);
    }
    free(buf);
}

static void VMResolveLogPath(void) {
    const char *cands[] = {
        "/var/jb/var/mobile/Library/VolumeManager-sunshinesong/vm-prefsclean.log",
        "/var/mobile/Library/VolumeManager-sunshinesong/vm-prefsclean.log",
        "/.jbroot/var/mobile/Library/VolumeManager-sunshinesong/vm-prefsclean.log",
        "/tmp/vm-prefsclean.log",
        NULL
    };
    for (int i = 0; cands[i]; i++) {
        char buf[PATH_MAX];
        strncpy(buf, cands[i], sizeof(buf) - 1);
        buf[sizeof(buf) - 1] = '\0';
        if (VMCanAppend(buf)) {
            strncpy(gLogPath, buf, sizeof(gLogPath) - 1);
            gLogPath[sizeof(gLogPath) - 1] = '\0';
            break;
        }
    }
    // 沙箱内最后的落点
    NSString *tmp = NSTemporaryDirectory();
    if (tmp.length) {
        NSString *p = [tmp stringByAppendingPathComponent:@"vm-prefsclean.log"];
        char buf[PATH_MAX];
        strncpy(buf, p.fileSystemRepresentation, sizeof(buf) - 1);
        buf[sizeof(buf) - 1] = '\0';
        if (VMCanAppend(buf) && (!gLogPath[0] || strcmp(gLogPath, buf) != 0)) {
            strncpy(gMirrorPath, buf, sizeof(gMirrorPath) - 1);
            gMirrorPath[sizeof(gMirrorPath) - 1] = '\0';
        }
    }
    // /tmp 再留一份镜像，取日志最方便
    if (VMCanAppend("/tmp/vm-prefsclean.log") &&
        (!gLogPath[0] || strcmp(gLogPath, "/tmp/vm-prefsclean.log") != 0)) {
        strncpy(gMirrorPath, "/tmp/vm-prefsclean.log", sizeof(gMirrorPath) - 1);
        gMirrorPath[sizeof(gMirrorPath) - 1] = '\0';
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

    char ts[32] = "?";
    time_t tt = time(NULL);
    struct tm tmv;
    if (localtime_r(&tt, &tmv)) {
        strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", &tmv);
    }

    char line[4096];
    snprintf(line, sizeof(line), "[%s] %s\n", ts, msg.UTF8String ?: "");

    if (gLogPath[0])    VMAppendLine(gLogPath, line);
    if (gMirrorPath[0]) VMAppendLine(gMirrorPath, line);
}

// 给用户一个"肉眼可见"的状态通道：写进 Preferences 自己的偏好域。
// Filza 打开 /var/mobile/Library/Preferences/com.apple.Preferences.plist，
// 查 VolManPrefsCleanStatus 即可确认模块到底跑没跑、删了几条。
static void VMStatus(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return;
    @try {
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        [d setObject:s forKey:@"VolManPrefsCleanStatus"];
        [d synchronize];
    } @catch (NSException *e) { }
}

// 日志里只放短文案：避免把攻击长文又抄进日志
static NSString *VMBrief(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || s.length == 0) return @"-";
    NSString *one = [s stringByReplacingOccurrencesOfString:@"\n" withString:@"⏎"];
    if (one.length > 60) return [[one substringToIndex:60] stringByAppendingString:@"…"];
    return one;
}

#pragma mark - 判定表

// 原始文案（未打静态补丁时使用；打了补丁后这些串已被清成空白）
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

// 关键词（大小写不敏感）
static NSArray<NSString *> *VMKeywords(void) {
    static NSArray *a = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        a = @[
            @"github", @"sileo", @"alipay", @"支付宝", @"ugly-soul",
            @"打赏", @"赞助", @"捐赠", @"咖啡", @"盗版", @"说在最后",
            @"followgithubaccount", @"qr.alipay", @"收款", @"关注我", @"查看源码",
        ];
    });
    return a;
}

static NSString *VMFooterBadSentence(void) {
    return @"如果选择其他方式，则可以通过其他插件控制显示，具体适配方式后续我会在GitHub上说明。";
}

#pragma mark - PSSpecifier 取值

static id VMProp(id sp, NSString *key) {
    if (!sp || !key) return nil;
    SEL sel = @selector(propertyForKey:);
    if (![sp respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(sp, sel, key);
}

static void VMSetProp(id sp, id value, NSString *key) {
    if (!sp || !key) return;
    SEL sel = @selector(setProperty:forKey:);
    if (![sp respondsToSelector:sel]) return;
    ((void (*)(id, SEL, id, id))objc_msgSend)(sp, sel, value, key);
}

static NSString *VMStr(id sp, NSString *key) {
    id v = VMProp(sp, key);
    return [v isKindOfClass:[NSString class]] ? (NSString *)v : nil;
}

static BOOL VMIsBlank(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return YES;
    return [[s stringByTrimmingCharactersInSet:
             [NSCharacterSet whitespaceAndNewlineCharacterSet]] length] == 0;
}

static BOOL VMIsGroup(id sp) {
    static Class groupCls = Nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ groupCls = NSClassFromString(@"PSGroupSpecifier"); });
    if (groupCls && [sp isKindOfClass:groupCls]) return YES;

    id cc = VMProp(sp, @"cellClass");
    if (!cc) return NO;
    NSString *n = [cc isKindOfClass:[NSString class]] ? (NSString *)cc : NSStringFromClass((Class)cc);
    return [n containsString:@"Group"];
}

static BOOL VMCellIsButton(id sp) {
    id cc = VMProp(sp, @"cellClass");
    if (!cc) return NO;
    NSString *n = [cc isKindOfClass:[NSString class]] ? (NSString *)cc : NSStringFromClass((Class)cc);
    return [n rangeOfString:@"Button" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

#pragma mark - 判定

static BOOL VMShouldDrop(id sp) {
    if (!sp || VMIsGroup(sp)) return NO;

    NSString *label = VMStr(sp, @"label");
    NSString *ident = VMStr(sp, @"identifier");
    if (!label && !ident) return NO;

    for (NSString *e in VMExactLabels()) {
        if (label && [label isEqualToString:e]) return YES;
        if (ident && [ident isEqualToString:e]) return YES;
    }
    for (NSString *k in VMKeywords()) {
        if (label && [label rangeOfString:k options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
        if (ident && [ident rangeOfString:k options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    // 已被静态净化成空白的推广行：按钮行，或 identifier 也空
    if (VMIsBlank(label)) {
        if (VMCellIsButton(sp)) return YES;
        if (VMIsBlank(ident)) return YES;
    }
    return NO;
}

static NSString *VMCleanFooter(NSString *ft) {
    if (![ft isKindOfClass:[NSString class]] || ft.length == 0) return ft;
    if ([ft rangeOfString:@"说在最后"].location != NSNotFound) return @"";

    NSMutableString *s = [ft mutableCopy];
    [s replaceOccurrencesOfString:VMFooterBadSentence()
                       withString:@""
                          options:0
                            range:NSMakeRange(0, s.length)];

    // 兜底：仍带 GitHub 的整行删掉
    NSMutableArray *keep = [NSMutableArray array];
    for (NSString *line in [s componentsSeparatedByString:@"\n"]) {
        if ([line rangeOfString:@"github" options:NSCaseInsensitiveSearch].location != NSNotFound) continue;
        [keep addObject:line];
    }
    NSString *out = [[keep componentsJoinedByString:@"\n"]
                     stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return out ?: @"";
}

static void VMCleanLabel(id sp) {
    NSString *label = VMStr(sp, @"label");
    if (label.length == 0) return;
    NSString *newLabel = nil;
    if ([label rangeOfString:@"(isEnabled mixable)" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        newLabel = @"启用混音";
    } else if ([label isEqualToString:@"启用混响"]) {
        newLabel = @"启用混音";
    }
    if (!newLabel || [newLabel isEqualToString:label]) return;
    VMSetProp(sp, newLabel, @"label");
    if ([sp respondsToSelector:@selector(setName:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(sp, @selector(setName:), newLabel);
    }
    VMLog(@"标签改写：%@ → %@", label, newLabel);
}

static void VMCleanSpecifier(id sp) {
    if (!sp) return;
    VMCleanLabel(sp);
    NSString *ft = VMStr(sp, @"footerText");
    if (ft.length == 0) return;
    NSString *clean = VMCleanFooter(ft);
    if (clean && ![clean isEqualToString:ft]) {
        VMSetProp(sp, clean, @"footerText");
        VMLog(@"footerText 已清理（%lu → %lu 字）",
              (unsigned long)ft.length, (unsigned long)clean.length);
    }
}

#pragma mark - 面板识别 / dump

static BOOL VMLooksLikeTargetPage(id self, NSArray *list) {
    NSString *cn = NSStringFromClass([self class]);
    if (cn.length &&
        [cn rangeOfString:@"VolumeManagerPrefs" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return YES;
    }
    if (![list isKindOfClass:[NSArray class]]) return NO;
    for (id sp in list) {
        NSString *lb = VMStr(sp, @"label");
        NSString *idn = VMStr(sp, @"identifier");
        for (NSString *k in VMKeywords()) {
            if (lb.length && [lb rangeOfString:k options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
            if (idn.length && [idn rangeOfString:k options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
        }
    }
    return NO;
}

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

    VMLog(@"===== 面板 dump ===== 类=%@ 来源=%@ 条目=%lu",
          cn, source, (unsigned long)list.count);
    NSUInteger i = 0;
    for (id sp in list) {
        if (i >= 60) { VMLog(@"  …… 余下 %lu 项省略", (unsigned long)(list.count - i)); break; }
        VMLog(@"  [%02lu] label=%@ | id=%@ | cell=%@ | group=%d",
              (unsigned long)i,
              VMBrief(VMStr(sp, @"label")),
              VMBrief(VMStr(sp, @"identifier")),
              VMBrief(VMStr(sp, @"cellClass")),
              VMIsGroup(sp) ? 1 : 0);
        i++;
    }
    VMLog(@"===== dump 结束 =====");
}

#pragma mark - 过滤

static NSArray *VMFilterSpecifiers(NSArray *input) {
    if (![input isKindOfClass:[NSArray class]] || input.count == 0) return input;

    NSMutableArray *out = [NSMutableArray arrayWithCapacity:input.count];
    id pendingGroup = nil;
    NSUInteger dropped = 0;

    for (id sp in input) {
        if (VMShouldDrop(sp)) {
            dropped++;
            VMLog(@"移除条目: label=%@ id=%@",
                  VMBrief(VMStr(sp, @"label")), VMBrief(VMStr(sp, @"identifier")));
            continue;
        }
        if (VMIsGroup(sp)) {
            pendingGroup = sp;      // 等确认后面还有成员才保留
            continue;
        }
        if (pendingGroup) {
            VMCleanSpecifier(pendingGroup);
            [out addObject:pendingGroup];
            pendingGroup = nil;
        }
        VMCleanSpecifier(sp);
        [out addObject:sp];
    }
    // 队尾孤立的分组头丢弃（它的成员都被删光了）

    if (dropped == 0) return input;
    VMLog(@"过滤完成：%lu 项 → %lu 项（移除 %lu）",
          (unsigned long)input.count, (unsigned long)out.count, (unsigned long)dropped);
    VMStatus([NSString stringWithFormat:@"filtered %lu→%lu dropped=%lu",
              (unsigned long)input.count, (unsigned long)out.count, (unsigned long)dropped]);
    return out;
}

static NSArray *VMFilterIfTarget(id self, NSArray *arr, const char *src) {
    if (![arr isKindOfClass:[NSArray class]] || arr.count == 0) return arr;
    @try {
        if (!VMLooksLikeTargetPage(self, arr)) return arr;
        VMDumpPage(self, arr, [NSString stringWithUTF8String:src]);
        return VMFilterSpecifiers(arr);
    } @catch (NSException *e) {
        VMLog(@"过滤异常(%s): %@", src, e);
        return arr;
    }
}

#pragma mark - Hook 实现

static IMP gOrigBaseSpecs     = NULL;
static IMP gOrigBaseSetSpecs  = NULL;
static IMP gOrigRootSpecs     = NULL;
static IMP gOrigButton        = NULL;
static IMP gOrigOpenURL       = NULL;
static IMP gOrigViewDidLoad   = NULL;

static void VMTryInstall(void);   // 前置声明：viewDidLoad 钩子里要再尝试安装

static NSArray *VMBaseSpecsHook(id self, SEL _cmd) {
    if (!gOrigBaseSpecs) return nil;
    id r = ((id (*)(id, SEL))gOrigBaseSpecs)(self, _cmd);
    return VMFilterIfTarget(self, (NSArray *)r, "PSListController.get");
}

static void VMBaseSetSpecsHook(id self, SEL _cmd, NSArray *specs) {
    NSArray *f = VMFilterIfTarget(self, specs, "PSListController.set");
    if (gOrigBaseSetSpecs) ((void (*)(id, SEL, id))gOrigBaseSetSpecs)(self, _cmd, f ?: specs);
}

static NSArray *VMRootSpecsHook(id self, SEL _cmd) {
    if (!gOrigRootSpecs) return nil;
    id r = ((id (*)(id, SEL))gOrigRootSpecs)(self, _cmd);
    return VMFilterIfTarget(self, (NSArray *)r, "Root.get");
}

static void VMButtonHook(id self, SEL _cmd, id sp) {
    if (sp && VMShouldDrop(sp)) {
        VMLog(@"拦截按钮点击: label=%@ id=%@",
              VMBrief(VMStr(sp, @"label")), VMBrief(VMStr(sp, @"identifier")));
        return;
    }
    if (gOrigButton) ((void (*)(id, SEL, id))gOrigButton)(self, _cmd, sp);
}

static BOOL VMPromoURL(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || s.length == 0) return NO;
    NSArray *keys = @[ @"alipay", @"github", @"ugly-soul", @"sileo://source" ];
    for (NSString *k in keys) {
        if ([s rangeOfString:k options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

static void VMOpenURLHook(id self, SEL _cmd, NSURL *url, NSDictionary *opts, id completion) {
    NSString *s = url.absoluteString;
    if (VMPromoURL(s)) {
        VMLog(@"拦截链接: %@", s);
        if (completion) ((void (^)(BOOL))completion)(NO);
        return;
    }
    if (gOrigOpenURL) {
        ((void (*)(id, SEL, id, id, id))gOrigOpenURL)(self, _cmd, url, opts, completion);
    }
}

static void VMViewDidLoadHook(id self, SEL _cmd) {
    VMTryInstall();     // 面板类此时已随 bundle 加载
    if (gOrigViewDidLoad) ((void (*)(id, SEL))gOrigViewDidLoad)(self, _cmd);
}

#pragma mark - 安装

static BOOL gBaseHooked = NO;
static BOOL gRootHooked = NO;
static BOOL gURLHooked  = NO;

static void VMTryInstall(void) {
    BOOL changed = NO;
    Class ps = objc_getClass("PSListController");
    if (ps && !gBaseHooked) {
        IMP o = VMReplace(ps, @selector(specifiers), (IMP)&VMBaseSpecsHook);
        if (o) { gOrigBaseSpecs = o; changed = YES; VMLog(@"已挂钩 PSListController -specifiers"); }

        o = VMReplace(ps, @selector(setSpecifiers:), (IMP)&VMBaseSetSpecsHook);
        if (o) { gOrigBaseSetSpecs = o; changed = YES; VMLog(@"已挂钩 PSListController -setSpecifiers:"); }

        o = VMReplace(ps, @selector(viewDidLoad), (IMP)&VMViewDidLoadHook);
        if (o) { gOrigViewDidLoad = o; changed = YES; VMLog(@"已挂钩 viewDidLoad"); }

        gBaseHooked = YES;
    }

    Class root = objc_getClass("_TtC18VolumeManagerPrefs18RootListController");
    if (root && !gRootHooked) {
        IMP o = VMReplace(root, @selector(specifiers), (IMP)&VMRootSpecsHook);
        if (o) { gOrigRootSpecs = o; changed = YES; VMLog(@"已挂钩 RootListController -specifiers"); }

        o = VMReplace(root, @selector(buttonEvent:), (IMP)&VMButtonHook);
        if (o) { gOrigButton = o; changed = YES; VMLog(@"已挂钩 RootListController -buttonEvent:"); }

        gRootHooked = YES;
    }

    if (!gURLHooked) {
        Class uiapp = objc_getClass("UIApplication");
        IMP o = VMReplace(uiapp, @selector(openURL:options:completionHandler:), (IMP)&VMOpenURLHook);
        if (o) {
            gOrigOpenURL = o;
            gURLHooked = YES;
            changed = YES;
            VMLog(@"已挂钩 UIApplication -openURL:options:completionHandler:");
        }
    }

    if (changed) {
        VMStatus([NSString stringWithFormat:@"hooks base=%d root=%d url=%d",
                  gBaseHooked ? 1 : 0, gRootHooked ? 1 : 0, gURLHooked ? 1 : 0]);
    }
}

static void VMPoll(int remaining) {
    if (gBaseHooked && gRootHooked) return;
    if (remaining <= 0) {
        VMLog(@"轮询结束：base=%d root=%d url=%d",
              gBaseHooked ? 1 : 0, gRootHooked ? 1 : 0, gURLHooked ? 1 : 0);
        return;
    }
    VMTryInstall();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ VMPoll(remaining - 1); });
}

#pragma mark - 入口

%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
        NSString *pn  = [[NSProcessInfo processInfo] processName] ?: @"";
        BOOL target = [bid isEqualToString:@"com.apple.Preferences"] ||
                      [pn isEqualToString:@"Preferences"];

        if (!target) {
            // 非目标进程：只走 NSLog，不碰磁盘
            NSLog(@"%s 跳过 pid=%d 进程=%@ bundle=%@",
                  kTag, (int)[[NSProcessInfo processInfo] processIdentifier], pn, bid);
            return;
        }

        VMLog(@"注入 pid=%d 进程=%@ bundle=%@ 目标=是",
              (int)[[NSProcessInfo processInfo] processIdentifier], pn, bid);
        VMStatus(@"injected, waiting for pane");

        dispatch_async(dispatch_get_main_queue(), ^{
            VMTryInstall();
            VMPoll(200);   // 0.3s × 200 ≈ 60s
        });
    }
}
