#!/usr/bin/env python3
"""把 Android tombstone 里 libaqt_client_ffi.so 的裸地址还原成 Rust 符号。

release profile 里 `strip = true`，线上 .so 没有 symtab，llvm-symbolizer 直接
用不了。这个脚本走两步：

1. **认版本**。tombstone 只给 "base.apk (offset 0x...)"，认不出是哪个 .so、
   更认不出是哪次构建。判据是：libunwindstack 打印的 rel_pc 对非栈顶帧已经
   减过 4，所以每个 pc 都应当正好落在一条 BL/BLR 上。拿候选 .so 挨个验，命中
   率 18/18 的那个就是用户装的那份；版本不对的话命中率掉到 ~15%。

2. **配符号**。用 `strip=false` 重建一份带 symtab 的 .so —— 它的 .text 通常
   跟线上那份**不字节一致**（依赖/NDK 的微小漂移就够了），所以不能按地址直接
   套。改成按函数内容配对：用 .eh_frame 的 FDE 切出函数边界，把 BL/B 的 imm26
   和 ADRP 的立即数掩掉（这些随布局变，指令序列本身不变）再哈希，唯一哈希互相
   匹配的即为同一函数。种子配好之后沿调用图传播（已配对函数的 callee 序列按调用点
   偏移一一对应），覆盖率能从 ~42% 提到 ~75%。

用法：
    # 1) 重建带符号的 .so
    cd rust && PATH=$HOME/.cargo/bin:$PATH \\
      ANDROID_NDK_HOME=/opt/android-sdk/ndk/26.3.11579264 \\
      cargo ndk -t arm64-v8a build --release -p aqt_client_ffi \\
      --target-dir /tmp/symbuild --config 'profile.release.strip=false'

    # 2) 把 tombstone 里的 pc 列表喂进来
    python3 scripts/symbolize_native_crash.py \\
      --target android/app/src/main/jniLibs/arm64-v8a/libaqt_client_ffi.so \\
      --symbols /tmp/symbuild/aarch64-linux-android/release/libaqt_client_ffi.so \\
      --pcs 0x1a0b04 0xd9974 0xed8f0 ...

`--verify-only` 只跑第 1 步，用来在一堆候选 .so 里认出线上那份。
"""

import argparse
import bisect
import hashlib
import re
import struct
import subprocess
import sys
from collections import defaultdict


def _sections(path):
    out = subprocess.run(['readelf', '-SW', path], capture_output=True, text=True).stdout
    d = {}
    for line in out.splitlines():
        m = re.match(r'\s*\[\s*\d+\]\s+(\S+)\s+\S+\s+([0-9a-f]+)\s+([0-9a-f]+)\s+([0-9a-f]+)', line)
        if m:
            d[m.group(1)] = (int(m.group(2), 16), int(m.group(3), 16), int(m.group(4), 16))
    return d


def _fdes(path):
    """函数边界。.eh_frame 即使 strip 过也还在（backtrace 要用）。"""
    out = subprocess.run(['readelf', '--debug-dump=frames-interp', path],
                         capture_output=True, text=True).stdout
    return sorted(set(
        (int(m.group(1), 16), int(m.group(2), 16))
        for m in re.finditer(r'FDE cie=[0-9a-f]+ pc=([0-9a-f]+)\.\.([0-9a-f]+)', out)
    ))


def _symtab(path):
    out = subprocess.run(['readelf', '-sW', path], capture_output=True, text=True).stdout
    d = {}
    for line in out.splitlines():
        q = line.split()
        if len(q) >= 8 and q[3] == 'FUNC':
            try:
                d[int(q[1], 16)] = ' '.join(q[7:])
            except ValueError:
                pass
    return d


def _fingerprint(data, off, size):
    """掩掉随布局漂移的立即数后再哈希，这样同一份源码在两次构建里指纹相同。"""
    b = bytearray(data[off:off + size])
    for i in range(0, size - 3, 4):
        w = struct.unpack_from('<I', b, i)[0]
        if (w >> 26) in (0b100101, 0b000101):        # BL / B
            w &= 0xFC000000
        elif (w & 0x9F000000) == 0x90000000:          # ADRP
            w &= 0x9F00001F
        struct.pack_into('<I', b, i, w)
    return hashlib.md5(bytes(b)).hexdigest()


