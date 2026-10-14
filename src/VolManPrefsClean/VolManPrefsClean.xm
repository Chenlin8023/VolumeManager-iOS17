/*
 * VolManPrefsClean v1.0.0
 * ============================================================================
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
#import <string.h>
#import <stdarg.h>
#import <limits.h>

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

static void VMLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSLog(@"%s %@", kTag, msg);

    static NSString *logPath = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray *dirs = @[
            @"/var/jb/var/mobile/Library/VolumeManager-sunshinesong",
            @"/var/mobile/Library/VolumeManager-sunshinesong",
        ];
        for (NSString *d in dirs) {
            if ([fm fileExistsAtPath:d]) {
                logPath = [d stringByAppendingPathComponent:@"vm-prefsclean.log"];
                break;
            }
        }
    });
    if (!logPath) return;

    char buf[PATH_MAX];
    const char *p = [logPath fileSystemRepresentation];
    if (!p) return;
    strncpy(buf, p, sizeof(buf) - 1);
    buf[sizeof(buf) - 1] = '\0';

    FILE *fp = fopen(buf, "a");
    if (!fp) return;
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    fprintf(fp, "[%s] %s\n",
            [[df stringFromDate:[NSDate date]] UTF8String],
            msg.UTF8String);
    fclose(fp);
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

static IMP gOrigSpecifiers = NULL;
static BOOL gInstalled = NO;

static NSArray *VMSpecifiersHook(id self, SEL _cmd) {
    if (!gOrigSpecifiers) return nil;
    id r = ((id (*)(id, SEL))gOrigSpecifiers)(self, _cmd);
    @try {
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
    if (!cls) return;
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
    if (gInstalled || remaining <= 0) return;
    VMTryInstall();
    if (gInstalled) return;
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
    VMTryInstall();
    %orig;
}
%end

// 兜底：万一某条路径没走到 viewDidLoad，用轮询补上（最多 60 秒）
%ctor {
    @autoreleasepool {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            VMPoll(120);
        });
    }
}
