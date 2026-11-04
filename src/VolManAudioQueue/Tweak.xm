/*
 * VolManAudioQueue v1.3.0 —— VolumeManager「每 App 音量」模块重写版
 * ============================================================================
 * v1.3.0  大回退版：以 v1.2.0 源码为基线，只保留与两个主诉直接相关的差异——
 *         ① 渲染回调层 ctx 表容量 32→512（唯一逻辑改动；修「几小时后某 App
 *            静音失效、杀后台才恢复」＝表只增不减耗尽 32 槽后新单元包装静默
 *            失败。静态数组按进程生命周期兜底，同 (unit,scope,element) 重注册
 *            走 match 复用；不需要任何销毁钩子/存活探测——1.2.1~1.2.4 那套
 *            机制整体废弃，实测无必要且引入风险）。
 *         ② 日志瘦身（纯日志，无逻辑影响；修「几小时把 256KB 日志轮转没」）：
 *            Widget/Today 扩展进程（PluginKitPlugin 容器）跳过、探针明细与
 *            配置原文仅 vmaq-debug 文件存在时输出、包装日志配额 60→200。
 *         ③ 包装计数每 32 次输出一行 ctx 占用率（验证用，无逻辑影响）。
 *         其余 1.2.1~1.2.7 的全部改动（Dispose 钩子/死亡单元探测/jbroot 反解/
 *         AQ 登记表/配置读失败保持系数等）不进本版；复盘见仓库 docs 与案卷。
 * v1.2.0  新增「混音策略层」：挂钩 AVAudioSession 的 setActive / setCategory 系列，
 *         在每次激活前把会话重新声明成 MixWithOthers，让多个 App 真正同时播放。
 *         该层与音量配置解耦、无条件安装；私有 API 探测后才挂；默认开启，
 *         可用 vmMixEnabled / vmMixGuard / vmMixExcludedApps 或 vmaq-mix-off 关闭。
 * v1.1.1  1) 音量值兼容字符串存储（设备上实测出现过 volume = "0.1951..."）；
 *         2) 日志版本串改为 v1.1.1，避免与历史日志混淆。
 * 变更历史
 *   v0.1.0  首次重写。arm64e 切片为旧 ABI → 注入 SpringBoard 直接安全模式。
 *   v0.2.0  改 arm64 单切片，不再崩。但①过滤器误用 Classes → 没被注入任何 App
 *           ②放弃渲染回调路径 → 即使被注入也改不了音量。
 *   v0.3.0  ①过滤器改回 Bundles=("com.apple.UIKit")
 *           ②重写渲染回调，按真实流格式缩放（消除杂音的正解）
 *           ③配置容错匹配 + 日志 + 调试旁路
 *           实测：注入成功、无杂音、无安全模式，但「配置存在=0」，音量未变。
 *   v0.4.0  修配置路径。原插件 postinst 用 ROOT_PREFIX=/var/jb：
 *           真实目录是 /var/jb/var/mobile/Library/VolumeManager-sunshinesong/
 *           dylib 里写裸路径靠越狱运行时映射，我们重写版没走那层 → 改为多路径探测。
 *           实测：音量生效、无杂音、多应用同时播放正常 ✅
 *   v0.5.0  本版修「改完音量必须重开 App 才生效」（原版是实时生效）。三处改动：
 *           ① 【根因】补齐 Darwin 通知监听。原版 AudioQueue 模块监听的是两个名字：
 *                 com.sunshinesong.volume-manager-prefs.settingOnChanged  (设置面板发)
 *                 com.sunshinesong.volume-manager-hud.onChangeHUDVolume   (HUD 发)
 *              我们之前只监听第一个 → 用 HUD 调音时收不到信号 → 系数永不刷新。
 *           ② 增加后台轮询（0.5s，比对配置/偏好文件的 size+mtime）：
 *              任何通知漏掉都能兜住，不依赖作者还发了什么通知。
 *           ③ 挂钩改为「只要配置存在就安装」，不再看启动瞬间的系数是不是 1.0
 *              —— 否则「启动时 1.0、之后调小」的场景永远不会生效。
 *           ④ 备用层（AudioQueue / AVPlayer / AVAudioPlayer /
 *              AVSampleBufferAudioRenderer）引入「实例登记表 + 基准音量」，
 *              系数变化时主动回写 → 实时生效；渲染回调层一旦布防成功
 *              （ASBD 拿到），登记表立刻回退为基准音量，避免 factor² 二次缩放。
 *           ⑤ 日志落点收敛为「实际使用的配置目录」，不再到处建目录（此前会在
 *              裸路径造出一个只有 vmaq.log 的空目录，容易把人绕晕）。
 *              探针日志增加 [序号] 与 dev/inode —— 同一文件无论几条路径，
 *              inode 相同一眼可辨。
 *
 * ---------------------------------------------------------------------------
 * 配置结构（已由用户导出的 volumeInfo.plist 确认，100% 确定）
 *   root = { "<bundleId>" : { "volume": <float 0..1>, "appName": "<中文名>" }, ... }
 *
 * ---------------------------------------------------------------------------
 * 杂音根因（已由反汇编确认）
 *   原模块挂钩 AudioUnitSetProperty(kAudioUnitProperty_SetRenderCallback=23)，
 *   把 App 的渲染回调整体换成自己的函数。该回调按 Float32、以固定 4 字节步长
 *   逐样本乘增益，完全不检查流的真实格式。当音频流是 16 位 PCM（每样本 2 字节）
 *   时，每 4 字节（两个 int16 样本）被整体当作一个 float 读写 → 原始 PCM 被
 *   彻底破坏 → 强杂音。直播流更多使用 16 位低码率格式，所以直播更容易复现。
 *
 *   本实现保留同一条路径（它是唯一通用的每 App 音量实现方式），但：
 *     · 先查询 AudioStreamBasicDescription，按 isFloat / isSignedInteger /
 *       mBitsPerChannel 分派到 Float32 / Float64 / SInt16 / SInt32 / SInt8
 *     · 任一环节不确定（取不到格式、格式不认识、位数不支持）→ 原样放行，
 *       一个字节都不动。宁可不出声，也绝不制造杂音。
 *     · 实时线程内零 Objective-C 调用、零内存分配、零日志、零锁
 */

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <dispatch/dispatch.h>
#import <pthread.h>
#import <stdlib.h>
#import <string.h>
#import <errno.h>
#import <math.h>
#import <sys/stat.h>
#if __has_include(<AudioUnit/AudioUnit.h>)
#import <AudioUnit/AudioUnit.h>
#endif

// ===========================================================================
// 路径
//   Rootless（本机）：真实目录在 /var/jb 前缀下。
//   原版 dylib 读的是不带前缀的路径 —— 靠越狱运行时映射。
//   这里两条都试，谁先读到谁赢。
//   ⚠ 注意：libroot 的 stat() 钩子会「就地改写」调用方传入的 C 路径缓冲区，
//   若直接对同一个 NSString 反复取 fileSystemRepresentation，会把它的缓存
//   缓冲区弄脏 → 日志里打印出来的路径会变成容器路径（此前就踩到这个坑）。
//   所以统一走 VMStat()，内部用一份临时字符串，绝不污染要打印的那个。
// ===========================================================================
#define VM_DIR_JB     @"/var/jb/var/mobile/Library/VolumeManager-sunshinesong"
#define VM_DIR_PLAIN  @"/var/mobile/Library/VolumeManager-sunshinesong"
#define VM_DIR_JBROOT @"/.jbroot/var/mobile/Library/VolumeManager-sunshinesong"

// postinst 会把配置同步一份到这里（Preferences 目录对沙箱内 App 通常可读）
static NSString *const kVMSyncedCopy = @"/var/mobile/Library/Preferences/com.local.volmanaudioqueue.appvolume.plist";

static NSString *const kVMPrefsPath  = @"/var/mobile/Library/Preferences/com.sunshinesong.volume-manager-prefs.plist";
static NSString *const kVMEnabledKey = @"isEnabledManagementAppVolume";

// 原版 AudioQueue 模块监听的就是这三个（前两个是重点）：
//   settingOnChanged  ← 设置面板调完音量后 POST
//   onChangeHUDVolume ← HUD 调音量后 POST（v0.5.0 之前我们漏掉的正是它）
//   showVMHUD         ← 呼出 HUD
static NSArray<NSString *> *VMNotifyNames(void) {
    return @[ @"com.sunshinesong.volume-manager-prefs.settingOnChanged",
              @"com.sunshinesong.volume-manager-hud.onChangeHUDVolume",
              @"com.sunshinesong.volume-manager.showVMHUD" ];
}

// 目录候选（日志/旁路文件/配置都在这几个目录里找）
static NSArray<NSString *> *VMDirs(void) {
    return @[ VM_DIR_JB, VM_DIR_PLAIN, VM_DIR_JBROOT ];
}

// 配置路径候选（按优先级）
static NSArray<NSString *> *VMConfigCandidates(void) {
    NSMutableArray *a = [NSMutableArray array];
    for (NSString *d in VMDirs()) {
        [a addObject:[d stringByAppendingPathComponent:@"volumeInfo.plist"]];
    }
    // 沙箱内可读的同步副本
    [a addObject:kVMSyncedCopy];
    // 偏好目录里的同名文件（万一作者把配置写在这）
    [a addObject:@"/var/mobile/Library/Preferences/volumeInfo.plist"];
    // App 自身容器（部分越狱场景下会被重定向到这里）
    @try {
        NSString *home = NSHomeDirectory();
        if (home.length) {
            [a addObject:[home stringByAppendingPathComponent:@"Library/VolumeManager-sunshinesong/volumeInfo.plist"]];
            [a addObject:[home stringByAppendingPathComponent:@"Documents/volumeInfo.plist"]];
        }
    } @catch (NSException *e) { }
    // 兜底（方便用户随手扔一份到这里做验证）
    [a addObject:@"/tmp/volumeInfo.plist"];
    return a;
}

