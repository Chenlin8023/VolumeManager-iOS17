/*
 * VMPVolumeController.m —— 单应用音量滑杆页（v3 纯 UIKit 自绘）
 * 一行：UISlider（0-100），拖动即时写 volumeInfo（原格式）+ 同步副本 + 通知。
 * 上下文由白名单页 push 前注入（bid / appName / volumePercent）。
 */
#import "VMPControllers.h"

@implementation VMPVolumeController

- (instancetype)init {
    return [self initWithStyle:UITableViewStyleInsetGrouped];
}

- (instancetype)initWithStyle:(UITableViewStyle)style {
    if ((self = [super initWithStyle:style])) {
        self.title = self.appName ?: @"音量";
        NSDictionary *root = VMPVolumeInfoReadMutable();
        BOOL matched = NO;
        double v = VMPVolumeInfoGetVolume(root, self.bid, &matched);
        self.volumePercent = round(v * 100.0);
        VMPDiagLog(@"volume v3 init: bid=%@ 初值=%.0f%%", self.bid, self.volumePercent);
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
}

#pragma mark - 数据

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"拖动即时生效，引擎 0.5s 轮询兜底；0 = 静音。";
}

#pragma mark - 行

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *sliderId = @"vmpSlider";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:sliderId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                      reuseIdentifier:sliderId];
        UISlider *sl = [UISlider new];
        sl.frame = CGRectMake(0, 0, 180, 30);
        sl.minimumValue = 0;
        sl.maximumValue = 100;
        sl.tintColor = [UIColor systemBlueColor];
        [sl addAction:[UIAction actionWithHandler:^(__kindof UIAction *a) {
            UISlider *s = (UISlider *)a.sender;
            double pct = round(s.value);
            self.volumePercent = pct;
            NSMutableDictionary *root = VMPVolumeInfoReadMutable();
            NSMutableDictionary *entry = [root[self.bid] mutableCopy]
                                         ?: [NSMutableDictionary dictionary];
            entry[@"volume"] = @(pct / 100.0);
            entry[@"appName"] = self.appName ?: self.bid;
            root[self.bid] = entry;
            VMPVolumeInfoFlush(root);
            VMPPostSettingChanged();
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%.0f%%", pct];
        }] forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sl;
    }
    ((UISlider *)cell.accessoryView).value = (float)self.volumePercent;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%.0f%%", self.volumePercent];
    return cell;
}

@end
