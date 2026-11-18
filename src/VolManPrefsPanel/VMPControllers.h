/*
 * VMPControllers.h —— 三个控制器的前置声明（CI 头适配：基类不暴露
 * specifiers ivar，各自声明；跨文件 push 引用需要完整 @interface）。
 */
#import "VMPShared.h"
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <objc/message.h>

// CI 头兼容：基类 plist 加载器声明（运行时存在；头版本差异由 category 补声明）。
// 三个控制器的加载截流覆写依赖这两个声明。
@interface PSListController (VMPCompat)
- (NSMutableArray *)loadSpecifiersFromPlistName:(NSString *)name target:(PSListController *)target;
- (NSMutableArray *)loadSpecifiersFromPlistName:(NSString *)name target:(PSListController *)target bundle:(NSBundle *)bundle;
@end

// 共用同步原语：把 specifiers 写进基类 ivar（KVC）+ 属性 setter + 表格刷新。
// 不调用基类 reloadSpecifiers——它从 plist 源重派生，会覆盖我们塞的数组
// （2026-11-19 实机证据：构建 6 项 + setSpecifiers 同步 6 项后表格仍空）。
static inline void VMPBaseSync(id self, NSString *tag) {
    NSArray *specs = nil;
    @try { specs = [self performSelector:@selector(specifiers)]; } @catch (NSException *e) { }
    if (!specs) return;
    @try { [self setValue:specs forKey:@"_specifiers"]; } @catch (NSException *e) {
        VMPDiagLog(@"[%@] KVC _specifiers 失败: %@", tag, e);
    }
    if ([self respondsToSelector:@selector(setSpecifiers:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(self, @selector(setSpecifiers:), specs);
    }
    UITableView *tv = nil;
    @try { tv = [self valueForKey:@"table"]; } @catch (NSException *e) { }
    if (![tv isKindOfClass:[UITableView class]]) {
        @try { tv = (UITableView *)((id (*)(id, SEL))objc_msgSend)(self, @selector(view)); } @catch (NSException *e) { }
    }
    if ([tv isKindOfClass:[UITableView class]]) [tv reloadData];
    VMPDiagLog(@"[%@] base sync %lu 项（KVC+setter+tableReload）", tag, (unsigned long)specs.count);
}

@interface VMPRootListController : PSListController {
    NSArray *_vmpSpecifiers;
}
@end

@interface VMPWhitelistController : PSListController {
    NSArray *_vmpSpecifiers;
}
@property (nonatomic, strong) NSArray<VMPAppEntry *> *apps;
@property (nonatomic, strong) NSMutableArray<NSString *> *enabled;
@property (nonatomic, assign) BOOL scanned;
@property (nonatomic, assign) BOOL seeding;
@end

@interface VMPVolumeController : PSListController {
    NSArray *_vmpSpecifiers;
}
@property (nonatomic, copy) NSString *bid;
@property (nonatomic, copy) NSString *appName;
@end
