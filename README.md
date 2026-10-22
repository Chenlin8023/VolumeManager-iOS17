# VolumeManager iOS 17 修复版

把 iPhone 越狱插件 **VolumeManager（音量管理）** 适配到 **iOS 17 Rootless 越狱**，
并修掉它三个最要命的问题：**播放杂音**、**读不到配置**、**改完音量要重开 App**。

> 已在 **iPhone 15 Pro / iOS 17.2.1 / Rootless 越狱** 实测通过：
> 不进安全模式、无杂音、多 App 同时播放正常、每个 App 的音量单独生效且即时刷新。

**当前版本：v1.1.3**（音量引擎 1.1.3 + 设置面板净化模块 1.0.3）

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

另外还附带一个 **设置面板净化模块**（`VolManPrefsClean`）：

原设置界面里有一堆和功能无关的东西 —— 支付宝打赏条目和收款二维码链接、GitHub 关注链接、
查看源码链接、Sileo 源、反盗版声明，以及面板末尾一大段针对其他插件作者的文字。
本模块在运行时把这些条目从列表里摘掉，**功能开关一个不少**（总开关、HUD 显示条件、
混音选项、应用音量列表全部保留）。

> **实测限制（很重要）**：在 **RootHide 系越狱 + 按 App 白名单注入**的环境下，
> 系统「设置」进程可能根本收不到注入 —— 即使白名单里已经把「设置」勾选打开。
> 已在 iPhone 15 Pro / iOS 17.2.1 / RootHide 实测：同期 `irisin`、`Filza`、`Sileo`、
> 以及各家 Widget 扩展全部正常注入，唯独 `com.apple.Preferences` 一次都没有。
> 这种情况下本模块不会生效，且不会造成任何副作用。
> 若你的越狱默认全量注入（不搞白名单），一般可以直接工作。

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
* 设置面板的那段净化逻辑是按**文案匹配**做的。原作者若日后改了界面文案，净化可能失效，
  但不会造成崩溃。

---

## 免责声明

* 本项目只包含**自己重写的代码**，不包含原插件 `VolumeManager` 的任何二进制文件。
  原插件版权归其原作者所有。
* 越狱、安装第三方插件存在风险，请自行判断，风险自负。
* 仅供个人学习与研究使用。
