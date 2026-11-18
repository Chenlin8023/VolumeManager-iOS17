/*
 * VMPVolumeController.m —— 单应用音量滑杆页
 * 上下文来自 push 时的 specifier（bid / appName）。
 * 写 volumeInfo 原格式（读改写保留未知键）+ Preferences 同步副本 + settingOnChanged。
 */
#import "VMPControllers.h"

@implementation VMPVolumeController

- (instancetype)initWithSpecifier:(PSSpecifier *)specifier {
    if ((self = [super initWithSpecifier:specifier])) {
        self.bid = [[specifier propertyForKey:@"bid"] copy];
        self.appName = [[specifier propertyForKey:@"appName"] copy] ?: self.bid;
    }
    return self;
}

- (int)currentPercent {
    NSDictionary *root = VMPVolumeInfoReadMutable();
    BOOL matched = NO;
    double v = VMPVolumeInfoGetVolume(root, self.bid, &matched);
    return (int)round(v * 100.0);
}

- (NSArray *)specifiers {
    if (!_vmpSpecifiers) {
        PSSpecifier *g = [PSSpecifier groupSpecifierWithName:self.appName ?: @"音量"];
        [g setProperty:@"拖动即时生效，引擎 0.5s 轮询兜底；0 = 静音。" forKey:@"footerText"];

        PSSpecifier *slider = [PSSpecifier preferenceSpecifierNamed:@"音量"
            target:self set:@selector(setVolume:forSpecifier:)
            get:@selector(volumeForSpecifier:)
            detail:nil cell:PSSliderCell edit:nil];
        [slider setProperty:@(0) forKey:@"min"];
        [slider setProperty:@(100) forKey:@"max"];
        [slider setProperty:@(self.currentPercent) forKey:@"default"];
        [slider setIdentifier:@"volumeSlider"];

        _vmpSpecifiers = @[ g, slider ];
    }
    return _vmpSpecifiers;
}

- (id)volumeForSpecifier:(PSSpecifier *)spec {
    return @(self.currentPercent);
}

- (void)setVolume:(id)value forSpecifier:(PSSpecifier *)spec {
    if (![value respondsToSelector:@selector(doubleValue)]) return;
    double pct = [value doubleValue];
    if (pct < 0.0) pct = 0.0;
    if (pct > 100.0) pct = 100.0;

    NSMutableDictionary *root = VMPVolumeInfoReadMutable();
    NSMutableDictionary *entry = [root[self.bid] mutableCopy] ?: [NSMutableDictionary dictionary];
    entry[@"volume"] = @(pct / 100.0);
    entry[@"appName"] = self.appName ?: self.bid;
    root[self.bid] = entry;
    VMPVolumeInfoFlush(root);
    VMPPostSettingChanged();
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.title = self.appName ?: @"音量";
}

@end
