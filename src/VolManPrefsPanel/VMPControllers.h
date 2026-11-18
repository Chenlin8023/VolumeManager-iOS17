/*
 * VMPControllers.h —— 三个控制器的前置声明（CI 头适配：基类不暴露
 * specifiers ivar，各自声明；跨文件 push 引用需要完整 @interface）。
 */
#import "VMPShared.h"
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

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
