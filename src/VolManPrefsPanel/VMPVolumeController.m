/*
 * VMPVolumeController.m —— 音量调节页（v5：PS 原生渲染）
 * 单行：PSSliderCell（get/set selector，0-100）。
 * 上下文由白名单页 push 前注入（bid / appName / volumePercent）。
 * get 在 cell 渲染时回读；set 拖动即写（PS 滑杆每次变更都会调 set——
 * 写入为原子小文件操作，量级可接受）。
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
        VMPDiagLog(@"volume v5 init: bid=%@ 初值=%.0f%%", self.bid, self.volumePercent);
    }
    return self;
}

- (instancetype)initWithSpecifier:(PSSpecifier *)specifier {
    if ((self = [super init])) {
        VMPDiagLog(@"volume v5 initSpec");
    }
    return self;
}

#pragma mark - specifiers

- (NSMutableArray *)vmp_buildSpecifiers {
    NSMutableArray *specs = [NSMutableArray array];
    PSSpecifier *g = [PSSpecifier groupSpecifierWithName:self.appName ?: @"音量"];
    [g setProperty:@"拖动即时生效，引擎 0.5s 轮询兜底；0 = 静音。" forKey:@"footerText"];
    [specs addObject:g];

    PSSpecifier *slider = [PSSpecifier preferenceSpecifierNamed:@"音量"
        target:self set:@selector(setVolumeValue:forSpecifier:)
        get:@selector(volumeValueForSpecifier:)
        detail:nil cell:PSSliderCell edit:nil];
    [slider setProperty:@(0) forKey:@"min"];
    [slider setProperty:@(100) forKey:@"max"];
    [slider setProperty:@(self.volumePercent) forKey:@"default"];
    [specs addObject:slider];
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
        VMPDiagLog(@"volume v5: KVC _specifiers 失败: %@", e);
    }
    return specs;
}

#pragma mark - 滑杆读写（PS get/set 契约）

- (id)volumeValueForSpecifier:(PSSpecifier *)spec {
    return @(self.volumePercent);
}

- (void)setVolumeValue:(id)value forSpecifier:(PSSpecifier *)spec {
    if (![value respondsToSelector:@selector(doubleValue)]) return;
    double pct = [value doubleValue];
    if (pct < 0.0) pct = 0.0;
    if (pct > 100.0) pct = 100.0;
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
