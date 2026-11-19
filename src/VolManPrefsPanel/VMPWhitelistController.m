/*
 * VMPWhitelistController.m —— 应用白名单页（v5：PS 原生渲染 + 动态 specifiers）
 * 每应用一行：PSSwitchCell（get/set selector 读写 VMPWhitelistRead/Write——引擎
 * 现有白名单文件源零改动）+ 图标（specifier icon 属性）。
 * 种子语义：白名单文件不存在时，首次进入按默认值创建一次
 * （音频类 + volumeInfo 已配置 且非系统应用 = 勾）；之后文件即唯一真相。
 * v5.6：表头 UISearchBar 过滤（应用名/bid，不走 PS nav-search 机制=v4 死循环
 * 根源规避；table 用 KVC 取避开 CI 头差异）+ 应用/系统组件两段分组带数量。
 * v5.7：移除「音量调节」入口段（bid 传参链路不通=闪退 + 与 HUD 滑杆重复；
 * 交互面收敛为 HUD）。
 */
#import "VMPControllers.h"
#import <UIKit/UIKit.h>

@interface VMPWhitelistController () <UISearchBarDelegate>
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, copy) NSString *searchText;
@end

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

    // v5.6 搜索栏（tableHeaderView 挂 UISearchBar；table 用 KVC 取，避开 CI 头差异）
    @try {
        UITableView *tv = [self valueForKey:@"table"];
        if ([tv isKindOfClass:[UITableView class]]) {
            UISearchBar *sb = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, tv.bounds.size.width ?: 320, 44)];
            sb.placeholder = @"搜索应用名或 Bundle ID";
            sb.delegate = self;
            sb.autocorrectionType = UITextAutocorrectionTypeNo;
            sb.autocapitalizationType = UITextAutocapitalizationTypeNone;
            self.searchBar = sb;
            tv.tableHeaderView = sb;
        }
    } @catch (NSException *e) {
        VMPDiagLog(@"whitelist v5: 搜索栏挂载异常 %@", e.name);
    }

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

#pragma mark - 搜索（v5.6）

- (void)searchBar:(UISearchBar *)sb textDidChange:(NSString *)text {
    self.searchText = text;
    [self reloadWhitelist];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)sb {
    [sb resignFirstResponder];
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)sb {
    sb.text = @"";
    self.searchText = nil;
    [sb resignFirstResponder];
    [self reloadWhitelist];
}

// 过滤词匹配：应用名或 bid 大小写不敏感子串；空词 = 全量
- (NSArray<VMPAppEntry *> *)filteredApps {
    NSString *q = [self.searchText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (q.length == 0) return self.apps ?: @[];
    NSMutableArray<VMPAppEntry *> *out = [NSMutableArray array];
    for (VMPAppEntry *e in self.apps) {
        if ([e.name rangeOfString:q options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [e.bid  rangeOfString:q options:NSCaseInsensitiveSearch].location != NSNotFound) {
            [out addObject:e];
        }
    }
    return out;
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

// 开关行构建（v5.6 抽出：应用段 + 系统段各调一次）
- (void)vmp_appendSwitches:(NSMutableArray *)specs
                     apps:(NSArray<VMPAppEntry *> *)list {
    for (VMPAppEntry *e in list) {
        NSString *title = e.name;
        if (e.isSystem) title = [title stringByAppendingString:@"（系统）"];
        if (e.hasAudioMode) title = [@"♪ " stringByAppendingString:title];
        PSSpecifier *sp = [PSSpecifier preferenceSpecifierNamed:title
            target:self set:@selector(setInjectValue:forSpecifier:)
            get:@selector(injectValueForSpecifier:)
            detail:nil cell:PSSwitchCell edit:nil];
        [sp setProperty:e.bid forKey:@"bid"];
        if (e.icon) [sp setProperty:e.icon forKey:@"icon"];
        [specs addObject:sp];
    }
}

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

    // v5.6：过滤 + 两段分组（应用 / 系统组件），段头带数量
    NSArray<VMPAppEntry *> *list = [self filteredApps];
    NSMutableArray<VMPAppEntry *> *userApps = [NSMutableArray array];
    NSMutableArray<VMPAppEntry *> *sysApps = [NSMutableArray array];
    for (VMPAppEntry *e in list) {
        if (e.isSystem) [sysApps addObject:e]; else [userApps addObject:e];
    }

    PSSpecifier *gUser = [PSSpecifier groupSpecifierWithName:
        [NSString stringWithFormat:@"应用（%lu）", (unsigned long)userApps.count]];
    [specs addObject:gUser];
    [self vmp_appendSwitches:specs apps:userApps];
    if (userApps.count == 0) {
        [specs addObject:[PSSpecifier groupSpecifierWithName:@"（无匹配应用）"]];
    }

    PSSpecifier *gSys = [PSSpecifier groupSpecifierWithName:
        [NSString stringWithFormat:@"系统组件（%lu）", (unsigned long)sysApps.count]];
    [specs addObject:gSys];
    [self vmp_appendSwitches:specs apps:sysApps];
    if (sysApps.count == 0) {
        [specs addObject:[PSSpecifier groupSpecifierWithName:@"（无匹配系统组件）"]];
    }

    // v5.7（2026-11-19 实机反馈）：移除「音量调节」入口段——
    //   · push 的音量子页 bid 传参链路不通（volume v5 init: bid=(null)，滑杆写入
    //     nil 键 = 闪退）；
    //   · 且音量调节的正式交互面 = HUD 滑杆（白名单过滤后仅显示勾选应用），
    //     面板内再罗列一份属于重复入口。
    // 保留 VMPVolumeController 类不删（日后若做面板内音量编辑可复用，修 bid 链路）。

    NSMutableArray<NSString *> *en = [self currentEnabled];
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
