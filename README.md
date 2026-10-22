# VolumeManager iOS 17 修复版

把 iPhone 越狱插件 **VolumeManager（音量管理）** 适配到 **iOS 17 Rootless 越狱**，
并修掉它三个最要命的问题：**播放杂音**、**读不到配置**、**改完音量要重开 App**。

> 已在 **iPhone 15 Pro / iOS 17.2.1 / Rootless 越狱** 实测通过：
> 不进安全模式、无杂音、多 App 同时播放正常、每个 App 的音量单独生效且即时刷新。

**当前版本：v1.2.0**（音量引擎 1.2.0 + 设置面板净化模块 1.1.0）

v1.2.0 变更：

- 新增**混音策略层**：挂钩 `AVAudioSession` 的 `setActive:withOptions:error:`、`setCategory:`
  四个变体与私有 `privateSet*` 入口，在每次会话激活前把会话重新声明为 `MixWithOthers`，
  让多个 App 真正同时播放（细节见下方「混音层」一节）；
- 混音层与音量配置**完全解耦、无条件安装**：只要有一个参与播放的 App 不是混音的，
  它一激活就会把别人掐掉，所以不能只在「有音量配置」的 App 里装；
- 净化模块升级为**双保险**：全量包在打包时把原版面板二进制里的推广文案与链接
  **等长清空并重新签名**，运行时再把整条 specifier 摘掉并拦截残留按钮与链接。
  即使 Preferences 进程收不到注入，静态层依然生效。

v1.1.3 变更：

- 修正净化模块被**打包成 644（缺执行位）**、从而自始至终没被加载的问题 ——
  这才是「净化毫无效果、日志一个字都没有」的真正原因，模块本身没问题；
- 构建流程加入硬断言：包内任何 `.dylib` 没有执行位就直接判定构建失败，
  避免「编译全绿、手机上静默不动」这种最难查的故障；
- 净化模块日志改为**主日志 + `/tmp` 镜像双写**，主路径写不进去时仍有痕迹。

v1.1.1 变更：

- 音量值兼容**字符串存储**（原实现只认数字，配置里写成 `"0.1951…"` 的 App 会被静默当成 1.0）；
- 日志改为**保留尾部**而非整份清空（原实现到 256 KB 就把文件清空到只剩一行，取日志时极易误判为损坏）；
- 净化模块加入**自诊断**：加载即写日志、实测可用日志目录、首次遇到疑似面板时 dump 全部条目，
  用于定位「净化不生效」究竟卡在注入、挂钩还是文案匹配。

> 仓库里只放**源码**，不放编译好的 `.deb`。原因是「全量包」需要打包原版插件的组件，
> 公开分发会涉及原作者的版权；如果你自己要用，按下面的「编译」一节在本机生成即可。

---

## 这个项目解决什么问题

原版 VolumeManager 能做到「按 App 单独调音量」，但在 iOS 17 上有三个缺陷：

| 问题 | 现象 | 根因 |
|---|---|---|
| **杂音** | 刷抖音时个别视频爆出强烈杂音，直播尤其容易复现 | 音量模块替换了 AudioUnit 的渲染回调，却按固定 **4 字节步长** 硬读 Float32。遇到 16 位 PCM 音频流时数据整体错位，原始波形被彻底破坏 |
| **音量调了没反应** | 装好后怎么调都没效果 | Rootless 越狱的真实数据目录是 `/var/jb/var/mobile/Library/...`，原模块写的是不带前缀的裸路径，全靠越狱运行时映射才碰巧能用；自编译模块没走那层映射就永远读不到配置 |
| **不是实时生效** | 每次调完音量必须把 App 杀掉重开 | 原模块监听的是**两个** Darwin 通知，只监听其中一个就会漏掉从 HUD 调音的路径 |

本项目重写了音量引擎（`VolManAudioQueue`），三处一起修：

* **格式感知的渲染回调** —— 先查 `AudioStreamBasicDescription`，按真实格式
  （Float32 / Float64 / SInt16 / SInt32 / SInt8）分派缩放；**遇到不认识的格式一律原样放行**，
  一个字节都不动。宁可不出声，也绝不制造杂音。
