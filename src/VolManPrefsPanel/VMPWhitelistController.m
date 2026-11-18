/*
 * VMPWhitelistController.m —— 应用白名单页（v4：PSListController 壳 + 自绘表）
 * Section 0：每个应用一行（图标 + 名称 + bid + 注入开关 UISwitch）
 * Section 1：已启用应用的音量调节入口（push 滑杆页）
 * 种子语义：白名单文件不存在时，首次进入按默认值创建一次
 * （音频类 + volumeInfo 已配置 且非系统应用 = 勾）；之后文件即唯一真相。
 * 开关行用 tag 定位（cell 复用时 tag 随行更新，handler 读 self.apps[tag]）。
 */
#import "VMPControllers.h"

@implementation VMPWhitelistController

- (instancetype)init {
    if ((self = [super init])) {
        VMPDiagHierarchy(self, @"whitelist-plain-init");
    }
    return self;
}

- (instancetype)initWithSpecifier:(PSSpecifier *)specifier {
    if ((self = [super init])) {
        VMPDiagHierarchy(self, @"whitelist-initSpec");
    }
    return self;
}

- (void)loadView {
    UITableView *tv = [[UITableView alloc] initWithFrame:CGRectZero
                                                   style:UITableViewStyleInsetGrouped];
    VMPTableMediator *med = [VMPTableMediator new];
    med.owner = self;
    tv.dataSource = med;
    tv.delegate = med;

    tv.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.view = tv;
    _vmpTable = tv;
    @try { [self setValue:tv forKey:@"table"]; } @catch (NSException *e) { }
    self.title = @"应用白名单";
    VMPDiagLog(@"whitelist loadView: 自绘表就绪");
}

// 防御性覆盖（同根页）
- (void)setSpecifiers:(NSMutableArray *)specifiers { /* 忽略 */ }
- (void)reloadSpecifiers { [_vmpTable reloadData]; }
- (NSMutableArray *)loadSpecifiersFromPlistName:(NSString *)name target:(PSListController *)target bundle:(NSBundle *)bundle {
    return [NSMutableArray new];
}
- (NSMutableArray *)loadSpecifiersFromPlistName:(NSString *)name target:(PSListController *)target {
    return [NSMutableArray new];
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

    VMPDiagLog(@"whitelist: 开始扫描（首建补种=%d）", self.seeding);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<VMPAppEntry *> *apps = VMPScanApps();
        dispatch_async(dispatch_get_main_queue(), ^{
            self.apps = apps;
            [self finishSeedingIfNeeded];
            [_vmpTable reloadData];
            VMPDiagLog(@"whitelist: 扫描完成 %lu 项", (unsigned long)apps.count);
        });
    });
}

// 首建补种：音频类 + 已配置 且非系统应用 → 勾（文件从此存在 → 引擎进入白名单模式）
- (void)finishSeedingIfNeeded {
    if (!self.seeding) return;
    self.enabled = [VMPWhitelistRead() mutableCopy];
    NSDictionary *vol = VMPVolumeInfoReadMutable();
    for (VMPAppEntry *e in self.apps) {
        BOOL defaultOn = (!e.isSystem && (e.hasAudioMode || vol[e.bid] != nil));
        if (defaultOn && ![self.enabled containsObject:e.bid]) [self.enabled addObject:e.bid];
    }
    VMPWhitelistWrite([self.enabled copy]);
    VMPDiagLog(@"whitelist: 首建补种完成 %lu 项", (unsigned long)self.enabled.count);
}

- (NSMutableArray<NSString *> *)currentEnabled {
    if (self.enabled) return self.enabled;
    self.enabled = [VMPWhitelistRead() mutableCopy];
    return self.enabled;
}

- (NSArray<VMPAppEntry *> *)enabledApps {
    NSMutableArray<VMPAppEntry *> *a = [NSMutableArray array];
    NSMutableArray<NSString *> *en = [self currentEnabled];
    for (VMPAppEntry *e in self.apps) {
        if ([en containsObject:e.bid]) [a addObject:e];
    }
    return a;
}

#pragma mark - 数据