class Image:
    def __init__(self, path):
        self.path = path
        sec = _sections(path)
        if '.text' not in sec:
            raise SystemExit(f'{path}: 读不到 .text')
        self.va, self.off, self.size = sec['.text']
        self.data = open(path, 'rb').read()
        self.fns = [(a, b) for a, b in _fdes(path) if self.va <= a < self.va + self.size]
        self.starts = [a for a, _ in self.fns]

        self.fp = defaultdict(list)
        for a, b in self.fns:
            self.fp[_fingerprint(self.data, self.off + (a - self.va), b - a)].append(a)

        self.calls = defaultdict(list)
        self.callers = defaultdict(list)
        for a, b in self.fns:
            for i in range(a, b, 4):
                w = struct.unpack_from('<I', self.data, self.off + (i - self.va))[0]
                if (w >> 26) != 0b100101:             # 只跟 BL
                    continue
                imm = w & 0x03FFFFFF
                if imm & 0x02000000:
                    imm -= 0x04000000
                tgt = i + imm * 4
                j = bisect.bisect_right(self.starts, tgt) - 1
                if j >= 0 and self.fns[j][0] == tgt:
                    self.calls[a].append((i - a, tgt))
                    self.callers[tgt].append((a, i - a))

    def insn(self, vaddr):
        return struct.unpack_from('<I', self.data, self.off + (vaddr - self.va))[0]

    def fn_of(self, pc):
        j = bisect.bisect_right(self.starts, pc) - 1
        return self.fns[j] if j >= 0 else None

    def call_hit_rate(self, pcs):
        """非栈顶帧的 pc 应当正好压在一条 BL/BLR 上 —— 版本对不对就看这个。"""
        ok = tot = 0
        for pc in pcs:
            if not (self.va <= pc < self.va + self.size):
                continue
            tot += 1
            w = self.insn(pc)
            if (w >> 26) == 0b100101 or (w & 0xFFFFFC1F) == 0xD63F0000:
                ok += 1
        return ok, tot


def match_functions(target, syms):
    """唯一指纹配种子，再沿调用图传播。返回 {target 函数起址: syms 函数起址}。"""
    fwd, back = {}, {}
    for fp, tl in target.fp.items():
        sl = syms.fp.get(fp)
        if len(tl) == 1 and sl and len(sl) == 1:
            fwd[tl[0]] = sl[0]
            back[sl[0]] = tl[0]
    seeds = len(fwd)

    while True:
        added = 0
        for t, s in list(fwd.items()):
            tc, sc = target.calls.get(t, []), syms.calls.get(s, [])
            if tc and len(tc) == len(sc):
                for (to, tt), (so, ss) in zip(tc, sc):
                    if to == so and tt not in fwd and ss not in back:
                        fwd[tt] = ss
                        back[ss] = tt
                        added += 1
            tu, su = target.callers.get(t, []), syms.callers.get(s, [])
            if len(tu) == 1 and len(su) == 1 and tu[0][1] == su[0][1]:
                tt, ss = tu[0][0], su[0][0]
                if tt not in fwd and ss not in back:
                    fwd[tt] = ss
                    back[ss] = tt
                    added += 1
        if not added:
            break
    return fwd, seeds


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--target', required=True, help='线上（stripped）.so')
    ap.add_argument('--symbols', help='strip=false 重建出来的同源 .so')
    ap.add_argument('--pcs', nargs='+', required=True, help='tombstone 里的 pc，栈顶在前')
    ap.add_argument('--verify-only', action='store_true', help='只验版本，不做符号化')
    args = ap.parse_args()

    pcs = [int(p, 16) if p.startswith('0x') else int(p, 16) for p in args.pcs]
    target = Image(args.target)

    # 栈顶是出错指令本身，不是返回地址，不参与 BL 校验
    ok, tot = target.call_hit_rate(pcs[1:])
    print(f'版本校验：{ok}/{tot} 个 pc 落在 call 指令上', end='  ')
    if tot and ok == tot:
        print('→ 版本吻合')
    elif tot and ok >= tot * 0.9:
        print('→ 大概率吻合')
    else:
        print('→ 版本不符，换一份 .so')
        if not args.verify_only:
            return 1
    if args.verify_only:
        return 0

    if not args.symbols:
        print('缺 --symbols，只能给出函数边界', file=sys.stderr)
        names, fwd = {}, {}
    else:
        syms = Image(args.symbols)
        names = _symtab(args.symbols)
        fwd, seeds = match_functions(target, syms)
        print(f'函数配对：种子 {seeds} → 传播后 {len(fwd)} / {len(target.fns)}\n')

    for i, pc in enumerate(pcs):
        span = target.fn_of(pc)
        if span is None:
            print(f'#{i:02d} {pc:#x}  <不在 .text 内>')
            continue
        a, b = span
        s = fwd.get(a)
        name = names.get(s, '<无名>') if s else '???'
        print(f'#{i:02d} {pc:#x}  fn={a:#x}+{pc - a:#x} ({b - a}B)')
        print(f'     {name}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
