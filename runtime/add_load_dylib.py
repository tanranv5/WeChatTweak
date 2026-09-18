#!/usr/bin/env python3
"""
add_load_dylib.py — 向 Mach-O（支持 FAT）添加 LC_LOAD_WEAK_DYLIB
用法: add_load_dylib.py <binary> <install_name>
原理: 各 slice 的 load commands 区后面通常有空隙（对齐填充），
      把插入点之后的 load commands 后移，腾出头部空间放新命令。
注意: 新 LC 必须插在所有 dylib LC 之后 —— 插到前面会把已有 import ordinal
      全部 +1，而 bind 表中的 ordinal 是静态编码的，会导致符号全部错位
      （实测 dyld 报 dyld_stub_binder not found）。
"""
import struct, sys

LC_LOAD_WEAK_DYLIB = 0x18 | 0x80000000   # LC_REQ_DYLD flag required
DYLIB_CMDS = (0xc, 0xd, 0x80000018)      # LOAD / ID / LOAD_WEAK

def align(v, a):
    return (v + a - 1) & ~(a - 1)

def process_slice(buf, slice_off, name):
    (magic, cput, cpus, ft, ncmds, szcmds, flags, res) = struct.unpack_from('<IiiIIIII', buf, slice_off)
    is64 = (magic == 0xfeedfacf)
    hsize = 32 if is64 else 28
    cmds_off = slice_off + hsize

    # 扫 load commands：最后一条的结束位置 + 最后一条 dylib LC 的结束位置
    off = cmds_off
    last_end = cmds_off
    last_dylib_end = cmds_off
    for _ in range(ncmds):
        cmd, cs = struct.unpack_from('<II', buf, off)
        if cmd in DYLIB_CMDS:
            last_dylib_end = off + cs
        last_end = off + cs
        off += cs

    cmdsize = align(24 + len(name) + 1, 8)

    # 空隙检查：last_end 之后必须有不少于 cmdsize 的全 0 填充
    room = 0
    p = last_end
    while p < len(buf) and buf[p] == 0 and room < 0x400:
        room += 1; p += 1
    if room < cmdsize:
        raise SystemExit(f'slice@{slice_off:#x}: no room after load commands (room={room}, need={cmdsize})')

    # 在 last_dylib_end 处插入：把 [last_dylib_end, last_end) 后移 cmdsize，
    # 空出的 cmdsize 写新 LC。前面已有 dylib LC 的位置不动 → ordinal 不变。
    shift = cmdsize
    tail = bytes(buf[last_dylib_end:last_end])
    buf[last_dylib_end+shift:last_end+shift] = tail
    lc = struct.pack('<IIIIII', LC_LOAD_WEAK_DYLIB, cmdsize, 24, 0, 0x10000, 0) + name + b'\0'
    lc = lc.ljust(cmdsize, b'\0')
    assert len(lc) == cmdsize
    buf[last_dylib_end:last_dylib_end+cmdsize] = lc
    # 更新 ncmds/sizeofcmds
    struct.pack_into('<II', buf, slice_off+16, ncmds+1, szcmds+cmdsize)
    print(f'  slice@{slice_off:#x}: inserted LC_LOAD_WEAK_DYLIB (ncmds {ncmds}->{ncmds+1})')

def main():
    binary, name = sys.argv[1], sys.argv[2]
    name_b = name.encode()
    with open(binary, 'rb') as f:
        buf = bytearray(f.read())

    (magic,) = struct.unpack_from('>I', buf, 0)
    if magic in (0xcafebabe, 0xcafebabf):
        (n,) = struct.unpack_from('>I', buf, 4)
        off = 8
        slices = []
        for _ in range(n):
            cput, cpus, foff, fsz, al = struct.unpack_from('>iiIII', buf, off)
            slices.append(foff)
            off += 20
        for so in slices:
            process_slice(buf, so, name_b)
    else:
        process_slice(buf, 0, name_b)

    with open(binary, 'wb') as f:
        f.write(buf)
    print(f'done: {binary} -> {name}')

if __name__ == '__main__':
    main()
