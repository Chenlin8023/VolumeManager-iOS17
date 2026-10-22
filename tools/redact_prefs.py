#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""设置面板二进制静态净化（等长替换）

原理：
  VolumeManager 的 Preferences 面板是 Swift 编译产物，推广文案 / 链接 / 攻击性
  长文都是 __TEXT,__cstring 里的 NUL 结尾 C 字符串。这里按「字节长度不变」的原则，
  把它们整段替换成空格：
    · 长度不变 → Swift 侧的字面量长度常量仍然成立，不会越界、不会截断；
    · NUL 保留   → 仍是合法 C 字符串，运行时得到空串；
    · 只动 __cstring，不碰代码、不改偏移。

用法：
  python3 redact_prefs.py <VolumeManagerPrefs 二进制>

幂等：已经净化过的文件再次执行不会报错，只会提示“已处理”。
"""

import sys, struct

# ---- URL：替换成等长的合法 URL ----
# 不能填空格：Swift 里常见 URL(string: "...")! 强制解包，空格会返回 nil → 点击即崩。
# 用 https://0.0.0.0/ + 填充字符，长度与原串完全一致，URL 解析一定成功。
URL_PREFIX = "https://0.0.0.0/"
URLS = [
    "https://qr.alipay.com/tsx16073sp9uagherfgnn4b",
    "https://github.com/ugly-soul/VolumeManager",
    "https://github.com/ugly-soul",
    "sileo://source/https://ugly-soul.github.io/repo/",
]

# ---- 仅用于显示的文本：整段填成空格 ----
EXACT = [
    # 推广条目文案
    "请杯咖啡, 动力十足。(thanks)!",
    "请我喝杯咖啡(支付宝)",
    "follow me.(GitHub)",
    "关注我(GitHub)",
    "查看源码(GitHub)",
    "拒绝盗版，从我做起!",
    "在Sileo添加我的源",
    # 功能介绍里那句指向 GitHub 的补充说明（前半句「开启控制…显示条件。」保留）
    "如果选择其他方式，则可以通过其他插件控制显示，具体适配方式后续我会在GitHub上说明。",
]

# ---- 以某段开头、需要清到 NUL 为止的字符串 ----
PREFIX = [
    "说在最后的话",          # 整段针对其他插件作者的长文
]

FILL = 0x20  # 空格


def slices(buf):
    if struct.unpack(">I", buf[:4])[0] not in (0xCAFEBABE, 0xCAFEBABF):
        return [(0, len(buf))]
    n = struct.unpack(">I", buf[4:8])[0]
    out = []
    for i in range(n):
        ct, cs, off, size, _ = struct.unpack(">5I", buf[8 + i * 20:28 + i * 20])
        out.append((off, size))
    return out


def url_fill(n):
    """等长的合法 URL：https://0.0.0.0/ + aaaa…"""
    p = URL_PREFIX.encode()
    if n <= len(p):
        return b" " * n
    return p + b"a" * (n - len(p))


def collect_spans(data):
    spans, missing = [], []
    for s in URLS:
        b = s.encode("utf-8")
        start = 0
        hits = 0
        while True:
            i = data.find(b, start)
            if i < 0:
                break
            spans.append((i, i + len(b), "url"))
            start = i + len(b)
            hits += 1
        if hits == 0:
            missing.append(s[:24])
    for s in EXACT:
        b = s.encode("utf-8")
        start = 0
        hits = 0
        while True:
            i = data.find(b, start)
            if i < 0:
                break
            spans.append((i, i + len(b), "blank"))
            start = i + len(b)
            hits += 1
        if hits == 0:
            missing.append(s[:24])
    for p in PREFIX:
        b = p.encode("utf-8")
        start = 0
        hits = 0
        while True:
            i = data.find(b, start)
            if i < 0:
                break
            end = data.find(b"\x00", i)
            if end < 0:
                end = i + len(b)
            spans.append((i, end, "blank"))
            start = end + 1
            hits += 1
        if hits == 0:
            missing.append(p + "…")
    return spans, missing


def merge(spans):
    """把重叠区间合并；同类才合并（URL 与文本不会重叠）"""
    spans.sort(key=lambda x: (x[0], x[1]))
    out = []
    for a, b, kind in spans:
        if out and a <= out[-1][1] and out[-1][2] == kind:
            out[-1] = (out[-1][0], max(out[-1][1], b), kind)
        elif out and a < out[-1][1]:
            # 不同类型重叠：保守起见各自保留，后一个从前者末尾开始
            if b > out[-1][1]:
                out.append((out[-1][1], b, kind))
        else:
            out.append((a, b, kind))
    return out


def main(path):
    raw = bytearray(open(path, "rb").read())
    orig_size = len(raw)
    total = 0
    all_missing = []

    for si, (off, size) in enumerate(slices(bytes(raw))):
        data = bytes(raw[off:off + size])
        spans, missing = collect_spans(data)
        all_missing += missing
        if not spans:
            continue
        merged = merge(spans)
        for a, b, kind in merged:
            n = b - a
            fill = url_fill(n) if kind == "url" else b" " * n
            raw[off + a:off + b] = fill
            total += n
        print(f"  slice {si}: 清除 {len(merged)} 段 / {sum(b-a for a,b,k in merged)} 字节")

    # 断言：长度不变
    if len(raw) != orig_size:
        raise SystemExit("!! 文件长度被改变，中止")

    open(path, "wb").write(raw)

    # 复查：原始目标串应已不存在
    check = bytes(raw)
    left = [s for s in EXACT if s.encode("utf-8") in check]
    left += [s for s in URLS if s.encode("utf-8") in check]
    left += [p for p in PREFIX if p.encode("utf-8") in check]
    if left:
        raise SystemExit("!! 仍有未清除内容：" + " / ".join(x[:20] for x in left))

    print(f"  共清除 {total} 字节；文件长度保持 {orig_size} 字节")
    if all_missing:
        # 某些版本可能本身就没有某几条，属于正常
        print("  未找到（可能该版本已被处理过或文案不同）：" + " / ".join(sorted(set(all_missing))))
    print("  复查通过：目标文案/链接已不存在")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit("用法: redact_prefs.py <二进制路径>")
    print(f"净化 {sys.argv[1]}")
    main(sys.argv[1])
