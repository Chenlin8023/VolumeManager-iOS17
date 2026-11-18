/*
 * VMPTableMediator.m —— 自绘表中介（v4.1）
 * 纯 NSObject 实现 UITableViewDataSource/Delegate 完整协议面，
 * 转发到 owner 的 vmp_* 前缀方法。存在意义：PSListController 自身实现了
 * UITableViewDelegate 的部分方法（titleAlignmentForHeaderInSection 等），
 * 自绘表若以 PSListController 子类为 delegate，表格 reload 会调进 PS 实现
 * 并读其内部空 specifiers 数组 → NSRangeException（实机 .ips 铁证）。
 */
#import "VMPControllers.h"

@implementation VMPTableMediator

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return [self.owner vmp_numberOfSections];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self.owner vmp_numberOfRowsInSection:section];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    return [self.owner vmp_cellForIndexPath:indexPath];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if ([self.owner respondsToSelector:@selector(vmp_titleForHeader:)])
        return [self.owner vmp_titleForHeader:section];
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if ([self.owner respondsToSelector:@selector(vmp_titleForFooter:)])
        return [self.owner vmp_titleForFooter:section];
    return nil;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([self.owner respondsToSelector:@selector(vmp_didSelectRowAtIndexPath:)])
        [self.owner vmp_didSelectRowAtIndexPath:indexPath];
}

@end