// 统一 stat 包装（见文件头注释：避开 libroot 的就地改写）
static int VMStat(NSString *p, struct stat *st) {
    if (!p.length) return -1;
    NSString *tmp = [NSString stringWithFormat:@"%@", p];
    return stat(tmp.fileSystemRepresentation, st);
}

// ===========================================================================
// 全局状态
//   热路径（实时音频线程）只读 gVolume / gRCActive / gRCArmed 三个 volatile。
// ===========================================================================
static volatile float gVolume     = 1.0f;   // 本进程音量系数，1.0 = 不改动
static volatile int   gRCActive   = 0;      // 渲染回调层「已经真正缩放过一次」
static volatile int   gRCArmed    = 0;      // 渲染回调层「已布防」（包装成功且拿到流格式）
static volatile int   gInstalled  = 0;      // 挂钩是否已安装
static volatile int   gHookLogCap = 0;      // 非实时路径日志配额
static volatile int   gReapply    = 0;      // 正在回写音量 → 挂钩直接放行（防自噬）
static volatile int   gFallbackDirty = 0;   // 备用层曾写入过「基准×系数」，需要回退

static NSString      *gCfgPath    = nil;    // 实际采用的配置路径
static NSString      *gCfgDir     = nil;    // 实际采用的目录（日志落点）
static NSMutableDictionary *gStamps = nil;  // 路径 → @[@(size), @(mtimeSec)]，用于轮询比对
static dispatch_queue_t gQueue    = nil;    // 刷新串行队列（非实时）
static dispatch_source_t gTimer   = nil;

static NSString *VMCurrentBundleId(void) {
    @try {
        NSString *b = [[NSBundle mainBundle] bundleIdentifier];
        return b ?: @"";
    } @catch (NSException *e) {
        return @"";
    }
}

// v1.3.0：详尽日志开关 —— 任一配置目录放名为 vmaq-debug 的空文件即开。
// 平时关：探针明细/配置原文/目录列举这些一次性诊断占掉了 256KB 日志的
// 绝大部分（每次注入 ~90 行 × 任意 App 启动），几小时就把历史轮转没了。
static int gVMAQDebug = 0;
static int VMAQDebugProbe(void) {
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *d in VMDirs()) {
            if ([fm fileExistsAtPath:[d stringByAppendingPathComponent:@"vmaq-debug"]]) return 1;
        }
        return 0;
    } @catch (NSException *e) {
        return 0;
    }
}

// ===========================================================================
// 日志工具（仅用于非实时路径！）
//   落点策略：优先写「实际使用的配置目录」；写成功就停，不再到处建目录。
// ===========================================================================
static BOOL VMWriteSink(NSString *path, NSString *dir, NSData *data) {
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:path]) {
            if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL]) return NO;
            if (![data writeToFile:path atomically:YES]) return NO;
            [fm setAttributes:@{NSFilePosixPermissions:@(0644)} ofItemAtPath:path error:NULL];
            return YES;
        }
        // 超过 256KB 时保留尾部 128KB。
        // 注意：不能写成「只写当前这一条」——那等于整份清空，取日志时只剩一行，
        // 极容易被误判成「日志坏了」。诊断日志的价值全在最近发生了什么，
        // 所以丢头部、留尾部，并明确写一行截断标记。
        NSDictionary *attr = [fm attributesOfItemAtPath:path error:NULL];
        if (attr && [[attr objectForKey:NSFileSize] unsignedIntegerValue] > 256 * 1024) {
            NSData *old = [NSData dataWithContentsOfFile:path];
            if (!old) return NO;
            const NSUInteger keep = 128 * 1024;
            NSUInteger from = old.length > keep ? old.length - keep : 0;
            if (from > 0) {
                // 对齐到行首，丢掉可能被切半的第一行
                const char *p = (const char *)old.bytes;
                while (from < old.length && p[from] != '\n') from++;
                if (from < old.length) from++;
            }
            NSMutableData *merged = [NSMutableData data];
            NSData *mark = [@"=== 日志超过 256KB，已丢弃较早内容，以下为最近 128KB ===\n"
                            dataUsingEncoding:NSUTF8StringEncoding];
            if (mark) [merged appendData:mark];
            if (from < old.length) {
                [merged appendData:[old subdataWithRange:NSMakeRange(from, old.length - from)]];
            }
            [merged appendData:data];
            return [merged writeToFile:path atomically:YES];
        }
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) return NO;
        [fh seekToEndOfFile];
        [fh writeData:data];
        [fh closeFile];
        return YES;
    } @catch (NSException *e) {
        return NO;
    }
}

static void VMLogRaw(NSString *line) {
    @try {
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        if (!data) return;
        if (gCfgDir.length) {
            if (VMWriteSink([gCfgDir stringByAppendingPathComponent:@"vmaq.log"], gCfgDir, data)) return;
        }
        for (NSString *d in VMDirs()) {
            if (VMWriteSink([d stringByAppendingPathComponent:@"vmaq.log"], d, data)) return;
        }
        NSString *home = NSHomeDirectory();
        if (home.length) {
            VMWriteSink([home stringByAppendingPathComponent:@"Documents/vmaq.log"],
                        [home stringByAppendingPathComponent:@"Documents"], data);
        }
    } @catch (NSException *e) { }
}

