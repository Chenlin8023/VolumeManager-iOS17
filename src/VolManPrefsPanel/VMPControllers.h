/*
 * VMPControllers.h —— v5 架构（2026-11-19）：纯 PS 原生渲染。
 *
 * 证据链闭环（v2→v4.4 六轮实机）：
 *   · v3 纯 UITableViewController → setRootController: 闪退（PS 契约要求 PS 家族基类）
 *   · v4/v4.1/v4.2 壳+自绘（loadView 替换视图）→ 导航栏半初始化搜索栏布局死循环
 *     （hang .ips 主线程栈实锤：_UISearchBarLayout prepareBaseConfigurationForSublayout
 *      → objc_msgSend 死循环烧 CPU）
 *   · v2 空表真因 = specifiers 只写了自定义 ivar，基类 _specifiers 从未填充
 *   · 闭源面板（iOS 17 实证可用）= PSListController + 代码构建 specifiers +
 *     从不碰 loadView → PS 自己建表、自己的 delegate 方法读已填充的 ivar
 *
 * v5 = 该实证形态的复刻：
 *   · 基类 PSListController，不碰 loadView/viewDidLoad 的 PS 职责（viewDidLoad 调 super）
 *   · specifiers 构建后 KVC 写基类 _specifiers ivar（mutableCopy）
 *   · 开关行绑 defaults 域（PS 原生读写+通知）或 get/set selector（直写文件）
 *   · 白名单行 get/set 走 VMPWhitelistRead/Write（引擎零改动）
 *   · 音量行 PSSliderCell get/set selector
 */
#import "VMPShared.h"
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <objc/message.h>

@interface VMPRootListController : PSListController
@end

@interface VMPWhitelistController : PSListController
@property (nonatomic, strong) NSArray<VMPAppEntry *> *apps;
@property (nonatomic, assign) BOOL scanned;
@property (nonatomic, assign) BOOL seeding;
@end

@interface VMPVolumeController : PSListController
@property (nonatomic, copy) NSString *bid;
@property (nonatomic, copy) NSString *appName;
@property (nonatomic, assign) double volumePercent;
@end
