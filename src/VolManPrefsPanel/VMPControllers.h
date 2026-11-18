/*
 * VMPControllers.h —— v3 架构（2026-11-19）：弃用 PSListController。
 *
 * 三轮实机证据：PS 的 plain-init 创建路径 ✓、类层级 ✓、KVC 直写 _specifiers ✓、
 * setSpecifiers ✓、reloadSpecifiers ✓、plist 加载截流（从未被走到）——全部到位
 * 表格仍然空。iOS 17 PSListController 内部加载流对我们不可见，继续考古成本失控。
 *
 * 改为纯 UITableViewController 自绘（Settings 导航栈接受任意 UIViewController）：
 *   · 业务逻辑层 VMPShared 一行不动（扫描/读写/通知）
 *   · 开关 = UISwitch（UIAction，iOS 14+），滑杆 = UISlider
 *   · 图标/名称/页脚 = 标准 UITableViewCell
 *   · 创建路径不变：NSPrincipalClass → plain init（已实锤）
 */
#import "VMPShared.h"
#import <objc/message.h>

@interface VMPRootListController : UITableViewController
@end

@interface VMPWhitelistController : UITableViewController
@property (nonatomic, strong) NSArray<VMPAppEntry *> *apps;
@property (nonatomic, strong) NSMutableArray<NSString *> *enabled;
@property (nonatomic, assign) BOOL scanned;
@property (nonatomic, assign) BOOL seeding;
@end

@interface VMPVolumeController : UITableViewController
@property (nonatomic, copy) NSString *bid;
@property (nonatomic, copy) NSString *appName;
@property (nonatomic, assign) double volumePercent;
@end