#define VMLog(fmt, ...)                                                        \
    do {                                                                       \
        @try {                                                                 \
            NSString *__b = [[NSBundle mainBundle] bundleIdentifier] ?: @"-";   \
            NSDateFormatter *__df = [[NSDateFormatter alloc] init];             \
            [__df setDateFormat:@"MM-dd HH:mm:ss"];                             \
            NSString *__l = [NSString stringWithFormat:@"[%@ %@] " fmt "\n",    \
                             [__df stringFromDate:[NSDate date]], __b,          \
                             ##__VA_ARGS__];                                    \
            NSLog(@"[VMAQ] %@", __l);                                           \
            VMLogRaw(__l);                                                      \
        } @catch (NSException *e) { }                                           \
    } while (0)

// 节流日志：防止非实时但高频的路径刷爆日志
static void VMLogT(NSString *s) {
    static volatile int n = 0;
    if (n >= 40) return;
    n++;
    VMLog(@"%@", s);
}

// ===========================================================================
// 配置定位
// ===========================================================================
// 读到一份「像配置」的字典就认：必须是非空字典，且至少有一项的值是数字或含数字的字典。
static BOOL VMLooksLikeConfig(id node) {
    if (![node isKindOfClass:[NSDictionary class]]) return NO;
    NSDictionary *d = (NSDictionary *)node;
    if (d.count == 0) return NO;
    for (id k in d) {
        id v = d[k];
        if ([v isKindOfClass:[NSNumber class]]) return YES;
        if ([v isKindOfClass:[NSDictionary class]]) {
            for (id kk in (NSDictionary *)v) {
                if ([((NSDictionary *)v)[kk] isKindOfClass:[NSNumber class]]) return YES;
            }
        }
    }
    return NO;
}

// 逐个候选路径尝试读取，返回第一个可用的路径（并给出字典）
static NSString *VMResolveConfig(NSDictionary **outRoot) {
    if (outRoot) *outRoot = nil;

    // 0) 用户手动指定的路径优先（vmaq-path.txt）
    @try {
        for (NSString *d in VMDirs()) {
            NSString *pf = [d stringByAppendingPathComponent:@"vmaq-path.txt"];
            NSString *s = [NSString stringWithContentsOfFile:pf
                                                    encoding:NSUTF8StringEncoding
                                                       error:NULL];
            if (s.length) {
                NSString *p = [s stringByTrimmingCharactersInSet:
                               [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (p.length) {
                    NSDictionary *r = [NSDictionary dictionaryWithContentsOfFile:p];
                    if (VMLooksLikeConfig(r)) {
                        if (outRoot) *outRoot = r;
                        gCfgPath = p;
                        gCfgDir  = [p stringByDeletingLastPathComponent];
                        VMLog(@"配置来源=手动指定(vmaq-path.txt) %@", p);
                        return p;
                    }
                    VMLog(@"手动指定的路径读不出配置: %@", p);
                }
            }
        }
    } @catch (NSException *e) { }

    // 1) 依次尝试候选路径
    for (NSString *p in VMConfigCandidates()) {
        @try {
            NSDictionary *r = [NSDictionary dictionaryWithContentsOfFile:p];
            if (VMLooksLikeConfig(r)) {
                if (outRoot) *outRoot = r;
                gCfgPath = p;
                gCfgDir  = [p stringByDeletingLastPathComponent];
                VMLog(@"配置来源=%@ (键数 %lu)", p, (unsigned long)((NSDictionary *)r).count);
                return p;
            }
        } @catch (NSException *e) { }
    }
    return nil;
}

// 全量探测：把每个候选路径的真实状态（存在/大小/权限/errno/dev/inode）写进日志。
// 目的：一次安装就把「到底文件在哪 / 为什么读不到」彻底查清。
// inode+dev 是判断「两条路径是不是同一个文件」的唯一可靠依据。
static void VMProbePaths(void) {
    @try {
        VMLog(@"进程 uid=%d home=%@", getuid(), NSHomeDirectory());

        // v1.3.0：明细（每个候选的 dev/ino、目录列举）只在 vmaq-debug 时输出；
        // 平时一行汇总 —— 10 个探针 + 4 个目录 ≈ 14 行/次注入，× 任意 App 启动，
        // 是日志轮转过快的主要原因。
        int idx = 0, hits = 0, total = 0;
        NSString *firstHit = nil;
        for (NSString *p in VMConfigCandidates()) {
            NSString *tag = [NSString stringWithFormat:@"[%d]", idx++];
            total++;
            struct stat st;
            memset(&st, 0, sizeof(st));
            // 注意：打印用 p 本体，stat 用临时副本（见文件头注释）
            int r = VMStat(p, &st);
            if (r == 0) {
                hits++;
                if (!firstHit) firstHit = p;
                if (gVMAQDebug)
                    VMLog(@"探针%@ 命中 %@ size=%lld mode=%o dev=%llu ino=%llu",
                          tag, p, (long long)st.st_size, (unsigned)(st.st_mode & 07777),
                          (unsigned long long)st.st_dev, (unsigned long long)st.st_ino);
            } else if (gVMAQDebug) {
                VMLog(@"探针%@ 缺失 %@ errno=%d(%s)", tag, p, errno, strerror(errno));
            }
        }
        if (!gVMAQDebug)
            VMLog(@"配置探测：%d 个候选命中 %d 个（首个=%@；调试放 vmaq-debug 文件看明细）",
                  total, hits, firstHit ?: @"无");

        if (gVMAQDebug) {
            // 目录列举：只看和本插件相关的条目，避免刷屏（仅 debug）
            NSArray *dirs = @[ VM_DIR_JB, VM_DIR_PLAIN, VM_DIR_JBROOT, @"/var/mobile/Library/Preferences" ];
            for (NSString *d in dirs) {
                NSError *e = nil;
                NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:d error:&e];
                if (!items) {
                    VMLog(@"目录 %@ 无法列举: %@", d, e.localizedDescription ?: @"(未知)");
                    continue;
                }
                NSMutableArray *hit = [NSMutableArray array];
                for (NSString *it in items) {
                    NSString *low = it.lowercaseString;
                    if ([low containsString:@"volume"] || [low containsString:@"sunshine"] ||
                        [low containsString:@"volman"]  || [low containsString:@"vmaq"]) {
                        NSString *full = [d stringByAppendingPathComponent:it];
                        struct stat st; memset(&st, 0, sizeof(st));
                        long long sz = (VMStat(full, &st) == 0) ? (long long)st.st_size : -1;
                        [hit addObject:[NSString stringWithFormat:@"%@(%lldB)", it, sz]];
                    }
                }
                VMLog(@"目录 %@ 共 %lu 项，相关项: %@",
                      d, (unsigned long)items.count,
                      hit.count ? [hit componentsJoinedByString:@", "] : @"(无)");
            }
        }
    } @catch (NSException *e) {
        VMLog(@"探针异常: %@", e);
    }
}

// ===========================================================================
// 配置取值
//   结构已确认：{ bundleId : { volume : number, appName : string } }
//   仍然保留容错扫描，以防个别条目格式不同。
// ===========================================================================
typedef struct { int score; float value; } VMCand;

static void VMScanNode(id node, NSString *bid, int depth, VMCand *best, NSString **bestKey) {
    if (depth > 6 || !node) return;
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = (NSDictionary *)node;
        for (id k in d) {
            if (![k isKindOfClass:[NSString class]]) continue;
            NSString *ks = (NSString *)k;
            id v = d[k];

            int ks1 = 0;
            if ([ks isEqualToString:bid])                        ks1 = 3;
            else if ([ks hasPrefix:bid])                         ks1 = 2;
            else if ([ks rangeOfString:bid].location != NSNotFound) ks1 = 1;

            if (ks1 > 0) {
                id num = v;
                if ([num isKindOfClass:[NSDictionary class]]) {
                    NSDictionary *vd = (NSDictionary *)num;
                    // 音量值可能是 NSNumber，也可能被写成字符串（设备上实测有
                    // volume = "0.1951640232857027" 这种），两种都要认。
                    id vv = vd[@"volume"];
                    if ([vv isKindOfClass:[NSNumber class]] || [vv isKindOfClass:[NSString class]]) {
                        num = vv;
                    } else {
                        // 回退扫描必须限定键名，否则会误取 appName（也是字符串）
                        for (id kk in vd) {
                            if (![kk isKindOfClass:[NSString class]]) continue;
                            NSString *kl = [(NSString *)kk lowercaseString];
                            if ([kl rangeOfString:@"vol"].location == NSNotFound &&
                                [kl rangeOfString:@"level"].location == NSNotFound) continue;
                            id cand = vd[kk];
                            if ([cand isKindOfClass:[NSNumber class]] ||
                                [cand isKindOfClass:[NSString class]]) { num = cand; break; }
                        }
                    }
                }
                if ([num isKindOfClass:[NSNumber class]] || [num isKindOfClass:[NSString class]]) {
                    if (ks1 > best->score) {
                        best->score = ks1;
                        best->value = [num floatValue];
                        if (bestKey) *bestKey = ks;
                    }
                }
            }
            if ([v isKindOfClass:[NSDictionary class]] || [v isKindOfClass:[NSArray class]]) {
                VMScanNode(v, bid, depth + 1, best, bestKey);
            }
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id v in (NSArray *)node) VMScanNode(v, bid, depth + 1, best, bestKey);
    }
}

// 找不到匹配项时，尝试约定的默认键
static float VMDefaultKeyValue(NSDictionary *root) {
    for (NSString *k in @[@"-", @"default", @"defaultVolume", @"volume"]) {
        id v = root[k];
        if ([v isKindOfClass:[NSNumber class]] || [v isKindOfClass:[NSString class]])
            return [v floatValue];
    }
    id sub = root[@"allAppVolume"];
    if ([sub isKindOfClass:[NSDictionary class]]) {
        for (NSString *k in @[@"-", @"default"]) {
            id v = ((NSDictionary *)sub)[k];
            if ([v isKindOfClass:[NSNumber class]] || [v isKindOfClass:[NSString class]])
                return [v floatValue];
        }
    }
    return -1.0f;
}

// 把各种可能的存储单位统一成 0..1
static float VMNormalize(float f) {
    if (!(f >= 0.0f)) return 1.0f;      // 顺带挡住 NaN
    if (f <= 1.0f)    return f;
    if (f <= 100.0f)  return f / 100.0f;
    if (f <= 1000.0f) return f / 1000.0f;
    return 1.0f;
}

static float VMComputeFactorFrom(NSDictionary *root, NSString *bid,
                                NSString **outKey, float *outRaw, BOOL *outMatched) {
    if (outKey) *outKey = nil;
    if (outRaw) *outRaw = -1.0f;
    if (outMatched) *outMatched = NO;
    if (!VMLooksLikeConfig(root) || bid.length == 0) return 1.0f;

    VMCand best; best.score = 0; best.value = 1.0f;
    VMScanNode(root, bid, 0, &best, outKey);

    if (best.score == 0) {
        float d = VMDefaultKeyValue(root);
        if (d >= 0.0f) {
            if (outKey) *outKey = @"(默认键)";
            if (outRaw) *outRaw = d;
            if (outMatched) *outMatched = YES;
            return VMNormalize(d);
        }
        return 1.0f;
    }
    if (outRaw) *outRaw = best.value;
    if (outMatched) *outMatched = YES;
    return VMNormalize(best.value);
}

static BOOL VMPrefsEnabled(void) {
    @try {
        NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:kVMPrefsPath];
        if (![p isKindOfClass:[NSDictionary class]]) return YES;   // 读不到就默认启用
        id v = p[kVMEnabledKey];
        return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : YES;
    } @catch (NSException *e) {
        return YES;
    }
}

// 调试旁路：vmaq-force.txt 里的一个数字，作为所有 App 的统一系数。
static float VMReadForceFile(void) {
    @try {
        NSMutableArray *files = [NSMutableArray array];
        for (NSString *d in VMDirs()) {
            [files addObject:[d stringByAppendingPathComponent:@"vmaq-force.txt"]];
        }
        [files addObject:@"/var/mobile/Library/Preferences/vmaq-force.txt"];
        NSString *home = NSHomeDirectory();
        if (home.length) {
            [files addObject:[home stringByAppendingPathComponent:@"Documents/vmaq-force.txt"]];
        }
        for (NSString *f in files) {
            NSString *s = [NSString stringWithContentsOfFile:f
                                                    encoding:NSUTF8StringEncoding
                                                       error:NULL];
            if (!s) continue;
            s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (s.length == 0) continue;
            VMLog(@"调试旁路文件命中: %@ = %@", f, s);
            return [s floatValue];
        }
        return -1.0f;
    } @catch (NSException *e) {
        return -1.0f;
    }
}

static void VMDumpConfigOnce(NSDictionary *root) {
    @try {
        if (!root) { VMLog(@"配置为空，无法 dump"); return; }
        NSString *s = [root description];
        if (s.length > 2000) s = [[s substringToIndex:2000] stringByAppendingString:@"……(已截断)"];
        VMLog(@"配置原文: %@", s);
    } @catch (NSException *e) {
        VMLog(@"配置 dump 异常: %@", e);
    }
}

// ===========================================================================
// 备用层：实例登记表
//   记录「App 自己设定的基准音量」，这样系数变化时能把 base×新系数 写回去，
//   实现实时生效。键持弱引用（对象释放自动移除）。
// ===========================================================================
static NSMapTable      *gBase     = nil;
static pthread_mutex_t  gBaseLock = PTHREAD_MUTEX_INITIALIZER;

static void VMBaseLockInit(void) {
    if (!gBase) {
        gBase = [[NSMapTable alloc]
                 initWithKeyOptions:(NSPointerFunctionsWeakMemory | NSPointerFunctionsOpaquePersonality)
                       valueOptions:NSPointerFunctionsStrongMemory
                           capacity:8];
    }
}

static void VMRegSet(id obj, float base) {
    if (!obj || !(base >= 0.0f)) return;
    pthread_mutex_lock(&gBaseLock);
    VMBaseLockInit();
    [gBase setObject:@(base) forKey:obj];
    pthread_mutex_unlock(&gBaseLock);
}

static void VMRegSetIfAbsent(id obj, float base) {
    if (!obj) return;
    pthread_mutex_lock(&gBaseLock);
    VMBaseLockInit();
    if (![gBase objectForKey:obj]) [gBase setObject:@(base) forKey:obj];
    pthread_mutex_unlock(&gBaseLock);
}

