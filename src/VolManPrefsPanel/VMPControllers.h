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
#import <objc/message.h>

@interface VMPRootListController : PSListController {
    UITableView *_vmpTable;
}
@end

@interface VMPWhitelistController : PSListController {
    UITableView *_vmpTable;
}
@property (nonatomic, strong) NSArray<VMPAppEntry *> *apps;
@property (nonatomic, strong) NSMutableArray<NSString *> *enabled;
@property (nonatomic, assign) BOOL scanned;
@property (nonatomic, assign) BOOL seeding;
@end

@interface VMPVolumeController : PSListController {
    UITableView *_vmpTable;
}
@property (nonatomic, copy) NSString *bid;
@property (nonatomic, copy) NSString *appName;
@property (nonatomic, assign) double volumePercent;
@end
