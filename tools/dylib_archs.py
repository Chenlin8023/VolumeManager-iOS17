#!/usr/bin/env python3
"""打印 Mach-O 薄片 / FAT 的架构名，输出语义与 `lipo -archs` 对齐。

背景：构建机 WSL 发行版没有 lipo（Xcode 工具），build-rootless.sh 的
「架构核验」段此前静默空转（not found 被吞掉）——硬断言不能是摆设，
这是 lipo 缺席时的兜底判定。

用法: dylib_archs.py <macho...>   （每行输出「路径: 架构列表」）
"""
import struct
import sys


def arch_name(cputype: int, cpusubtype: int) -> str:
    st = cpusubtype & 0x7FFFFFFF
    if cputype == 0x0100000C:
        return 'arm64e' if st == 2 else 'arm64'
    if cputype == 0x0000000C:
        return 'arm'
    if cputype == 0x01000007:
        return 'x86_64'
    return 'cpu0x%x' % cputype


def main(paths):
    for f in paths:
        with open(f, 'rb') as fh:
            d = fh.read(8192)
        if len(d) < 8:
            print(f'{f}: too-short')
            continue
        # 薄片：磁盘字节 cf fa ed fe（头字段 LE）；FAT：磁盘字节 ca fe ba be（字段 BE）。
        # 魔数按原始字节比较，避开 '>I'/'<I' 两种读法各自的字节序坑。
        if d[:4] == b'\xcf\xfa\xed\xfe':
            ct, st = struct.unpack_from('<ii', d, 4)
            print(f'{f}: {arch_name(ct, st)}')
        elif d[:4] == b'\xca\xfe\xba\xbe':
            # fat_arch={cpu,sub,offset,size,align}=20B，从偏移 8 开始。
            n = struct.unpack_from('>I', d, 4)[0]
            names = [arch_name(*struct.unpack_from('>II', d, 8 + 20 * i))
                     for i in range(min(n, 8))]
            print(f'{f}: {" ".join(names)}')
        else:
            print(f'{f}: unknown-magic({d[:4].hex()})')


if __name__ == '__main__':
    main(sys.argv[1:])
