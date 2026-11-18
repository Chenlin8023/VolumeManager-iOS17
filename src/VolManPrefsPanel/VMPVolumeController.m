/*
 * VMPVolumeController.m —— 单应用音量滑杆页（v4：PSListController 壳 + 自绘表）
 * 一行：UISlider（0-100）。上下文由白名单页 push 前注入（bid / appName）。
 * 写入节流：ValueChanged 只更新内存值，EditingDidEnd 落盘+通知（避免拖动期间
 * 每秒几十次文件写）。
 */
#import "VMPControllers.h"

@implementation VMPVolumeController

- (instancetype)init {
    if ((self = [super init])) {
        NSDictionary *root = VMPVolumeInfoReadMutable();
        BOOL matched = NO;
        double v = VMPVolumeInfoGetVolume(root, self.bid, &matched);
        self.volumePercent = round(v * 100.0);
        self.title = self.appName ?: @"音量";
        VMPDiagLog(@"volume init: bid=%@ 初值=%.0f%%", self.bid, self.volumePercent);
    }
    return self;
}

- (instancetype)initWithSpecifier:(PSSpecifier *)specifier {
    if ((self = [super init])) {
        VMPDiagHierarchy(self, @"volume-initSpec");
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
    VMPDiagLog(@"volume loadView: 自绘表就绪");
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

#pragma mark - 数据

- (NSInteger)vmp_numberOfSections {
    return 1;
}

- (NSInteger)vmp_numberOfRowsInSection:(NSInteger)section {
    return 1;
}

- (NSString *)vmp_titleForFooter:(NSInteger)section {
    return @"拖动即时生效（松手落盘），引擎 0.5s 轮询兜底；0 = 静音。";
}

#pragma mark - 行

- (UITableViewCell *)vmp_cellForIndexPath:(NSIndexPath *)indexPath {
    static NSString *id = @"vmpSliderRow";
    UITableViewCell *cell = [_vmpTable dequeueReusableCellWithIdentifier:id];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                      reuseIdentifier:id];
        UISlider *sl = [UISlider new];
        sl.frame = CGRectMake(0, 0, 180, 30);
        sl.minimumValue = 0;
        sl.maximumValue = 100;
        sl.tintColor = [UIColor systemBlueColor];
        // 拖动中：只更新内存值
        [sl addTarget:self action:@selector(sliderLiveChanged:)
             forControlEvents:UIControlEventValueChanged];
        // 松手：落盘 + 通知
        [sl addTarget:self action:@selector(sliderSettled:)
             forControlEvents:UIControlEventEditingDidEnd | UIControlEventTouchUpInside];
        cell.accessoryView = sl;
    }
    ((UISlider *)cell.accessoryView).value = (float)self.volumePercent;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%.0f%%", self.volumePercent];
    return cell;
}

- (void)sliderLiveChanged:(UISlider *)sl {
    self.volumePercent = round(sl.value);
}

- (void)sliderSettled:(UISlider *)sl {
    double pct = round(sl.value);
    self.volumePercent = pct;
    NSMutableDictionary *root = VMPVolumeInfoReadMutable();
    NSMutableDictionary *entry = [root[self.bid] mutableCopy]
                                 ?: [NSMutableDictionary dictionary];
    entry[@"volume"] = @(pct / 100.0);
    entry[@"appName"] = self.appName ?: self.bid;
    root[self.bid] = entry;
    VMPVolumeInfoFlush(root);
    VMPPostSettingChanged();
    VMPDiagLog(@"volume: %@ → %.0f%%（落盘）", self.bid, pct);
}

@end