static NSArray *VMRegSnapshot(void) {
    NSMutableArray *a = [NSMutableArray array];
    pthread_mutex_lock(&gBaseLock);
    if (gBase) {
        for (id k in gBase.keyEnumerator) {
            NSNumber *b = [gBase objectForKey:k];
            if (k && b) [a addObject:@[k, b]];   // ARC：数组持强引用，回写期间对象不会消失
        }
    }
    pthread_mutex_unlock(&gBaseLock);
    return a;
}

static void VMReapply(float f, BOOL revertToBase) {
    NSArray *snap = VMRegSnapshot();
    if (snap.count == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        gReapply = 1;
        int n = 0;
        for (NSArray *pair in snap) {
            id obj = pair[0];
            float base = [(NSNumber *)pair[1] floatValue];
            float v = revertToBase ? base : base * f;
            if (!(v >= 0.0f)) v = 0.0f;
            if (v > 1.0f) v = 1.0f;
            @try {
                if ([obj respondsToSelector:@selector(setVolume:)]) {
                    [(AVPlayer *)obj setVolume:v];
                    n++;
                }
            } @catch (NSException *e) { }
        }
        gReapply = 0;
        if (n) {
            VMLogT([NSString stringWithFormat:@"备用层回写 %d 个播放器 → %@ (系数 %.4f)",
                    n, revertToBase ? @"基准音量" : @"基准×新系数", (double)f]);
        }
    });
}

// ===========================================================================
// 渲染回调层：格式感知的逐样本缩放
// ===========================================================================
// v1.3.0：32→512。静态数组（不做动态扩容——渲染回调持有槽位指针，realloc 会让
// 已安装回调的 refCon 全部失效）。512×~96B ≈ 48KB BSS，按进程生命周期兜底；
// 同 (unit,scope,element) 重注册走 match 复用，槽位不主动回收（无销毁钩子）。
#define VM_CTX_MAX    512
#define VM_CTX_MAGIC  0x564D415143545831ULL   // "VMAQCTX1"
#define VM_ASBD_TRIES 16

typedef struct {
    volatile int used;
    volatile uint64_t magic;
    AudioUnit unit;
    UInt32 scope;
    UInt32 element;
    AURenderCallback origProc;
    void *origRefCon;
    volatile int asbdValid;
    volatile int asbdTries;
    AudioStreamBasicDescription asbd;
} VMCtx;

static VMCtx gCtx[VM_CTX_MAX];
static pthread_mutex_t gCtxLock = PTHREAD_MUTEX_INITIALIZER;
static volatile int gCtxPeak   = 0;   // v1.3.0：占用峰值（诊断）
static volatile int gWrapCount = 0;   // v1.3.0：累计包装次数（占用率日志节流）

// 按 (unit, scope, element) 找到或新建上下文。只在非实时路径调用。
static VMCtx *VMObtainCtx(AudioUnit unit, UInt32 scope, UInt32 element) {
    VMCtx *found = NULL;
    pthread_mutex_lock(&gCtxLock);
    for (int i = 0; i < VM_CTX_MAX; i++) {
        if (gCtx[i].used && gCtx[i].magic == VM_CTX_MAGIC &&
            gCtx[i].unit == unit && gCtx[i].scope == scope && gCtx[i].element == element) {
            found = &gCtx[i];
            break;
        }
    }
    if (!found) {
        for (int i = 0; i < VM_CTX_MAX; i++) {
            if (!gCtx[i].used) { found = &gCtx[i]; break; }
        }
        if (found) {
            memset(found, 0, sizeof(*found));
            found->used = 1;
            found->unit = unit;
            found->scope = scope;
            found->element = element;
        }
    }
    if (found) found->magic = VM_CTX_MAGIC;
    pthread_mutex_unlock(&gCtxLock);
    return found;
}

// 取流格式。依次尝试 (原 scope, 原 element) / (Input, 原 element) /
// (Output, 原 element) / (Input, 0)，尽量提高拿到真实格式的机率。
static BOOL VMQueryASBD(VMCtx *c) {
    if (!c || !c->unit) return NO;
    UInt32 scopes[4] = { c->scope, kAudioUnitScope_Input, kAudioUnitScope_Output, kAudioUnitScope_Input };
    UInt32 elems[4]  = { c->element, c->element, c->element, 0 };
    for (int i = 0; i < 4; i++) {
        AudioStreamBasicDescription a;
        memset(&a, 0, sizeof(a));
        UInt32 sz = sizeof(a);
        if (AudioUnitGetProperty(c->unit, kAudioUnitProperty_StreamFormat,
                                 scopes[i], elems[i], &a, &sz) == noErr &&
            sz == sizeof(a) && a.mBitsPerChannel > 0) {
            c->asbd = a;
            c->asbdValid = 1;
            return YES;
        }
    }
    return NO;
}

// 真正的缩放。c 的 asbd 必须有效。缓冲区按「扁平样本数组」处理，
// 因此天然兼容 interleaved 与 non-interleaved 两种布局。
static void VMScaleBufferList(const AudioStreamBasicDescription *asbd,
                              AudioBufferList *ioData, float v) {
    const UInt32 flags = asbd->mFormatFlags;
    const UInt32 bits  = asbd->mBitsPerChannel;
    const BOOL   isFloat = (flags & kAudioFormatFlagIsFloat) != 0;
    const BOOL   isInt   = (flags & kAudioFormatFlagIsSignedInteger) != 0;
    const UInt32 nb = ioData->mNumberBuffers;

    for (UInt32 b = 0; b < nb; b++) {
        AudioBuffer *buf = &ioData->mBuffers[b];
        if (!buf->mData || buf->mDataByteSize == 0) continue;

        if (isFloat) {
            if (bits == 32) {
                float *p = (float *)buf->mData;
                UInt32 n = buf->mDataByteSize >> 2;
                for (UInt32 i = 0; i < n; i++) p[i] *= v;
            } else if (bits == 64) {
                double *p = (double *)buf->mData;
                UInt32 n = buf->mDataByteSize >> 3;
                for (UInt32 i = 0; i < n; i++) p[i] *= v;
            }
            // 其余位宽：不认识的浮点格式，一个字节都不动
        } else if (isInt) {
            if (bits == 16) {
                int16_t *p = (int16_t *)buf->mData;
                UInt32 n = buf->mDataByteSize >> 1;
                for (UInt32 i = 0; i < n; i++) {
                    int32_t s = (int32_t)((float)p[i] * v);
                    p[i] = (int16_t)s;
                }
            } else if (bits == 32) {
                int32_t *p = (int32_t *)buf->mData;
                UInt32 n = buf->mDataByteSize >> 2;
                for (UInt32 i = 0; i < n; i++) {
                    p[i] = (int32_t)((double)p[i] * (double)v);
                }
            } else if (bits == 8) {
                int8_t *p = (int8_t *)buf->mData;
                UInt32 n = buf->mDataByteSize;
                for (UInt32 i = 0; i < n; i++) {
                    p[i] = (int8_t)((int32_t)p[i] * v);
                }
            }
            // 24 位打包等：不动
        }
        // 既不是浮点也不是有符号整数（例如压缩格式）：不动
    }
}

// 实时线程执行的回调本体。全程：无 ObjC 调用、无分配、无日志、无锁。
static OSStatus VMRenderCB(void *inRefCon,
                           AudioUnitRenderActionFlags *ioActionFlags,
                           const AudioTimeStamp *inTimeStamp,
                           UInt32 inBusNumber,
                           UInt32 inNumberFrames,
                           AudioBufferList *ioData) {
    VMCtx *c = (VMCtx *)inRefCon;
    if (!c || c->magic != VM_CTX_MAGIC) return noErr;

    OSStatus st = noErr;
    if (c->origProc) {
        st = c->origProc(c->origRefCon, ioActionFlags, inTimeStamp,
                         inBusNumber, inNumberFrames, ioData);
    }

    const float v = gVolume;
    if (v >= 0.999f || !(v >= 0.0f)) return st;      // 1.0 或异常值 → 原样返回
    if (!ioData || ioData->mNumberBuffers == 0) return st;

    if (!c->asbdValid) {
        if (c->asbdTries < VM_ASBD_TRIES) {
            c->asbdTries++;
            if (!VMQueryASBD(c)) return st;          // 拿不到格式 → 不动数据
        } else {
            return st;
        }
    }

    VMScaleBufferList(&c->asbd, ioData, v);
    gRCActive = 1;                                   // 告知其它图层：让位
    return st;
}

// ===========================================================================
// 挂钩组：只有确认「本进程确实需要改音量」时才安装
// ===========================================================================
// ===========================================================================
// 混音策略层（L1）
//
//   目标：让多个 App 的 AVAudioSession 同时保持「可混音」状态，
//         系统在激活新会话时就不会去打断已经在放音的那个。
//
//   核心结论（来自 AudioMix 0.0.10 的反汇编验证）：
//     · 决定「会不会打断别人」的时刻是 setActive:YES，不是设类别的那一刻；
//     · 所以在调用原实现之前，把当前会话重新声明成 MixWithOthers 即可；
//     · 改 setCategory 只是补漏，改音频渲染数据对混音完全无效、也不必要。
//
//   与 AudioMix 的差异（都是为了尽量少改变别人的行为）：
//     ① 保留 App 的 mode / routeSharingPolicy：激活前用公有 getter 现读，
//        并用 setCategory:mode:routeSharingPolicy:options:error: 原样带回；
//        AudioMix 只传 category，会把 MoviePlayback / VoiceChat 重置成 Default。
//     ② options 用「已知值 | MixWithOthers」，不丢弃 allowBluetooth 等路由位；
//        AudioMix 直接覆盖成 1。
//     ③ 录音类不改类别：Record 完全放行，PlayAndRecord 只加混音位。
//     ④ 私有 API 全部 class_getInstanceMethod 探测，不存在就不挂。
//     ⑤ 不用 libSparkAppList（240KB + SpringBoard 注入），排除表自己读 plist。
//
//   配置（任选一处，找不到就用默认值）：
//     <数据目录>/mixInfo.plist
//     /var/mobile/Library/Preferences/com.local.volmanaudioqueue.mix.plist
//     /var/mobile/Library/Preferences/com.sunshinesong.volume-manager-prefs.plist
//     /tmp/mixInfo.plist
//   键：
//     vmMixEnabled        BOOL  默认 YES，混音层总开关
//     vmMixGuard          BOOL  默认 NO，是否拦截 silenceOutput（激进防守）
//     vmMixExcludedApps   array 不参与混音的 bundle id
//   另：<数据目录>/vmaq-mix-off 文件存在即强制关闭（免重装调试用）
// ===========================================================================

