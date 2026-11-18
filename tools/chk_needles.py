import sys
def u16(s): return s.encode('utf-16-le')
needles={'knownlist_u16(v03)': u16('已知类清单'), 'sweep_u16(v02+)': u16('扫描补丁'), 'zh_u16': u16('方法表'), 'sweeplog_u16(v02+)': u16('命中 VM 窗口')}
d=open(sys.argv[1],'rb').read()
print(sys.argv[1].split('/')[-1], len(d), {k: d.count(v) for k, v in needles.items()})
