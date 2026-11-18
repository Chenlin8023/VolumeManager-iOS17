/*
 * VMPWhitelistController.m —— 应用白名单页（v3 纯 UIKit 自绘）
 * Section 0：每个应用一行（图标 + 名称 + 注入开关 UISwitch）
 * Section 1：已启用应用的音量调节入口（点击 push 滑杆页）
 * 种子语义：白名单文件不存在时，首次进入按默认值创建一次
 * （音频类 + volumeInfo 已配置 且非系统应用 = 勾）；之后文件即唯一真相。
 */
#import "VMPControllers.h"

@implementation VMPWhitelistController

- (instancetype)init {
    return [self initWithStyle:UITableViewStyleInsetGrouped];
}

- (instancetype)initWithStyle:(UITableViewStyle)style {
    if ((self = [super initWithStyle:style])) {
        self.title = @"应用白名单";
        VMPDiagLog(@"whitelist v3 init");
    }
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

    VMPDiagLog(@"whitelist: 开始扫描（首建补种=%d）", self.seeding);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<VMPAppEntry *> *apps = VMPScanApps();
        dispatch_async(dispatch_get_main_queue(), ^{
            self.apps = apps;
            [self finishSeedingIfNeeded];
            [self.tableView reloadData];
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

#pragma mark - 数据

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return MAX(1, (NSInteger)self.apps.count);
    return MAX(1, (NSInteger)[self enabledApps].count);
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) {
        if (!VMPMasterEnabledRead()) return @"应用白名单（⚠ 总开关已关闭，白名单不生效）";
        return @"应用白名单";
    }
    return @"音量调节";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) {
        return @"勾选 = 引擎对该应用装载音量挂钩与混音；不勾 = 完全不注入。"
               @"系统应用默认不勾选。改动需重启对应应用生效。";
    }
    return @"点按行进入滑杆，音量即时生效（0 = 静音）；未列出的应用音量为 1.0。";
}

- (NSArray<VMPAppEntry *> *)enabledApps {
    NSMutableArray<VMPAppEntry *> *a = [NSMutableArray array];
    NSMutableArray<NSString *> *en = [self currentEnabled];
    for (VMPAppEntry *e in self.apps) {
        if ([en containsObject:e.bid]) [a addObject:e];
    }
    return a;
}

#pragma mark - 行

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *appCellId   = @"vmpApp";
    static NSString *volumeCellId = @"vmpVolumeLink";

    UITableViewCell *cell;
    if (indexPath.section == 0) {
        cell = [tableView dequeueReusableCellWithIdentifier:appCellId];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                          reuseIdentifier:appCellId];
            UISwitch *sw = [UISwitch new];
            sw.onTintColor = [UIColor systemGreenColor];
            [sw addAction:[UIAction actionWithHandler:^(__kindof UIAction *a) {
                UISwitch *s = (UISwitch *)a.sender;
                NSIndexPath *ip = [self.tableView indexPathForCell:(UITableViewCell *)s.superview.superview];
                VMPAppEntry *e = (ip.row < (NSInteger)self.apps.count) ? self.apps[ip.row] : nil;
                if (!e) return;
                NSMutableArray *en = [self currentEnabled];
                if (s.on) {
                    if (![en containsObject:e.bid]) [en addObject:e.bid];
                } else {
                    [en removeObject:e.bid];
                }
                VMPWhitelistWrite([en copy]);
                VMPDiagLog(@"whitelist: %@ → %@", e.bid, s.on ? @"开" : @"关");
                [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1]
                              withRowAnimation:UITableViewRowAnimationNone];
            }] forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        }
        if (indexPath.row < (NSInteger)self.apps.count) {
            VMPAppEntry *e = self.apps[indexPath.row];
            NSString *title = e.name;
            if (e.isSystem) title = [title stringByAppendingString:@"（系统）"];
            if (e.hasAudioMode) title = [@"♪ " stringByAppendingString:title];
            cell.textLabel.text = title;
            cell.detailTextLabel.text = e.bid;
            cell.imageView.image = e.icon;
            ((UISwitch *)cell.accessoryView).on =
                [[self currentEnabled] containsObject:e.bid];
        }
    } else {
        cell = [tableView dequeueReusableCellWithIdentifier:volumeCellId];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                          reuseIdentifier:volumeCellId];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
        NSArray<VMPAppEntry *> *enabledApps = [self enabledApps];
        if (indexPath.row < (NSInteger)enabledApps.count) {
            cell.textLabel.text = enabledApps[indexPath.row].name;
        } else {
            cell.textLabel.text = @"（暂无已启用的应用）";
        }
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
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