static volatile int gMixEnabled    = 1;   // 混音层总开关
static volatile int gMixGuard      = 0;   // silenceOutput 拦截（默认关）
static volatile int gMixExcluded   = 0;   // 本 App 在排除表里
static volatile int gMixHooked     = 0;   // 已安装钩子
static volatile int gMixActCount   = 0;   // 已改写过几次（用于日志节流）
static NSObject   *gMixLock        = nil;

// 会话状态缓存（AVAudioSession 在进程内实际是单例，但仍按「最后一次调用」记录）
static NSString   *gMixCat         = nil;
static NSString   *gMixMode        = nil;
static NSUInteger  gMixPolicy      = 0;
static NSUInteger  gMixOptions     = 0;

#define VM_CAT_RINGTONE  @"AVAudioSessionCategoryRingtone"

// ---- 原实现指针 ---------------------------------------------------------
static BOOL (*vm_orig_setActive)(id, SEL, BOOL, NSUInteger, NSError **);
static BOOL (*vm_orig_setCatErr)(id, SEL, NSString *, NSError **);
static BOOL (*vm_orig_setCatOpts)(id, SEL, NSString *, NSUInteger, NSError **);
static BOOL (*vm_orig_setCatMode)(id, SEL, NSString *, NSString *, NSUInteger, NSError **);
static BOOL (*vm_orig_setCatModePolicy)(id, SEL, NSString *, NSString *, NSUInteger, NSUInteger, NSError **);
static BOOL (*vm_orig_setMode)(id, SEL, NSString *, NSError **);
static BOOL (*vm_orig_privSetOptions)(id, SEL, NSUInteger, NSString *, NSError **);
static BOOL (*vm_orig_privSetCat)(id, SEL, NSString *, id, NSUInteger, NSUInteger);
static BOOL (*vm_orig_isPrimary)(id, SEL);
static BOOL (*vm_orig_silenceOutput)(id, SEL, NSUInteger, NSError **);

// ---- 配置 ---------------------------------------------------------------
static NSArray<NSString *> *VMMixConfigCandidates(void) {
    NSMutableArray *a = [NSMutableArray array];
    for (NSString *d in VMDirs()) {
        [a addObject:[d stringByAppendingPathComponent:@"mixInfo.plist"]];
    }
    [a addObject:@"/var/mobile/Library/Preferences/com.local.volmanaudioqueue.mix.plist"];
    [a addObject:@"/var/jb/var/mobile/Library/Preferences/com.local.volmanaudioqueue.mix.plist"];
    [a addObject:@"/var/.jbroot/var/mobile/Library/Preferences/com.local.volmanaudioqueue.mix.plist"];
    [a addObject:kVMPrefsPath];
    [a addObject:[@"/var/jb" stringByAppendingString:kVMPrefsPath]];
    [a addObject:[@"/.jbroot" stringByAppendingString:kVMPrefsPath]];
    [a addObject:@"/tmp/mixInfo.plist"];
    return a;
}

static BOOL VMMixKillSwitchPresent(void) {
    for (NSString *d in VMDirs()) {
        if ([d length] == 0) continue;
        struct stat st;
        memset(&st, 0, sizeof(st));
        if (VMStat([d stringByAppendingPathComponent:@"vmaq-mix-off"], &st) == 0) return YES;
    }
    return NO;
}

static void VMMixLoadConfig(NSString *bid) {
    NSString *src = nil;
    NSDictionary *d = nil;

    for (NSString *p in VMMixConfigCandidates()) {
        @try {
            NSDictionary *r = [NSDictionary dictionaryWithContentsOfFile:p];
            if (![r isKindOfClass:[NSDictionary class]] || r.count == 0) continue;
            // 只认带混音键的文件，避免把 volumeInfo.plist 当成混音配置
            if (r[@"vmMixEnabled"] || r[@"vmMixGuard"] || r[@"vmMixExcludedApps"]) {
                d = r; src = p; break;
            }
        } @catch (NSException *e) { }
    }

    BOOL en = YES;
    BOOL gd = NO;
    if (d) {
        id v = d[@"vmMixEnabled"];
        if ([v respondsToSelector:@selector(boolValue)]) en = [v boolValue];
        v = d[@"vmMixGuard"];
        if ([v respondsToSelector:@selector(boolValue)]) gd = [v boolValue];

        id ex = d[@"vmMixExcludedApps"];
        if ([ex isKindOfClass:[NSArray class]] && bid.length) {
            for (id one in (NSArray *)ex) {
                if ([one isKindOfClass:[NSString class]] && [one isEqualToString:bid]) {
                    gMixExcluded = 1;
                    break;
                }
            }
        }
    }

    if (VMMixKillSwitchPresent()) {
        en = NO;
        src = src ? [src stringByAppendingString:@" +vmaq-mix-off"] : @"vmaq-mix-off";
    }

    gMixEnabled = en ? 1 : 0;
    gMixGuard   = gd ? 1 : 0;

    VMLog(@"[mix] 配置=%@ 开关=%d 防守=%d 排除=%d", src ?: @"(默认：开/不防守)",
          gMixEnabled, gMixGuard, gMixExcluded);
}

// ---- 状态读写 -----------------------------------------------------------
static void VMMixRemember(NSString *cat, NSString *mode, NSUInteger policy, NSUInteger opts) {
    if (!gMixLock) return;
    @synchronized (gMixLock) {
        if (cat)  gMixCat  = [cat copy];
        if (mode) gMixMode = [mode copy];
        gMixPolicy  = policy;
        gMixOptions = opts;
    }
}

static NSString *VMMixCachedMode(void) {
    if (!gMixLock) return nil;
    @synchronized (gMixLock) { return gMixMode; }
}

static NSUInteger VMMixCachedPolicy(void) {
    if (!gMixLock) return 0;
    @synchronized (gMixLock) { return gMixPolicy; }
}

static NSUInteger VMMixCachedOptions(void) {
    if (!gMixLock) return 0;
    @synchronized (gMixLock) { return gMixOptions; }
}

// ---- 判定 ---------------------------------------------------------------
static BOOL VMMixConfigActive(void) {
    return (gMixEnabled && !gMixExcluded) ? YES : NO;
}

// 「别的 App 正在放音」：iOS 17 起再叠加一个官方提示位，判定更准。
static BOOL VMMixOtherPlaying(void) {
    @try {
        AVAudioSession *s = [AVAudioSession sharedInstance];
        BOOL other = s.isOtherAudioPlaying;
        // 不用 @available：本机 Theos 工具链缺少 ___isOSVersionAtLeast，
        // 改成能力探测，效果等价且不会引入链接期符号。
        if ([s respondsToSelector:@selector(secondaryAudioShouldBeSilencedHint)]) {
            other = other || s.secondaryAudioShouldBeSilencedHint;
        }
        return other ? YES : NO;
    } @catch (NSException *e) {
        return NO;
    }
}

// 会被系统判定为「独占/会抢焦点」的类别 → 换成可混音的 Playback。
// 录音类（Record / PlayAndRecord）一律不动类别。
static NSString *VMMixNormalizeCategory(NSString *cat) {
    if (![cat isKindOfClass:[NSString class]] || cat.length == 0) return cat;
    if ([cat isEqualToString:AVAudioSessionCategorySoloAmbient] ||
        [cat isEqualToString:AVAudioSessionCategoryAmbient] ||
        [cat isEqualToString:VM_CAT_RINGTONE]) {
        return AVAudioSessionCategoryPlayback;
    }
    return cat;
}

// 用原实现重新声明会话；保留 mode / policy / options。
static BOOL VMMixApply(AVAudioSession *s, NSString *cat, NSString *mode,
                       NSUInteger policy, NSUInteger opts) {
    if (!s || !cat) return NO;
    NSUInteger o = opts | AVAudioSessionCategoryOptionMixWithOthers;
    @try {
        if (mode && vm_orig_setCatModePolicy) {
            return vm_orig_setCatModePolicy(s, @selector(setCategory:mode:routeSharingPolicy:options:error:),
                                            cat, mode, policy, o, NULL);
        }
        if (mode && vm_orig_setCatMode) {
            return vm_orig_setCatMode(s, @selector(setCategory:mode:options:error:),
                                      cat, mode, o, NULL);
        }
        if (vm_orig_setCatOpts) {
            return vm_orig_setCatOpts(s, @selector(setCategory:withOptions:error:), cat, o, NULL);
        }
    } @catch (NSException *e) { }
    return NO;
}

