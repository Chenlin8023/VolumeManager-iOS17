/*
 * VMPControllers.h —— v4 架构（2026-11-19）：PSListController 壳 + 纯 UIKit 自绘内容。
 *
 * 证据链闭环：
 *   · v3 纯 UITableViewController → PS 创建后调 setRootController:（PS 家族属性）
 *     unrecognized selector 闪退 → detail 控制器必须继承 PSListController
 *   · v2 PSListController + specifier 渲染 → 三轮实验（getter 覆写/KVC ivar/
 *     setSpecifiers/截流）全部到位仍空表 → PS 的 specifier 渲染流不可见
 *   · v4 = 壳（继承提供 PS 全部机器方法）+ loadView 自绘 UITableView
 *     （自家 dataSource/delegate，PS specifier 机制全部旁路）
 * 防御性覆盖：setSpecifiers:/reloadSpecifiers/loadSpecifiersFromPlistName: →
 *   不破坏自绘表（PS 内部若触碰 specifier 机制，一律无害化）。
 */
#import "VMPShared.h"
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <objc/message.h>

// ── 自绘表中介（v4.1，2026-11-19）─────────────────────────────────────────
// 铁证：自绘表 delegate=self（PSListController 子类）时，PSListController 自己
// 实现的 UITableViewDelegate 方法（iOS 17 的 titleAlignmentForHeaderInSection
// 等）会读它内部 specifiers 数组（空）→ NSRangeException。
// 中介 = 纯 NSObject 实现完整协议面，转发到控制器的 vmp_* 前缀方法
// （PS 永不实现这些名字）→ delegate 回调彻底脱离 PS 实现。
@protocol VMPTableSource <NSObject>
@required
- (NSInteger)vmp_numberOfSections;
- (NSInteger)vmp_numberOfRowsInSection:(NSInteger)section;
- (UITableViewCell *)vmp_cellForIndexPath:(NSIndexPath *)indexPath;
@optional
- (NSString *)vmp_titleForHeader:(NSInteger)section;
- (NSString *)vmp_titleForFooter:(NSInteger)section;
- (void)vmp_didSelectRowAtIndexPath:(NSIndexPath *)indexPath;
@end

@interface VMPTableMediator : NSObject <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, weak) id<VMPTableSource> owner;
@end

@interface VMPRootListController : PSListController <VMPTableSource> {
    UITableView *_vmpTable;
}
@end

@interface VMPWhitelistController : PSListController <VMPTableSource> {
    UITableView *_vmpTable;
}
@property (nonatomic, strong) NSArray<VMPAppEntry *> *apps;
@property (nonatomic, strong) NSMutableArray<NSString *> *enabled;
@property (nonatomic, assign) BOOL scanned;
@property (nonatomic, assign) BOOL seeding;
@end

@interface VMPVolumeController : PSListController <VMPTableSource> {
    UITableView *_vmpTable;
}
@property (nonatomic, copy) NSString *bid;
@property (nonatomic, copy) NSString *appName;
@property (nonatomic, assign) double volumePercent;
@end
