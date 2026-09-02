"""Dump offset/length/inflated size and the first 64 bytes of one chunk.
Usage: python3 tools/dump.py <region.mca> <idx>
"""
import struct, sys, zlib
path, idx = sys.argv[1], int(sys.argv[2])
raw = open(path,"rb").read()
e = raw[idx*4:idx*4+4]
off = (e[0]<<16)|(e[1]<<8)|e[2]; cnt = e[3]
print(f"idx={idx} offset_sector={off} sectors={cnt} filesize={len(raw)} totalsectors={len(raw)//4096}")
s = off*4096
(ln,) = struct.unpack(">I", raw[s:s+4]); ct = raw[s+4]
print(f"declared length={ln} comptype={ct}  (payload {ln-1} bytes, allocated {cnt*4096})")
data = raw[s+5:s+5+ln-1]
d = zlib.decompressobj()
out = d.decompress(data)
print(f"inflated={len(out)} bytes  unused_tail={len(d.unused_data)} eof={d.eof}")
print("first 64 bytes:", out[:64].hex(" "))
print("printable:", "".join(chr(b) if 32<=b<127 else "." for b in out[:64]))