// ---- setActive 之前的统一改写 -------------------------------------------
static void VMMixReassert(AVAudioSession *s, const char *why) {
    @try {
        NSString *cat = s.category;
        if (cat.length == 0) return;
        if ([cat isEqualToString:AVAudioSessionCategoryRecord]) return;   // 纯录音，别碰

        NSString *mode = s.mode ?: AVAudioSessionModeDefault;
        NSUInteger policy = 0;
        if ([s respondsToSelector:@selector(routeSharingPolicy)]) {
            policy = (NSUInteger)s.routeSharingPolicy;
        }
        NSUInteger opts = VMMixCachedOptions();
        NSString *ncat  = VMMixNormalizeCategory(cat);

        VMMixRemember(ncat, mode, policy, opts);
        VMMixApply(s, ncat, mode, policy, opts);

        if (gMixActCount < 60) {
            gMixActCount++;
            VMLog(@"[mix] %s 前置改写 cat=%@(原 %@) mode=%@ policy=%lu opts=%lu",
                  why, ncat, cat, mode, (unsigned long)policy,
                  (unsigned long)(opts | AVAudioSessionCategoryOptionMixWithOthers));
        }
    } @catch (NSException *e) { }
}

// ---- 钩子实现 -----------------------------------------------------------
static BOOL vm_mix_setActive(id self, SEL _cmd, BOOL active, NSUInteger options, NSError **error) {
    if (active && VMMixConfigActive() && VMMixOtherPlaying()) {
        VMMixReassert((AVAudioSession *)self, "setActive");
    }
    return vm_orig_setActive ? vm_orig_setActive(self, _cmd, active, options, error) : NO;
}

static BOOL vm_mix_setCategoryError(id self, SEL _cmd, NSString *cat, NSError **error) {
    if (VMMixConfigActive()) {
        // setCategory:error: 等价于默认 mode + 默认 options
        VMMixRemember(cat, AVAudioSessionModeDefault, 0, 0);
        if (VMMixOtherPlaying()) {
            NSString *n = VMMixNormalizeCategory(cat);
            VMMixRemember(n, AVAudioSessionModeDefault, 0, AVAudioSessionCategoryOptionMixWithOthers);
            if (vm_orig_setCatOpts) {
                if (gMixActCount < 60) {
                    gMixActCount++;
                    VMLog(@"[mix] setCategory:error: 改写 %@ → %@ + Mix", cat, n);
                }
                return vm_orig_setCatOpts(self, @selector(setCategory:withOptions:error:),
                                          n, AVAudioSessionCategoryOptionMixWithOthers, error);
            }
        }
    }
    return vm_orig_setCatErr ? vm_orig_setCatErr(self, _cmd, cat, error) : NO;
}

static BOOL vm_mix_setCategoryOptions(id self, SEL _cmd, NSString *cat,
                                      NSUInteger options, NSError **error) {
    if (VMMixConfigActive()) {
        VMMixRemember(cat, AVAudioSessionModeDefault, 0, options);
        if (VMMixOtherPlaying()) {
            NSString *n = VMMixNormalizeCategory(cat);
            NSUInteger o = options | AVAudioSessionCategoryOptionMixWithOthers;
            VMMixRemember(n, AVAudioSessionModeDefault, 0, o);
            if (gMixActCount < 60) {
                gMixActCount++;
                VMLog(@"[mix] setCategory:withOptions: 改写 %@/%lu → %@/%lu", cat,
                      (unsigned long)options, n, (unsigned long)o);
            }
            if (vm_orig_setCatOpts) return vm_orig_setCatOpts(self, _cmd, n, o, error);
        }
    }
    return vm_orig_setCatOpts ? vm_orig_setCatOpts(self, _cmd, cat, options, error) : NO;
}

static BOOL vm_mix_setCategoryMode(id self, SEL _cmd, NSString *cat, NSString *mode,
                                   NSUInteger options, NSError **error) {
    if (VMMixConfigActive()) {
        VMMixRemember(cat, mode, 0, options);
        if (VMMixOtherPlaying()) {
            NSString *n = VMMixNormalizeCategory(cat);
            NSUInteger o = options | AVAudioSessionCategoryOptionMixWithOthers;
            VMMixRemember(n, mode, 0, o);
            if (vm_orig_setCatMode) return vm_orig_setCatMode(self, _cmd, n, mode, o, error);
        }
    }
    return vm_orig_setCatMode ? vm_orig_setCatMode(self, _cmd, cat, mode, options, error) : NO;
}

static BOOL vm_mix_setCategoryModePolicy(id self, SEL _cmd, NSString *cat, NSString *mode,
                                         NSUInteger policy, NSUInteger options, NSError **error) {
    if (VMMixConfigActive()) {
        VMMixRemember(cat, mode, policy, options);
        if (VMMixOtherPlaying()) {
            NSString *n = VMMixNormalizeCategory(cat);
            NSUInteger o = options | AVAudioSessionCategoryOptionMixWithOthers;
            VMMixRemember(n, mode, policy, o);
            if (vm_orig_setCatModePolicy) {
                return vm_orig_setCatModePolicy(self, _cmd, n, mode, policy, o, error);
            }
        }
    }
    return vm_orig_setCatModePolicy
         ? vm_orig_setCatModePolicy(self, _cmd, cat, mode, policy, options, error) : NO;
}

// 有些 App 先设类别、再单独调 setMode:，必须跟住，否则激活时会把 mode 改回 Default
static BOOL vm_mix_setMode(id self, SEL _cmd, NSString *mode, NSError **error) {
    if (VMMixConfigActive()) VMMixRemember(nil, mode, VMMixCachedPolicy(), VMMixCachedOptions());
    return vm_orig_setMode ? vm_orig_setMode(self, _cmd, mode, error) : NO;
}

// 私有：-privateSetOptions:forCategory:error:
static BOOL vm_mix_privSetOptions(id self, SEL _cmd, NSUInteger options,
                                  NSString *cat, NSError **error) {
    if (VMMixConfigActive()) {
        VMMixRemember(cat, VMMixCachedMode(), VMMixCachedPolicy(), options);
        if (VMMixOtherPlaying()) {
            NSString *n = VMMixNormalizeCategory(cat);
            NSUInteger o = options | AVAudioSessionCategoryOptionMixWithOthers;
            VMMixRemember(n, VMMixCachedMode(), VMMixCachedPolicy(), o);
            if (vm_orig_privSetOptions) return vm_orig_privSetOptions(self, _cmd, o, n, error);
        }
    }
    return vm_orig_privSetOptions ? vm_orig_privSetOptions(self, _cmd, options, cat, error) : NO;
}

// 私有：-privateSetCategoryWithOptions:modes:routeSharingPolicy:options:
//   实测签名：(self, _cmd, category, modes, policy, options)
static BOOL vm_mix_privSetCat(id self, SEL _cmd, NSString *cat, id modes,
                              NSUInteger policy, NSUInteger options) {
    if (VMMixConfigActive()) {
        VMMixRemember(cat, VMMixCachedMode(), policy, options);
        if (VMMixOtherPlaying()) {
            NSString *n = VMMixNormalizeCategory(cat);
            NSUInteger o = options | AVAudioSessionCategoryOptionMixWithOthers;
            VMMixRemember(n, VMMixCachedMode(), policy, o);
            if (vm_orig_privSetCat) return vm_orig_privSetCat(self, _cmd, n, modes, policy, o);
        }
    }
    return vm_orig_privSetCat ? vm_orig_privSetCat(self, _cmd, cat, modes, policy, options) : NO;
}

// 私有：-isPrimary —— 回答之前先把自己的「攻击性类别」换掉
static BOOL vm_mix_isPrimary(id self, SEL _cmd) {
    if (VMMixConfigActive() && VMMixOtherPlaying()) {
        @try {
            NSString *cat = [(AVAudioSession *)self category];
            if ([cat isEqualToString:AVAudioSessionCategoryAmbient] ||
                [cat isEqualToString:AVAudioSessionCategorySoloAmbient]) {
                VMMixReassert((AVAudioSession *)self, "isPrimary");
            }
        } @catch (NSException *e) { }
    }
    return vm_orig_isPrimary ? vm_orig_isPrimary(self, _cmd) : NO;
}

// 私有：-silenceOutput:error: —— 别的 App 正在放音时，假装「已静音」，实际什么都不做。
// 默认关闭（gMixGuard=0）：多数两 App 混音场景用不到，开启后可能出现「通话时音乐不停」。
static BOOL vm_mix_silenceOutput(id self, SEL _cmd, NSUInteger reason, NSError **error) {
    if (gMixGuard && VMMixConfigActive() && VMMixOtherPlaying()) {
        if (gMixActCount < 60) {
            gMixActCount++;
            VMLog(@"[mix] 拦截 silenceOutput(reason=%lu)，保持播放", (unsigned long)reason);
        }
        return NO;
    }
    return vm_orig_silenceOutput ? vm_orig_silenceOutput(self, _cmd, reason, error) : NO;
}

// ---- 安装 ---------------------------------------------------------------
static void VMMixHookMethod(Class cls, const char *name, IMP hook, IMP *orig) {
    if (!cls || !name) return;
    SEL sel = sel_registerName(name);
    if (!class_getInstanceMethod(cls, sel)) return;   // 该版本没有这个方法 → 不挂
    MSHookMessageEx(cls, sel, hook, orig);
}

