/*
 * VMPRootListController.m —— 根页（v4：PSListController 壳 + 自绘表）
 * Section 0：总开关（isEnabledManagementAppVolume，引擎热轮询即时生效）
 *            启用混音（vmMixEnabled，引擎 ctor 读取，重启 App 生效）
 * Section 1：应用白名单（push VMPWhitelistController）
 */
#import "VMPControllers.h"

@implementation VMPRootListController

// PS 的 plain-init 创建路径（v2 diag 实锤：入口创建走 plain init）
- (instancetype)init {
    if ((self = [super init])) {
        VMPDiagHierarchy(self, @"root-plain-init");
    }
    return self;
}

// PS 契约：controllerForSpecifier: 可能走 initWithSpecifier:（无设防）
- (instancetype)initWithSpecifier:(PSSpecifier *)specifier {
    if ((self = [super init])) {
        VMPDiagHierarchy(self, @"root-initSpec");
    }
    return self;
}

// v4 核心：loadView 自绘表（PS 的 specifier 表格完全旁路）
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
    // 基类的 table 属性同步指向自绘表（PS 内部若触碰则作用于自绘表）
    @try { [self setValue:tv forKey:@"table"]; } @catch (NSException *e) { }
    VMPDiagLog(@"root loadView: 自绘表就绪");
}

// ── 防御性覆盖：PS 内部触碰 specifier 机制时不破坏自绘表 ──
- (void)setSpecifiers:(NSMutableArray *)specifiers { /* 忽略 */ }
- (void)reloadSpecifiers { [_vmpTable reloadData]; }
- (NSMutableArray *)loadSpecifiersFromPlistName:(NSString *)name target:(PSListController *)target bundle:(NSBundle *)bundle {
    return [NSMutableArray new];
}
- (NSMutableArray *)loadSpecifiersFromPlistName:(NSString *)name target:(PSListController *)target {
    return [NSMutableArray new];
}

// v4.2：覆盖 viewDidLoad 且不调 super——基类实现内含 PS 内部工作（上一份
// hang .ips：主线程用户态 CPU 空转 9 秒，基类 viewDidLoad 是主线程上最后
// 一个已确认的 PS 入口）。自绘表在 loadView 已就绪， reloadData 由本类负责。
- (void)viewDidLoad {
    VMPDiagLog(@"root viewDidLoad: 进入（跳过基类）");
}

- (void)viewWillAppear:(BOOL)animated {
    VMPDiagLog(@"root viewWillAppear: super 前");
    [super viewWillAppear:animated];
    VMPDiagLog(@"root viewWillAppear: super 后");
    VMPDiagLog(@"root viewWillAppear: reloadData 前");
    [_vmpTable reloadData];
    VMPDiagLog(@"root viewWillAppear: reloadData 后");
    // 心跳：判明卡死时主 runloop 是否存活（活着=渲染层问题；停跳=主线程阻塞）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        VMPDiagLog(@"root 心跳 1s：主 runloop 存活");
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        VMPDiagLog(@"root 心跳 3s：主 runloop 存活");
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        VMPDiagLog(@"root 心跳 6s：主 runloop 存活");
    });
}

- (void)viewDidAppear:(BOOL)animated {
    VMPDiagLog(@"root viewDidAppear: 进入");
    [super viewDidAppear:animated];
    VMPDiagLog(@"root viewDidAppear: 返回");
}

#pragma mark - 数据

- (NSInteger)vmp_numberOfSections {
    return 2;
}

- (NSInteger)vmp_numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 2;
    return 1;
}

- (NSString *)vmp_titleForFooter:(NSInteger)section {
    return section == 0
        ? @"总开关关闭时，所有应用的音量调整与混音全部停止。混音开关在应用下次启动时生效。"
        : @"勾选 = 引擎对该应用装载音量挂钩与混音；不勾 = 完全不注入。";
}

- (NSString *)vmp_titleForHeader:(NSInteger)section {
    return section == 0 ? @"音量管理" : @"应用";
}

#pragma mark - 行

- (UITableViewCell *)masterCell:(UITableView *)tv {
    static NSString *id = @"vmpMaster";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:id];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:id];
        UISwitch *sw = [UISwitch new];
        sw.onTintColor = [UIColor systemGreenColor];
        [sw addTarget:self action:@selector(masterToggled:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
    }
    cell.textLabel.text = @"启用音量管理";
    ((UISwitch *)cell.accessoryView).on = VMPMasterEnabledRead();
    return cell;
}

- (UITableViewCell *)mixCell:(UITableView *)tv {
    static NSString *id = @"vmpMix";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:id];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:id];
        UISwitch *sw = [UISwitch new];
        sw.onTintColor = [UIColor systemGreenColor];
        [sw addTarget:self action:@selector(mixToggled:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
    }
    cell.textLabel.text = @"启用混音（多应用同播）";
    ((UISwitch *)cell.accessoryView).on = VMPMixEnabledRead();
    return cell;
}

- (UITableViewCell *)whitelistCell:(UITableView *)tv {
    static NSString *id = @"vmpWhitelistLink";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:id];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:id];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    cell.textLabel.text = @"应用白名单";
    return cell;
}

- (void)masterToggled:(UISwitch *)sw {
    VMPMasterEnabledWrite(sw.on);
    VMPPostSettingChanged();
}
- (void)mixToggled:(UISwitch *)sw {
    VMPMixEnabledWrite(sw.on);
}

static int vmp_cellLogs = 0;
- (UITableViewCell *)vmp_cellForIndexPath:(NSIndexPath *)indexPath {
    if (vmp_cellLogs < 6) {
        VMPDiagLog(@"root cellForRow: section=%ld row=%ld", (long)indexPath.section, (long)indexPath.row);
        vmp_cellLogs++;
    }
    if (indexPath.section == 0) {
        return indexPath.row == 0 ? [self masterCell:_vmpTable] : [self mixCell:_vmpTable];
    }
    return [self whitelistCell:_vmpTable];
}

- (void)vmp_didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [_vmpTable deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1 && indexPath.row == 0) {
        VMPWhitelistController *c = [VMPWhitelistController new];
        [self.navigationController pushViewController:c animated:YES];
    }
}

@end
