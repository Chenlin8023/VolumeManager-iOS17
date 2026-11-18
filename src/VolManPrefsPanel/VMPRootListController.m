/*
 * VMPRootListController.m —— 根页：总开关 / 启用混音 / 应用白名单入口
 * 总开关写 prefs 域 isEnabledManagementAppVolume（引擎热轮询即时生效）；
 * 混音写 vmMixEnabled 配置（引擎 ctor 读取，重启 App 生效，页脚注明）。
 *
 * CI 头适配：cell: 参数是 PSCellType 枚举（PSSwitchCell 等为枚举常量，直接用
 * 头里的名字）；specifiers ivar 自声明（基类不暴露），类声明在 VMPControllers.h。
 */
#import "VMPControllers.h"

@implementation VMPRootListController

// 二进制加载即诊（dlopen 时机，早于一切）：加载时类层级
+ (void)load {
    VMPDiagLog(@"+load: bundle binary loaded, rootClass=%@ rootSuper=%@",
        NSStringFromClass([VMPRootListController class]),
        [VMPRootListController superclass]
            ? NSStringFromClass([VMPRootListController superclass]) : @"(nil)");
}

// PS 契约：推 detail 时 controllerForSpecifier: 会无设防调用 initWithSpecifier:
// （实机崩溃实锤 2026-11-18）——基类头未声明该 selector，子类自带实现走
// [super init] 安全链（根页无上下文，空实现即可）。
- (instancetype)initWithSpecifier:(PSSpecifier *)specifier {
    if ((self = [super init])) {
        VMPDiagHierarchy(self, @"root-initSpec");
    }
    return self;
}

// 普通路径防御：若 PS 走 plain init 创建（不调 initWithSpecifier:），也留诊断
- (instancetype)init {
    if ((self = [super init])) {
        VMPDiagHierarchy(self, @"root-plain-init");
    }
    return self;
}

- (NSArray *)specifiers {
    if (!_vmpSpecifiers) {
        PSSpecifier *g1 = [PSSpecifier groupSpecifierWithName:@"音量管理"];
        [g1 setProperty:@"总开关关闭时，所有应用的音量调整与混音全部停止。"
                  forKey:@"footerText"];

        PSSpecifier *master = [PSSpecifier preferenceSpecifierNamed:@"启用音量管理"
            target:self set:@selector(setMasterValue:forSpecifier:)
            get:@selector(masterValueForSpecifier:)
            detail:nil cell:PSSwitchCell edit:nil];
        [master setIdentifier:@"master"];

        PSSpecifier *mix = [PSSpecifier preferenceSpecifierNamed:@"启用混音（多应用同播）"
            target:self set:@selector(setMixValue:forSpecifier:)
            get:@selector(mixValueForSpecifier:)
            detail:nil cell:PSSwitchCell edit:nil];
        [mix setIdentifier:@"mix"];
        PSSpecifier *mixFoot = [PSSpecifier groupSpecifierWithName:@" "];
        [mixFoot setProperty:@"混音开关在应用下次启动时生效（引擎启动时读取）。"
                  forKey:@"footerText"];

        PSSpecifier *g2 = [PSSpecifier groupSpecifierWithName:@"应用"];
        PSSpecifier *wl = [PSSpecifier preferenceSpecifierNamed:@"应用白名单"
            target:self set:NULL get:NULL
            detail:[VMPWhitelistController class] cell:PSLinkCell edit:nil];
        [wl setIdentifier:@"whitelist"];

        _vmpSpecifiers = @[ g1, master, mix, mixFoot, g2, wl ];
    }
    return _vmpSpecifiers;
}

- (id)masterValueForSpecifier:(PSSpecifier *)spec {
    return @(VMPMasterEnabledRead());
}
- (void)setMasterValue:(id)value forSpecifier:(PSSpecifier *)spec {
    VMPMasterEnabledWrite([value boolValue]);
    VMPPostSettingChanged();
}

- (id)mixValueForSpecifier:(PSSpecifier *)spec {
    return @(VMPMixEnabledRead());
}
- (void)setMixValue:(id)value forSpecifier:(PSSpecifier *)spec {
    VMPMixEnabledWrite([value boolValue]);
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"音量管理器";
}

@end