static void VMMixInstallHooks(void) {
    Class cls = objc_getClass("AVAudioSession");
    if (!cls) {
        VMLog(@"[mix] 本进程没有 AVAudioSession，跳过混音层");
        return;
    }
    if (!gMixLock) gMixLock = [NSObject new];

    // 公有 API（iOS 15+ 全部存在）
    VMMixHookMethod(cls, "setActive:withOptions:error:",
                    (IMP)vm_mix_setActive, (IMP *)&vm_orig_setActive);
    VMMixHookMethod(cls, "setCategory:error:",
                    (IMP)vm_mix_setCategoryError, (IMP *)&vm_orig_setCatErr);
    VMMixHookMethod(cls, "setCategory:withOptions:error:",
                    (IMP)vm_mix_setCategoryOptions, (IMP *)&vm_orig_setCatOpts);
    VMMixHookMethod(cls, "setCategory:mode:options:error:",
                    (IMP)vm_mix_setCategoryMode, (IMP *)&vm_orig_setCatMode);
    VMMixHookMethod(cls, "setCategory:mode:routeSharingPolicy:options:error:",
                    (IMP)vm_mix_setCategoryModePolicy, (IMP *)&vm_orig_setCatModePolicy);
    VMMixHookMethod(cls, "setMode:error:",
                    (IMP)vm_mix_setMode, (IMP *)&vm_orig_setMode);

    // 私有 API（存在才挂）
    VMMixHookMethod(cls, "privateSetOptions:forCategory:error:",
                    (IMP)vm_mix_privSetOptions, (IMP *)&vm_orig_privSetOptions);
    VMMixHookMethod(cls, "privateSetCategoryWithOptions:modes:routeSharingPolicy:options:",
                    (IMP)vm_mix_privSetCat, (IMP *)&vm_orig_privSetCat);
    VMMixHookMethod(cls, "isPrimary",
                    (IMP)vm_mix_isPrimary, (IMP *)&vm_orig_isPrimary);
    VMMixHookMethod(cls, "silenceOutput:error:",
                    (IMP)vm_mix_silenceOutput, (IMP *)&vm_orig_silenceOutput);

    gMixHooked = 1;
    VMLog(@"[mix] 已安装：setActive=%d setCategory=%d/%d/%d/%d priv=%d/%d isPrimary=%d silence=%d",
          vm_orig_setActive ? 1 : 0,
          vm_orig_setCatErr ? 1 : 0, vm_orig_setCatOpts ? 1 : 0,
          vm_orig_setCatMode ? 1 : 0, vm_orig_setCatModePolicy ? 1 : 0,
          vm_orig_privSetOptions ? 1 : 0, vm_orig_privSetCat ? 1 : 0,
          vm_orig_isPrimary ? 1 : 0, vm_orig_silenceOutput ? 1 : 0);
}

%group VMHooks

// ---- 渲染回调包装 -------------------------------------------------------
// 这是每 App 音量的通用实现路径，也是杂音的原始来源。这里保留了路径，
// 但把「按固定 4 字节读 Float32」换成了上面那套格式感知的缩放。
%hookf(OSStatus, AudioUnitSetProperty, AudioUnit inUnit, AudioUnitPropertyID inID, AudioUnitScope inScope, AudioUnitElement inElement, const void *inData, UInt32 inDataSize) {
    if (inID != kAudioUnitProperty_SetRenderCallback ||
        !inData || inDataSize < sizeof(AURenderCallbackStruct)) {
        return %orig(inUnit, inID, inScope, inElement, inData, inDataSize);
    }

    AURenderCallbackStruct orig;
    memcpy(&orig, inData, sizeof(orig));

    // 我们自己装的回调：直接放过，避免重复包装
    if (orig.inputProc == VMRenderCB) {
        return %orig(inUnit, inID, inScope, inElement, inData, inDataSize);
    }
    // App 在撤销回调：原样放过
    if (!orig.inputProc) {
        return %orig(inUnit, inID, inScope, inElement, inData, inDataSize);
    }

    VMCtx *c = VMObtainCtx(inUnit, inScope, inElement);
    if (!c) {
        return %orig(inUnit, inID, inScope, inElement, inData, inDataSize);
    }

    c->origProc    = orig.inputProc;
    c->origRefCon  = orig.inputProcRefCon;
    c->asbdValid   = 0;
    c->asbdTries   = 0;
    BOOL gotASBD   = VMQueryASBD(c);          // 先试一次，成功就不必在实时线程里查

    if (gHookLogCap < 200) {
        gHookLogCap++;
        VMLog(@"包装渲染回调 unit=%p scope=%u elem=%u 原回调=%p 格式=%@",
              inUnit, (unsigned)inScope, (unsigned)inElement, orig.inputProc,
              gotASBD ? [NSString stringWithFormat:@"float=%d bits=%u ch=%u",
                              (c->asbd.mFormatFlags & kAudioFormatFlagIsFloat) ? 1 : 0,
                              (unsigned)c->asbd.mBitsPerChannel,
                              (unsigned)c->asbd.mChannelsPerFrame]
                      : @"(待实时线程补查)");
    }

    AURenderCallbackStruct nl;
    nl.inputProc = VMRenderCB;
    nl.inputProcRefCon = c;
    UInt32 nlSize = (UInt32)sizeof(AURenderCallbackStruct);
    OSStatus r = %orig(inUnit, inID, inScope, inElement, &nl, nlSize);

    // v1.3.0：占用率自证日志 —— 每 32 次包装一行，不受 vmaq-debug 门控。
    // 512 槽下唯一需要盯的指标就是它：平稳低位=健康，持续爬升逼近上限=异常。
    {
        int wc = __sync_add_and_fetch(&gWrapCount, 1);
        if ((wc & 31) == 1) {
            int used = 0;
            pthread_mutex_lock(&gCtxLock);
            for (int i = 0; i < VM_CTX_MAX; i++) if (gCtx[i].used) used++;
            pthread_mutex_unlock(&gCtxLock);
            if (used > gCtxPeak) gCtxPeak = used;
            VMLog(@"ctx 占用 %d/%d（峰值 %d，累计包装 %d）", used, VM_CTX_MAX, gCtxPeak, wc);
        }
    }

    // 布防成功（回调装上且拿到了流格式）→ 渲染回调层接管。
    // 立刻把备用层已写入的 base×系数 回退成 base，避免 factor²。
    if (r == noErr && gotASBD && !gRCArmed) {
        gRCArmed = 1;
        VMLog(@"渲染回调层已布防（ASBD 有效）→ 备用层让位");
        if (gFallbackDirty) {
            VMReapply(gVolume, YES);
            gFallbackDirty = 0;
        }
    }
    return r;
}

// ---- 备用层 1：AudioQueue 参数 ------------------------------------------
// 渲染回调层布防/生效后自动让位，避免 factor² 二次缩放。
%hookf(OSStatus, AudioQueueSetParameter, AudioQueueRef aq, AudioQueueParameterID pid, AudioQueueParameterValue val) {
    if (aq && pid == kAudioQueueParam_Volume && !gRCArmed && !gRCActive && gVolume < 0.999f) {
        float nv = val * gVolume;
        if (!(nv >= 0.0f)) nv = 0.0f;
        if (nv > 1.0f) nv = 1.0f;
        VMLogT([NSString stringWithFormat:@"备用层(AudioQueue) %.4f × %.4f → %.4f",
                (double)val, (double)gVolume, (double)nv]);
        return %orig(aq, pid, nv);
    }
    return %orig(aq, pid, val);
}

// ---- 备用层 2/3/4：AVFoundation 音量入口 --------------------------------
// 统一套路：① 记下 App 传进来的「基准音量」② 需要时缩放 ③ 系数变化时能回写
//   注：这里显式写出三个类，不用宏 —— 因为 play 的返回类型不同
//       （AVPlayer.play 是 void，AVAudioPlayer.play 是 BOOL），
//       %orig 忘了 return 会返回垃圾值，是崩溃常见来源。
%hook AVPlayer
- (void)setVolume:(float)volume {
    if (gReapply) {
        %orig(volume);
        return;
    }
    VMRegSet(self, volume);                       // 先记基准（App 传进来的就是基准）
    float f = gVolume;
    if (f < 0.999f && !gRCArmed && !gRCActive) {
        float nv = volume * f;
        if (!(nv >= 0.0f)) nv = 0.0f;
        if (nv > 1.0f) nv = 1.0f;
        gFallbackDirty = 1;
        VMLogT([NSString stringWithFormat:@"备用层(AVPlayer) %.4f × %.4f → %.4f",
                (double)volume, (double)f, (double)nv]);
        %orig(nv);
        return;
    }
    %orig(volume);
}
- (void)play {
    VMRegSetIfAbsent(self, 1.0f);                 // 默认 1.0，供后续系数变化回写
    %orig;
}
%end

%hook AVAudioPlayer
- (void)setVolume:(float)volume {
    if (gReapply) {
        %orig(volume);
        return;
    }
    VMRegSet(self, volume);
    float f = gVolume;
    if (f < 0.999f && !gRCArmed && !gRCActive) {
        float nv = volume * f;
        if (!(nv >= 0.0f)) nv = 0.0f;
        if (nv > 1.0f) nv = 1.0f;
        gFallbackDirty = 1;
        VMLogT([NSString stringWithFormat:@"备用层(AVAudioPlayer) %.4f × %.4f → %.4f",
                (double)volume, (double)f, (double)nv]);
        %orig(nv);
        return;
    }
    %orig(volume);
}
- (BOOL)play {
    VMRegSetIfAbsent(self, 1.0f);
    return %orig;
}
%end

%hook AVSampleBufferAudioRenderer
- (void)setVolume:(float)volume {
    if (gReapply) {
        %orig(volume);
        return;
    }
    VMRegSet(self, volume);
    float f = gVolume;
    if (f < 0.999f && !gRCArmed && !gRCActive) {
        float nv = volume * f;
        if (!(nv >= 0.0f)) nv = 0.0f;
        if (nv > 1.0f) nv = 1.0f;
        gFallbackDirty = 1;
        VMLogT([NSString stringWithFormat:@"备用层(AVSampleBufferAudioRenderer) %.4f × %.4f → %.4f",
                (double)volume, (double)f, (double)nv]);
        %orig(nv);
        return;
    }
    %orig(volume);
}
%end

%end   // %group VMHooks

// ===========================================================================
// 刷新引擎（非实时）：轮询 + Darwin 通知 → 重算系数 → 分层回写
// ===========================================================================
static NSString *VMStampKey(NSString *p) { return p; }

