/*
 * VMPWhitelistController.m —— 应用白名单页（v2.0 步骤③核心页）
 * 种子语义（一句话）：白名单文件不存在时，首次进入本页按默认值创建一次
 * （音频类 + volumeInfo 已配置 且非系统应用 = 勾）；文件存在后它就是唯一真相，
 * 勾选变更直接改写。与引擎「缺失 = legacy 兼容模式」的三态裁决严丝合缝：
 * 用户进一次面板 = 显式采用白名单模式。
 */
#import "VMPControllers.h"

@implementation VMPWhitelistController

// PS 契约：无设防 initWithSpecifier:（见根页注释）——白名单页无上下文，安全链即可
- (instancetype)initWithSpecifier:(PSSpecifier *)specifier {
    if ((self = [super init])) { }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    if (self.scanned) return;
    self.scanned = YES;

    // 文件不存在 = 首次采用白名单模式 → 扫描完成后按默认值补种
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL fileExisted = [fm fileExistsAtPath:VMPWhitelistDataPath()]
                    || [fm fileExistsAtPath:VMPWhitelistSyncedPath()];
    self.seeding = !fileExisted;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<VMPAppEntry *> *apps = VMPScanApps();
        dispatch_async(dispatch_get_main_queue(), ^{
            self.apps = apps;
            [self rebuildSpecifiers];
        });
    });
}

- (NSMutableArray<NSString *> *)currentEnabled {
    if (self.enabled) return self.enabled;
    NSMutableArray *en = [VMPWhitelistRead() mutableCopy];
    if (self.seeding && self.apps) {
        // 首建补种：音频类 + 已配置 且非系统应用 → 勾
        NSDictionary *vol = VMPVolumeInfoReadMutable();
        for (VMPAppEntry *e in self.apps) {
            BOOL defaultOn = (!e.isSystem && (e.hasAudioMode || vol[e.bid] != nil));
            if (defaultOn && ![en containsObject:e.bid]) [en addObject:e.bid];
        }
        VMPWhitelistWrite([en copy]);   // 文件从此存在 → 引擎进入白名单模式
    }
    self.enabled = en;
    return en;
}

- (void)rebuildSpecifiers {
    NSMutableArray *specs = [NSMutableArray array];

    PSSpecifier *g1 = [PSSpecifier groupSpecifierWithName:@"应用白名单"];
    [g1 setProperty:@"勾选 = 引擎对该应用装载音量挂钩与混音；不勾 = 完全不注入。"
                 @"系统应用默认不勾选。改动需重启对应应用生效。"
              forKey:@"footerText"];
    [specs addObject:g1];

    if (!VMPMasterEnabledRead()) {
        PSSpecifier *off = [PSSpecifier groupSpecifierWithName:@"⚠ 总开关已关闭"];
        [off setProperty:@"根页总开关处于关闭状态，白名单不会生效。" forKey:@"footerText"];
        [specs addObject:off];
    }

    if (self.apps.count == 0) {
        [specs addObject:[PSSpecifier groupSpecifierWithName:@"（扫描无结果）"]];
        _vmpSpecifiers = specs;
        [self reloadSpecifiers];
        return;
    }

    NSMutableArray<NSString *> *en = [self currentEnabled];

    for (VMPAppEntry *e in self.apps) {
        NSString *title = e.name;
        if (e.isSystem) title = [title stringByAppendingString:@"（系统）"];
        if (e.hasAudioMode) title = [@"♪ " stringByAppendingString:title];
        PSSpecifier *sp = [PSSpecifier preferenceSpecifierNamed:title
            target:self set:@selector(setInjectValue:forSpecifier:)
            get:@selector(injectValueForSpecifier:)
            detail:nil cell:PSSwitchCell edit:nil];
        [sp setProperty:e.bid forKey:@"bid"];
        [specs addObject:sp];
    }

    PSSpecifier *g2 = [PSSpecifier groupSpecifierWithName:@"音量调节"];
    [g2 setProperty:@"点按行进入滑杆，音量即时生效（0 = 静音）；未列出的应用音量为 1.0。"
                 forKey:@"footerText"];
    [specs addObject:g2];

    NSUInteger linkCount = 0;
    for (VMPAppEntry *e in self.apps) {
        if (![en containsObject:e.bid]) continue;
        PSSpecifier *sp = [PSSpecifier preferenceSpecifierNamed:e.name
            target:self set:NULL get:NULL
            detail:[VMPVolumeController class] cell:PSLinkCell edit:nil];
        [sp setProperty:e.bid forKey:@"bid"];
        [sp setProperty:e.name forKey:@"appName"];
        [specs addObject:sp];
        linkCount++;
    }
    if (linkCount == 0) {
        [specs addObject:[PSSpecifier groupSpecifierWithName:@"（暂无已启用的应用）"]];
    }
    if (en.count == 0) {
        PSSpecifier *empty = [PSSpecifier groupSpecifierWithName:@"⚠ 空白名单 = 所有应用都不注入"];
        [empty setProperty:@"这是你自己勾选的结果；要恢复，请在上方勾选应用。" forKey:@"footerText"];
        [specs addObject:empty];
    }

    _vmpSpecifiers = specs;
    [self reloadSpecifiers];
}

- (NSArray *)specifiers {
    if (!_vmpSpecifiers) {
        PSSpecifier *g = [PSSpecifier groupSpecifierWithName:@"扫描中…"];
        _vmpSpecifiers = @[ g ];
    }
    return _vmpSpecifiers;
}

- (id)injectValueForSpecifier:(PSSpecifier *)spec {
    NSString *bid = [spec propertyForKey:@"bid"];
    return @([[self currentEnabled] containsObject:bid]);
}

- (void)setInjectValue:(id)value forSpecifier:(PSSpecifier *)spec {
    NSString *bid = [spec propertyForKey:@"bid"];
    NSMutableArray *en = [self currentEnabled];
    if ([value boolValue]) {
        if (![en containsObject:bid]) [en addObject:bid];
    } else {
        [en removeObject:bid];
    }
    VMPWhitelistWrite([en copy]);
    [self rebuildSpecifiers];   // 音量调节段跟随勾选变化
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.title = @"应用白名单";
}

@end
