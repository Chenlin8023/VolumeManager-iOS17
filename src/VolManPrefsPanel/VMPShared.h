/*
 * VMPShared.h —— VolManPrefsPanel 公共层（v2.0 步骤③，docs/05 §五）
 *
 * 与引擎的契约：volumeInfo.plist（原格式）、appwhitelist.plist（三态裁决输入）、
 * vmMix 配置（vmMixEnabled）、prefs 域 com.sunshinesong.volume-manager-prefs
 * （isEnabledManagementAppVolume 总开关）、Darwin 通知 settingOnChanged。
 * 全部走直接文件读写（闭源面板同款机制；引擎按文件 mtime 轮询）。
 * 写入一律双写：jbroot 数据目录（引擎主路径）+ Preferences 同步副本（沙箱兜底）。
 */
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// ── 路径 ──────────────────────────────────────────────────────────────────
NSArray<NSString *> *VMPDataDirs(void);
NSString *VMPWhitelistDataPath(void);      // <数据目录>/appwhitelist.plist（引擎主路径）
NSString *VMPWhitelistSyncedPath(void);    // Preferences 同步副本（沙箱 App 兜底）
NSString *VMPVolumeDataPath(void);         // <数据目录>/volumeInfo.plist
NSString *VMPVolumeSyncedPath(void);       // Preferences 同步副本
NSString *VMPMixDataPath(void);            // <数据目录>/mixInfo.plist
NSString *VMPMixSyncedPath(void);          // Preferences 同步副本
NSString *VMPSunPrefsPath(void);           // com.sunshinesong.volume-manager-prefs.plist（总开关）

BOOL VMPWritePlist(id plist, NSString *path);

// ── 总开关（prefs 域，直接文件写——闭源面板同款，引擎按 mtime 轮询） ──────
BOOL VMPMasterEnabledRead(void);
BOOL VMPMasterEnabledWrite(BOOL enabled);

// ── 混音（vmMixEnabled；引擎 ctor 读取，改后重启 App 生效） ───────────────
BOOL VMPMixEnabledRead(void);
BOOL VMPMixEnabledWrite(BOOL enabled);

// ── 白名单（引擎 ctor 三态裁决输入；缺失=legacy 兼容模式） ─────────────────
NSArray<NSString *> *VMPWhitelistRead(void);
BOOL VMPWhitelistWrite(NSArray<NSString *> *enabled);

// ── volumeInfo（原格式 <bid>:{volume,appName}；读改写保留未知键） ──────────
NSMutableDictionary *VMPVolumeInfoReadMutable(void);
BOOL VMPVolumeInfoFlush(NSDictionary *root);              // 双写落盘
double VMPVolumeInfoGetVolume(NSDictionary *root, NSString *bid, BOOL *matched);

// ── 通知 ──────────────────────────────────────────────────────────────────
void VMPPostSettingChanged(void);

// ── 诊断（面板排障专用；写数据目录 vmp-panel-diag.log，Settings 可写） ────
void VMPDiagLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

// ── 扫描 ──────────────────────────────────────────────────────────────────
@interface VMPAppEntry : NSObject
@property (nonatomic, copy) NSString *bid;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong, nullable) UIImage *icon;
@property (nonatomic, assign) BOOL isSystem;      // bundleURL 位于 /System/ 下
@property (nonatomic, assign) BOOL hasAudioMode;  // UIBackgroundModes 含 audio
@property (nonatomic, assign) BOOL configured;    // volumeInfo 已有条目
@end

// 同步扫描（调用方自行 dispatch_async）；返回按名称排序的全量列表
NSArray<VMPAppEntry *> *VMPScanApps(void);

NS_ASSUME_NONNULL_END