* **多路径探测配置** —— 同时尝试 `/var/jb/...`、`/var/mobile/...`、`/.jbroot/...`、
  Preferences 同步副本等多条路径，并正确绕开 libroot 对 `stat()` 的参数改写陷阱。
* **三重刷新机制** —— 监听全部 3 个通知 + 0.5 秒文件时间戳轮询兜底 + 备用层（AVPlayer /
  AVAudioPlayer / AVSampleBufferAudioRenderer）基准音量回写，做到改完即生效。

另外还附带一个 **设置面板净化模块**（`VolManPrefsClean`），两层实现：

- **静态层（只在全量包）**：打包时把原版面板二进制 `VolumeManagerPrefs` 里的
  推广文案、收款 / 源码 / Sileo 链接、以及面板末尾那段针对其他作者的长文按
  **字节等长**清空 —— 长度与结尾 NUL 都不变，Swift 侧的字面量长度常量仍然成立；
  4 条 URL 换成**等长的合法占位链接**（若清成空格，Swift 里 `URL(string:)!`
  会返回 nil，点击即崩），最后用 `ldid -S` 重新签名。
- **运行层**：在 `-setSpecifiers:` / `-specifiers` / `-buttonEvent:` 上摘除条目，
  并拦截 `alipay` / `github` / `sileo` 链接；顺带把作者留下的调试后缀
  `启用混响(isEnabled mixable)` 改成「启用混音」。

**功能开关一个不少**（总开关、混音选项、HUD 显示条件、应用音量列表全部保留）。

> **诊断信息**：运行层会把状态写进 Preferences 自己的偏好域，用 Filza 打开
> `/var/mobile/Library/Preferences/com.apple.Preferences.plist`，查
> `VolManPrefsCleanStatus` 即可看到 `injected` / `hooks base=1 root=1 url=1` /
> `filtered 21→14 dropped=7`。在 RootHide + 白名单注入环境下，如果「设置」进程
> 收不到注入，运行层不生效，但全量包的静态层仍然会把内容清掉。

---

## 混音层（v1.2.0）

原版 VolumeManager 只做「每 App 音量」，**并不保证多个 App 能同时出声**。
v1.2.0 增加了一层独立的混音策略（思路来自对 AudioMix 的逆向，代码完全重写）：

- 真正决定「会不会打断别人」的时刻是 `setActive:YES`，所以在调用原实现之前，
  把当前会话重新声明成 `MixWithOthers`；
- 覆盖公有 `setCategory:` 的四个变体、`setCategory:error:`、`setMode:`，
  以及私有 `privateSetOptions:forCategory:error:`、
  `privateSetCategoryWithOptions:modes:routeSharingPolicy:options:`、
  `isPrimary`、`silenceOutput:error:` —— 私有方法全部**运行期探测，存在才挂**；
- 保留 App 的 `mode` / `routeSharingPolicy` / 已有 options；
  `Record` 完全放行，`PlayAndRecord` 只加混音位、不改类别；
- 与音量配置解耦：无论该 App 有没有音量配置，混音钩子都会安装。

配置（任一文件，找不到就用默认值）：

```
<数据目录>/mixInfo.plist
/var/mobile/Library/Preferences/com.local.volmanaudioqueue.mix.plist
/var/mobile/Library/Preferences/com.sunshinesong.volume-manager-prefs.plist
/tmp/mixInfo.plist
```

| 键 | 默认 | 说明 |
|---|---|---|
| `vmMixEnabled` | YES | 混音层总开关 |
| `vmMixGuard` | NO | 是否拦截 `silenceOutput:error:`（激进防守，开启后可能出现「通话时音乐不停」） |
| `vmMixExcludedApps` | 空 | 不参与混音的 bundle id 数组 |

紧急关闭：在数据目录放一个空文件 `vmaq-mix-off`，重启 App 生效（不用重装）。

> **与原版 `isEnabledMixable` 的关系**：原版主模块里那个开关会**无条件**把类别改成
> `Playback + MixWithOthers`，对「第一个发声的 App」也生效，但会让录音 / 录像类
> App 失去录音能力。它可以与本混音层共存，按需取舍。

---

## 仓库结构

