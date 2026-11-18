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
    tv.dataSource = self;
    tv.delegate = self;
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

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [_vmpTable reloadData];   // 开关状态回流（从别的页面回来时刷新）
}

#pragma mark - 数据

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 2;
    return 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return section == 0
        ? @"总开关关闭时，所有应用的音量调整与混音全部停止。混音开关在应用下次启动时生效。"
        : @"勾选 = 引擎对该应用装载音量挂钩与混音；不勾 = 完全不注入。";
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
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

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        return indexPath.row == 0 ? [self masterCell:tableView] : [self mixCell:tableView];
    }
    return [self whitelistCell:tableView];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1 && indexPath.row == 0) {
        VMPWhitelistController *c = [VMPWhitelistController new];
        [self.navigationController pushViewController:c animated:YES];
    }
}

@end