- (NSInteger)vmp_numberOfSections {
    return 2;
}

- (NSInteger)vmp_numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return MAX(1, (NSInteger)self.apps.count);
    return MAX(1, (NSInteger)[self enabledApps].count);
}

- (NSString *)vmp_titleForHeader:(NSInteger)section {
    if (section == 0) {
        if (!VMPMasterEnabledRead()) return @"应用白名单（⚠ 总开关已关闭，白名单不生效）";
        return @"应用白名单";
    }
    return @"音量调节";
}

- (NSString *)vmp_titleForFooter:(NSInteger)section {
    if (section == 0) {
        return @"勾选 = 引擎对该应用装载音量挂钩与混音；不勾 = 完全不注入。"
               @"系统应用默认不勾选。改动需重启对应应用生效。";
    }
    return @"点按行进入滑杆，音量即时生效（0 = 静音）；未列出的应用音量为 1.0。";
}

#pragma mark - 行

- (UITableViewCell *)appCell:(UITableView *)tv row:(NSInteger)row {
    static NSString *id = @"vmpApp";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:id];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:id];
        UISwitch *sw = [UISwitch new];
        sw.onTintColor = [UIColor systemGreenColor];
        [sw addTarget:self action:@selector(injectToggled:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
    }
    VMPAppEntry *e = (row < (NSInteger)self.apps.count) ? self.apps[row] : nil;
    if (!e) {
        cell.textLabel.text = @"（扫描中…）";
        cell.detailTextLabel.text = nil;
        cell.imageView.image = nil;
        ((UISwitch *)cell.accessoryView).hidden = YES;
        return cell;
    }
    ((UISwitch *)cell.accessoryView).hidden = NO;
    ((UISwitch *)cell.accessoryView).tag = row;
    NSString *title = e.name;
    if (e.isSystem) title = [title stringByAppendingString:@"（系统）"];
    if (e.hasAudioMode) title = [@"♪ " stringByAppendingString:title];
    cell.textLabel.text = title;
    cell.detailTextLabel.text = e.bid;
    cell.imageView.image = e.icon;
    ((UISwitch *)cell.accessoryView).on = [[self currentEnabled] containsObject:e.bid];
    return cell;
}

- (UITableViewCell *)volumeLinkCell:(UITableView *)tv row:(NSInteger)row {
    static NSString *id = @"vmpVolumeLink";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:id];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:id];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    NSArray<VMPAppEntry *> *enabledApps = [self enabledApps];
    if (row < (NSInteger)enabledApps.count) {
        cell.textLabel.text = enabledApps[row].name;
    } else {
        cell.textLabel.text = @"（暂无已启用的应用）";
    }
    return cell;
}

- (UITableViewCell *)vmp_cellForIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        return [self appCell:_vmpTable row:indexPath.row];
    }
    return [self volumeLinkCell:_vmpTable row:indexPath.row];
}

- (void)injectToggled:(UISwitch *)sw {
    NSInteger row = sw.tag;
    if (row >= (NSInteger)self.apps.count) return;
    VMPAppEntry *e = self.apps[row];
    NSMutableArray *en = [self currentEnabled];
    if (sw.on) {
        if (![en containsObject:e.bid]) [en addObject:e.bid];
    } else {
        [en removeObject:e.bid];
    }
    VMPWhitelistWrite([en copy]);
    VMPDiagLog(@"whitelist: %@ → %@", e.bid, sw.on ? @"开" : @"关");
    // 音量调节段跟随勾选变化
    NSIndexSet *sec = [NSIndexSet indexSetWithIndex:1];
    [_vmpTable reloadSections:sec withRowAnimation:UITableViewRowAnimationNone];
}

- (void)vmp_didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [_vmpTable deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 1) return;
    NSArray<VMPAppEntry *> *enabledApps = [self enabledApps];
    if (indexPath.row >= (NSInteger)enabledApps.count) return;
    VMPAppEntry *e = enabledApps[indexPath.row];

    VMPVolumeController *c = [VMPVolumeController new];
    c.bid = e.bid;
    c.appName = e.name;
    [self.navigationController pushViewController:c animated:YES];
}

@end
