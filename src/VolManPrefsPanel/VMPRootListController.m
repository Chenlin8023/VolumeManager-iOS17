/*
 * VMPRootListController.m —— 根页（v5：PS 原生渲染）
 * 总开关/混音开关 = defaults 域绑定（PS 原生读写 + PostNotification，零 get/set 代码）：
 *   isEnabledManagementAppVolume —— 引擎热轮询直接吃
 *   vmMixEnabled —— 引擎 VMMixLoadConfig 的 prefs 域候选已认（重启 App 生效）
 * 链接行 = push 白名单页 / 音量调节页
 * specifiers 构建后 KVC 写基类 _specifiers ivar（PS 自己的 delegate 方法读它）
 */
#import "VMPControllers.h"

static NSString * const kCellSwitch = @"PSSwitchCell";
static NSString * const kCellLink   = @"PSLinkCell";
static NSString * const kPrefsDomain = @"com.sunshinesong.volume-manager-prefs";

@implementation VMPRootListController

- (instancetype)init {
    if ((self = [super init])) {
        VMPDiagLog(@"root v5 init");
    }
    return self;
}

- (instancetype)initWithSpecifier:(PSSpecifier *)specifier {
    if ((self = [super init])) {
        VMPDiagLog(@"root v5 initSpec");
    }
    return self;
}

- (NSMutableArray *)vmp_buildSpecifiers {
    PSSpecifier *g1 = [PSSpecifier groupSpecifierWithName:@"音量管理"];
    [g1 setProperty:@"总开关关闭时，所有应用的音量调整与混音全部停止。混音开关在应用下次启动时生效。"
              forKey:@"footerText"];

    PSSpecifier *master = [PSSpecifier preferenceSpecifierNamed:@"启用音量管理"
        target:self set:NULL get:NULL detail:nil cell:PSSwitchCell edit:nil];
    [master setProperty:kPrefsDomain forKey:@"defaults"];
    [master setProperty:@"isEnabledManagementAppVolume" forKey:@"key"];
    [master setProperty:@"com.sunshinesong.volume-manager-prefs.settingOnChanged" forKey:@"PostNotification"];
    [master setProperty:@(YES) forKey:@"default"];

    PSSpecifier *mix = [PSSpecifier preferenceSpecifierNamed:@"启用混音（多应用同播）"
        target:self set:NULL get:NULL detail:nil cell:PSSwitchCell edit:nil];
    [mix setProperty:kPrefsDomain forKey:@"defaults"];
    [mix setProperty:@"vmMixEnabled" forKey:@"key"];
    [mix setProperty:@(YES) forKey:@"default"];

    PSSpecifier *g2 = [PSSpecifier groupSpecifierWithName:@"应用"];
    PSSpecifier *wl = [PSSpecifier preferenceSpecifierNamed:@"应用白名单"
        target:self set:NULL get:NULL
        detail:[VMPWhitelistController class] cell:kCellLink edit:nil];
    PSSpecifier *vol = [PSSpecifier preferenceSpecifierNamed:@"音量调节"
        target:self set:NULL get:NULL
        detail:[VMPVolumeController class] cell:kCellLink edit:nil];

    NSMutableArray *specs = [NSMutableArray arrayWithObjects:g1, master, mix, g2, wl, vol, nil];
    VMPDiagLog(@"root v5: 构建 %lu 项", (unsigned long)specs.count);
    return specs;
}

// 基类 ivar 为空 → 构建 + KVC 写入；非空 → 直接返回基类 ivar（PS 可能已填充）
- (NSArray *)specifiers {
    id cur = nil;
    @try { cur = [self valueForKey:@"_specifiers"]; } @catch (NSException *e) { }
    if ([cur isKindOfClass:[NSArray class]] && [(NSArray *)cur count] > 0) return cur;

    NSMutableArray *specs = [self vmp_buildSpecifiers];
    @try {
        [self setValue:specs forKey:@"_specifiers"];
    } @catch (NSException *e) {
        VMPDiagLog(@"root v5: KVC _specifiers 失败: %@", e);
    }
    return specs;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"音量管理器";
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 开关状态回流：PS 原生开关按 defaults 重绘（重建 cell 时回读域值）
    [self reloadSpecifiers];
}

@end