// 比对 配置 / 同步副本 / 偏好文件 的 size+mtime；任一变化即返回 YES
static BOOL VMStatChanged(void) {
    BOOL changed = NO;
    @try {
        NSMutableArray *paths = [NSMutableArray array];
        if (gCfgPath.length) [paths addObject:gCfgPath];
        [paths addObject:kVMSyncedCopy];
        [paths addObject:kVMPrefsPath];
        for (NSString *p in paths) {
            struct stat st;
            memset(&st, 0, sizeof(st));
            if (VMStat(p, &st) != 0) continue;
            NSArray *now = @[@((long long)st.st_size), @((long long)st.st_mtimespec.tv_sec)];
            NSArray *old = gStamps[VMStampKey(p)];
            if (old) {
                if (![old isEqualToArray:now]) changed = YES;
            } else {
                changed = YES;      // 首次见到 → 也算变化（触发一次刷新，无害）
            }
            gStamps[VMStampKey(p)] = now;
        }
    } @catch (NSException *e) { }
    return changed;
}

// 分层回写：渲染回调层已布防/生效 → 备用层必须退回基准音量（否则 factor²）；
// 否则备用层承担缩放。
static void VMModeSync(void) {
    if (gRCArmed || gRCActive) {
        if (gFallbackDirty) {
            VMReapply(gVolume, YES);
            gFallbackDirty = 0;
        }
    } else {
        VMReapply(gVolume, NO);
        gFallbackDirty = 1;
    }
}

// 重新读配置、重算系数、必要时回写
static void VMRefresh(NSString *reason) {
    @autoreleasepool {
    @try {
        if (!gInstalled) return;
        NSString *bid = VMCurrentBundleId();
        BOOL enabled  = VMPrefsEnabled();

        // 配置路径失效（例如被删掉/换位置）→ 重新探测
        NSDictionary *root = nil;
        NSString *path = gCfgPath;
        if (!path.length) {
            path = VMResolveConfig(&root);
        } else {
            struct stat st;
            if (VMStat(path, &st) != 0) {
                VMLog(@"原配置路径已不可读，重新探测");
                gCfgPath = nil; gCfgDir = nil;
                path = VMResolveConfig(&root);
            } else {
                root = [NSDictionary dictionaryWithContentsOfFile:path];
            }
        }

        float f = 1.0f;
        NSString *why = @"";
        float forced = VMReadForceFile();
        if (!enabled) {
            f = 1.0f; why = @"总开关关闭";
        } else if (forced >= 0.0f && forced <= 1.0f) {
            f = forced; why = @"调试旁路";
        } else if (!path.length || !VMLooksLikeConfig(root)) {
            f = 1.0f; why = @"配置不可读";
        } else {
            NSString *key = nil; float raw = -1.0f; BOOL matched = NO;
            f = VMComputeFactorFrom(root, bid, &key, &raw, &matched);
            if (f > 1.0f) f = 1.0f;
            why = [NSString stringWithFormat:@"配置键=%@ 原值=%.4f 命中=%d",
                   key ?: @"(无)", (double)raw, matched];
        }

        float old = gVolume;
        if (fabsf(f - old) < 0.0005f) return;      // 没变，什么都不做
        gVolume = f;

        VMLog(@"%@：系数 %.4f → %.4f（%@）", reason.length ? reason : @"刷新",
              (double)old, (double)f, why);
        VMModeSync();
    } @catch (NSException *e) {
        VMLog(@"刷新异常: %@", e);
    }
    }
}

// Darwin 通知回调（系统线程，必须快速返回 → 只投递到队列）
static void vmNotifyCB(CFNotificationCenterRef center, void *observer,
                       CFStringRef name, const void *object,
                       CFDictionaryRef userInfo) {
    NSString *n = [(__bridge NSString *)name copy] ?: @"?";
    VMLogT([@"收到通知 " stringByAppendingString:n]);
    if (!gQueue) return;
    dispatch_async(gQueue, ^{ VMRefresh([@"通知(" stringByAppendingString:n]); });
}

// 启动刷新引擎
static void VMStartEngine(void) {
    if (gQueue) return;
    gQueue = dispatch_queue_create("com.local.volmanaudioqueue.refresh", DISPATCH_QUEUE_SERIAL);
    if (!gStamps) gStamps = [NSMutableDictionary dictionary];

    // 先记录一次基线时间戳，避免第一个 tick 误判为“变化”
    if (gCfgPath.length) {
        struct stat st; memset(&st, 0, sizeof(st));
        if (VMStat(gCfgPath, &st) == 0) {
            gStamps[VMStampKey(gCfgPath)] = @[@((long long)st.st_size), @((long long)st.st_mtimespec.tv_sec)];
        }
    }

    // 0.5s 轮询兜底：任何通知漏掉都能兜住
    gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gQueue);
    dispatch_source_set_timer(gTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                              (uint64_t)(0.5 * NSEC_PER_SEC),
                              (uint64_t)(0.1 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(gTimer, ^{
        if (!gCfgPath.length || VMStatChanged()) {
            VMRefresh(@"轮询(文件时间戳变化)");
        } else {
            VMModeSync();      // 渲染回调层中途接管 → 让备用层退回基准
        }
    });
    dispatch_resume(gTimer);

    // 三个通知名全部监听（v0.5.0 的核心修复）
    for (NSString *n in VMNotifyNames()) {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL, vmNotifyCB,
                                        (__bridge CFStringRef)n,
                                        NULL,
                                        CFNotificationSuspensionBehaviorCoalesce);
    }
    VMLog(@"刷新引擎已启动：0.5s 轮询 + 监听 %lu 个通知",
          (unsigned long)VMNotifyNames().count);
}

// ===========================================================================
// 入口
// ===========================================================================
%ctor {
    @autoreleasepool {
        @try {
            NSString *bid  = VMCurrentBundleId();
            BOOL enabled   = VMPrefsEnabled();
            BOOL isSB      = [bid isEqualToString:@"com.apple.springboard"];
            // v1.3.0：Widget/Today 等扩展进程（PluginKitPlugin 容器）不可能出声，
            // 挂钩 + 0.5s 轮询 + 探针日志对它们纯属浪费 —— 与 SpringBoard 同级跳过。
            BOOL isExt     = [NSHomeDirectory() rangeOfString:@"PluginKitPlugin"].location != NSNotFound;
            BOOL skip      = (bid.length == 0) || isSB || isExt;
            gVMAQDebug     = VMAQDebugProbe();

            float forced = VMReadForceFile();

            VMLog(@"=== v1.3.0 注入 | bundle=%@ 总开关=%d 跳过=%d 扩展=%d 调试=%d 调试旁路=%.3f",
                  bid, enabled, skip, isExt, gVMAQDebug, (double)forced);

            // ① 全量路径探测（一次性，把真相写进日志）
            if (!skip) VMProbePaths();

            // ② 定位配置
            NSDictionary *cfgRoot = nil;
            NSString *cfgPath = nil;
            float cfgFactor = 1.0f;
            NSString *cfgKey = nil; float cfgRaw = -1.0f; BOOL cfgMatched = NO;

            if (!skip) {
                cfgPath = VMResolveConfig(&cfgRoot);
                if (cfgPath) {
                    cfgFactor = VMComputeFactorFrom(cfgRoot, bid, &cfgKey, &cfgRaw, &cfgMatched);
                    if (cfgFactor > 1.0f) cfgFactor = 1.0f;
                    VMLog(@"配置解析：文件=%@ 匹配键=%@ 原值=%.6f → 归一化=%.4f 命中=%d",
                          cfgPath, cfgKey ?: @"(无)", (double)cfgRaw, (double)cfgFactor, cfgMatched);
                    if (!cfgMatched && gVMAQDebug) VMDumpConfigOnce(cfgRoot);
                } else {
                    VMLog(@"配置解析：所有候选路径都读不到配置");
                }
            }

            // ②′ 混音策略层：与音量配置完全解耦，无条件安装。
            //     必须无条件 —— 只要有一个参与播放的 App 不是混音的，
            //     它一激活就会把别人掐掉，表现为「有时能同时播、有时不能」。
            if (!skip) {
                VMMixLoadConfig(bid);
                VMMixInstallHooks();
            }

            // ③ 决定是否安装挂钩
            //    v0.5.0 起改为「只要配置存在就安装」——因为系数随时可能变，
            //    必须先把挂钩装好，否则「启动时 1.0 → 之后调小」永远不生效。
            BOOL install = NO;
            NSString *reason = @"";
            if (skip || !enabled) {
                gVolume = 1.0f;
                reason = skip ? (isSB    ? @"关键进程 SpringBoard"
                                 : isExt ? @"扩展进程(Widget/PluginKitPlugin)不出声"
                                         : @"无 bundle id")
                              : @"总开关关闭";
            } else if (forced >= 0.0f && forced <= 1.0f) {
                gVolume = forced;
                install = YES;
                reason = [NSString stringWithFormat:@"调试旁路(配置系数=%.4f)", (double)cfgFactor];
            } else if (!cfgPath) {
                gVolume = 1.0f;
                reason = @"配置缺失（所有候选路径都读不到）";
            } else {
                gVolume = cfgFactor;
                install = YES;
                reason = cfgMatched
                       ? [NSString stringWithFormat:@"配置匹配(%@)=%.4f", cfgKey ?: @"?", (double)cfgFactor]
                       : @"配置存在但本 App 未匹配（系数 1.0，挂钩仍安装以便后续变化）";
            }

            if (install) {
                %init(VMHooks);
                gInstalled = 1;
                VMLog(@"已安装挂钩（原因：%@），本进程音量系数 = %.4f", reason, (double)gVolume);
                VMStartEngine();
            } else {
                gInstalled = 0;
                VMLog(@"不安装音量挂钩（原因：%@），混音层=%d", reason, gMixHooked);
            }
        } @catch (NSException *e) {
            gVolume = 1.0f;
            gInstalled = 0;
            VMLogRaw([NSString stringWithFormat:@"[VMAQ] %%ctor 异常: %@\n", e]);
        }
    }
}
