/*
 * VMPWhitelistController.m —— 应用白名单页（v5：PS 原生渲染 + 动态 specifiers）
 * 每应用一行：PSSwitchCell（get/set selector 读写 VMPWhitelistRead/Write——引擎
 * 现有白名单文件源零改动）+ 图标（specifier icon 属性）+ bid 副标题。
 * Section 1：已启用应用的音量调节入口（push 音量页）。
 * 种子语义：白名单文件不存在时，首次进入按默认值创建一次
 * （音频类 + volumeInfo 已配置 且非系统应用 = 勾）；之后文件即唯一真相。
 */
#import "VMPControllers.h"

static NSString * const kCellSwitch = @"PSSwitchCell";
static NSString * const kCellLink   = @"PSLinkCell";
static NSString * const kCellGroup  = @"PSGroupCell";

@implementation VMPWhitelistController

- (instancetype)init {
    if ((self = [super init])) {
        VMPDiagLog(@"whitelist v5 init");
    }
    return self;
}

- (instancetype)initWithSpecifier:(PSSpecifier *)specifier {
    if ((self = [super init])) {
        VMPDiagLog(@"whitelist v5 initSpec");
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"应用白名单";
    if (self.scanned) return;
    self.scanned = YES;

    // 文件不存在 = 首次采用白名单模式 → 扫描完成后按默认值补种
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL fileExisted = [fm fileExistsAtPath:VMPWhitelistDataPath()]
                    || [fm fileExistsAtPath:VMPWhitelistSyncedPath()];
    self.seeding = !fileExisted;

    VMPDiagLog(@"whitelist: 开始扫描（首建补种=%d）", self.seeding);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<VMPAppEntry *> *apps = VMPScanApps();
        dispatch_async(dispatch_get_main_queue(), ^{
            self.apps = apps;
            [self finishSeedingIfNeeded];
            [self reloadWhitelist];
            VMPDiagLog(@"whitelist: 扫描完成 %lu 项", (unsigned long)apps.count);
        });
    });
}

// 首建补种：音频类 + 已配置 且非系统应用 → 勾（文件从此存在 → 引擎进入白名单模式）
- (void)finishSeedingIfNeeded {
    if (!self.seeding) return;
    NSMutableArray *en = [VMPWhitelistRead() mutableCopy];
    NSDictionary *vol = VMPVolumeInfoReadMutable();
    for (VMPAppEntry *e in self.apps) {
        BOOL defaultOn = (!e.isSystem && (e.hasAudioMode || vol[e.bid] != nil));
        if (defaultOn && ![en containsObject:e.bid]) [en addObject:e.bid];
    }
    VMPWhitelistWrite([en copy]);
    VMPDiagLog(@"whitelist: 首建补种完成 %lu 项", (unsigned long)en.count);
}

- (NSMutableArray<NSString *> *)currentEnabled {
    return [VMPWhitelistRead() mutableCopy];
}

- (NSArray<VMPAppEntry *> *)enabledApps {
    NSMutableArray<VMPAppEntry *> *a = [NSMutableArray array];
    NSMutableArray<NSString *> *en = [self currentEnabled];
    for (VMPAppEntry *e in self.apps) {
        if ([en containsObject:e.bid]) [a addObject:e];
    }
    return a;
}

#pragma mark - specifiers

- (NSMutableArray *)vmp_buildSpecifiers {
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
        return specs;
    }

    NSMutableArray<NSString *> *en = [self currentEnabled];

    for (VMPAppEntry *e in self.apps) {
        NSString *title = e.name;
        if (e.isSystem) title = [title stringByAppendingString:@"（系统）"];
        if (e.hasAudioMode) title = [@"♪ " stringByAppendingString:title];
        PSSpecifier *sp = [PSSpecifier preferenceSpecifierNamed:title
            target:self set:@selector(setInjectValue:forSpecifier:)
            get:@selector(injectValueForSpecifier:)
            detail:nil cell:kCellSwitch edit:nil];
        [sp setProperty:e.bid forKey:@"bid"];
        if (e.icon) [sp setProperty:e.icon forKey:@"icon"];
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
            detail:[VMPVolumeController class] cell:kCellLink edit:nil];
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
    return specs;
}

- (NSArray *)specifiers {
    id cur = nil;
    @try { cur = [self valueForKey:@"_specifiers"]; } @catch (NSException *e) { }
    if ([cur isKindOfClass:[NSArray class]] && [(NSArray *)cur count] > 0) return cur;

    NSMutableArray *specs = [self vmp_buildSpecifiers];
    @try {
        [self setValue:specs forKey:@"_specifiers"];
    } @catch (NSException *e) {
        VMPDiagLog(@"whitelist v5: KVC _specifiers 失败: %@", e);
    }
    return specs;
}

- (void)reloadWhitelist {
    // 重载：清基类 ivar → getter 重建 → reload（PS 原生渲染路径）
    @try { [self setValue:[NSMutableArray new] forKey:@"_specifiers"]; } @catch (NSException *e) { }
    [self reloadSpecifiers];
}

#pragma mark - 开关读写（PS get/set 契约）

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
    VMPDiagLog(@"whitelist: %@ → %@", bid, [value boolValue] ? @"开" : @"关");
    [self reloadWhitelist];   // 音量调节段跟随勾选变化
}

@end