```
src/
  VolManAudioQueue/        每 App 音量引擎（重写版）
    Tweak.xm               全部实现，注释写得很细
    Makefile
    VolManAudioQueue.plist 注入过滤器
  VolManPrefsClean/        设置面板净化模块
    VolManPrefsClean.xm
    Makefile
    VolManPrefsClean.plist 注入过滤器（Bundles = com.apple.UIKit）
tools/
  redact_prefs.py          面板二进制静态净化（等长替换 + 重新签名，全量包打包时调用）
packaging/
  control.patch            补丁包控制信息（建议装在已装原版插件之上）
  control.full             全量包控制信息（一个 deb 装完整套）
  Makefile.patch / Makefile.full
  DEBIAN/                  安装 / 卸载脚本
docs/
  01-杂音根因分析.md
  02-构建与安装.md
  03-净化模块为何静默.md    ← 装上了却没反应、连日志都没有，先看这篇
```

两个包的区别：

* **补丁包**（`com.local.volmanaudioqueue`）—— 只装重写后的音量引擎和净化模块，
  适合**已经装了原版 VolumeManager** 的设备。安装后会把原版有杂音的音量模块改名停用，
  卸载时自动还原。
* **全量包**（`com.local.volmanaudioqueue.full`）—— 自带全套组件（原版主模块、音量 HUD、
  设置面板 + 重写的音量引擎 + 净化模块），适合**全新安装**，一个 deb 解决。

两个包里的 `VolManAudioQueue.dylib` 是同一份代码，md5 一致。

---

## 编译

需要 **Theos** 环境（Linux / macOS / WSL 均可）。

```bash
export THEOS=$HOME/theos
export PATH=$THEOS/bin:$PATH

# 音量引擎
cd src/VolManAudioQueue
make package FINALPACKAGE=1

# 设置面板净化模块
cd ../VolManPrefsClean
make package FINALPACKAGE=1
```

全量包还需要一步**静态净化**（把原版面板二进制里的推广文案与链接清掉），
必须在 `make package` 之前执行，否则发布出去的包里仍带着原文案：

```bash
BIN=layout/Library/PreferenceBundles/VolumeManagerPrefs.bundle/VolumeManagerPrefs
python3 tools/redact_prefs.py "$BIN"          # 等长替换，长度不变
"$THEOS/toolchain/linux/iphone/bin/ldid" -S "$BIN"   # 重新签名
```

关键编译选项（不要随意改）：

```make
ARCHS = arm64                     # 必须单切片，见下方说明
TARGET = iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME = rootless   # 根前缀 /var/jb
```

> ⚠️ **为什么 `ARCHS` 必须只有 arm64？**
> iOS 15 之后系统对 arm64e 切片的 ABI 版本有要求。用较旧的工具链编出来的 arm64e
> 切片带的是旧 ABI 标记（`cpusubtype = 0x00000002`），系统进程加载时会直接进**安全模式**；
> 而 arm64 单切片不受这条限制。

---

## 安装

1. 把 `packages/*.deb` 传到 iPhone，用 **Sileo** 或 Filza 安装；
2. 安装完执行一次 **respring（注销）**；
3. 打开 **设置 → VolumeManager**，给需要单独调音量的 App 设一个值即可。

调完后如果某个 App 的音量没变，先确认那 App 正在播放音频再调一次 —— 音量是在音频流建立后才挂钩的。

---

## 已知边界

* 只处理**媒体播放类**音频（AudioToolbox / AVFoundation 路径）。系统提示音、来电铃声不在此列。
* 渲染回调对**不认识的采样格式**会主动放弃处理（放行原始数据），这些格式下音量不会变化，
  但也不会出现杂音。
* 净化分两层：静态层按**原文案**定位，原作者若改版会导致构建期直接报错中止
  （不会产出半成品包）；运行层按**关键词**兜底，但改版后仍可能漏掉新文案。
* 混音层只在**会话激活时**改写策略，因此改造前就已经在放音的 App 需要重启才会走新逻辑。

---

## 免责声明

* 本项目只包含**自己重写的代码**，不包含原插件 `VolumeManager` 的任何二进制文件。
  原插件版权归其原作者所有。
* 越狱、安装第三方插件存在风险，请自行判断，风险自负。
* 仅供个人学习与研究使用。
