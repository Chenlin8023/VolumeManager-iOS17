/*
 * VMPRootListController.m —— 根页（v3 纯 UIKit 自绘）
 * Section 0：总开关（isEnabledManagementAppVolume，引擎热轮询即时生效）
 *            启用混音（vmMixEnabled，引擎 ctor 读取，重启 App 生效）
 * Section 1：应用白名单（push VMPWhitelistController）
 */
#import "VMPControllers.h"

@implementation VMPRootListController

- (instancetype)init {
    // 设置面板观感：内嵌分组样式；PS 的 plain-init 创建路径走这里
    return [self initWithStyle:UITableViewStyleInsetGrouped];
}

- (instancetype)initWithStyle:(UITableViewStyle)style {
    if ((self = [super initWithStyle:style])) {
        self.title = @"音量管理器";
        VMPDiagLog(@"root v3 init: 样式=%lu", (unsigned long)style);
    }
    return self;
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

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *switchId = @"vmpSwitch";
    static NSString *linkId   = @"vmpLink";

    UITableViewCell *cell;
    if (indexPath.section == 0) {
        cell = [tableView dequeueReusableCellWithIdentifier:switchId];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                          reuseIdentifier:switchId];
            UISwitch *sw = [UISwitch new];
            sw.onTintColor = [UIColor systemGreenColor];
            [sw addAction:[UIAction actionWithHandler:^(__kindof UIAction *a) {
                UISwitch *s = (UISwitch *)a.sender;
                NSIndexPath *ip = [self.tableView indexPathForCell:(UITableViewCell *)s.superview.superview];
                if (ip.row == 0) {
                    VMPMasterEnabledWrite(s.on);
                    VMPPostSettingChanged();
                } else {
                    VMPMixEnabledWrite(s.on);
                }
            }] forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        }
        UISwitch *sw = (UISwitch *)cell.accessoryView;
        cell.textLabel.text = indexPath.row == 0 ? @"启用音量管理" : @"启用混音（多应用同播）";
        sw.on = indexPath.row == 0 ? VMPMasterEnabledRead() : VMPMixEnabledRead();
    } else {
        cell = [tableView dequeueReusableCellWithIdentifier:linkId];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                          reuseIdentifier:linkId];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
        cell.textLabel.text = @"应用白名单";
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1 && indexPath.row == 0) {
        VMPWhitelistController *c = [VMPWhitelistController new];
        [self.navigationController pushViewController:c animated:YES];
    }
}

@end
