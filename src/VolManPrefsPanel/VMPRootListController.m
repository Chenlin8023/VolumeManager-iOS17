/*
 * VMPRootListController.m —— 根页：总开关 / 启用混音 / 应用白名单入口
 * 总开关写 prefs 域 isEnabledManagementAppVolume（引擎热轮询即时生效）；
 * 混音写 vmMixEnabled 配置（引擎 ctor 读取，重启 App 生效，页脚注明）。
 */
#import "VMPShared.h"
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

// cell 类型常量（框架内字符串值；Theos 各版本头不齐，自行定义最稳）
static NSString * const kCellGroup  = @"PSGroupCell";
static NSString * const kCellSwitch = @"PSSwitchCell";
static NSString * const kCellLink   = @"PSLinkCell";

@implementation VMPRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        PSSpecifier *g1 = [PSSpecifier groupSpecifierWithName:@"音量管理"];
        [g1 setProperty:@"总开关关闭时，所有应用的音量调整与混音全部停止。" forKey:@"footerText"];

        PSSpecifier *master = [PSSpecifier preferenceSpecifierNamed:@"启用音量管理"
            target:self set:@selector(setMasterValue:forSpecifier:)
            get:@selector(masterValueForSpecifier:)
            detail:nil cell:kCellSwitch edit:nil];
        [master setIdentifier:@"master"];

        PSSpecifier *mix = [PSSpecifier preferenceSpecifierNamed:@"启用混音（多应用同播）"
            target:self set:@selector(setMixValue:forSpecifier:)
            get:@selector(mixValueForSpecifier:)
            detail:nil cell:kCellSwitch edit:nil];
        [mix setIdentifier:@"mix"];

        PSSpecifier *g2 = [PSSpecifier groupSpecifierWithName:@"应用"];
        PSSpecifier *wl = [PSSpecifier preferenceSpecifierNamed:@"应用白名单"
            target:self set:NULL get:NULL
            detail:[VMPWhitelistController class] cell:kCellLink edit:nil];
        [wl setIdentifier:@"whitelist"];

        _specifiers = @[ g1, master, mix, g2, wl ];
    }
    return _specifiers;
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

- (NSString *)navigationBarTitle {
    return @"音量管理器";
}

@end
