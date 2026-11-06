#!/usr/bin/env python3
"""Check a real Ethernet/IPv6 registration capture without third-party packages."""
import ipaddress
import struct
import sys
from pathlib import Path

capture, source, target, mac = sys.argv[1:]
data = Path(capture).read_bytes()
assert data[:4] in (b'\xd4\xc3\xb2\xa1', b'\xa1\xb2\xc3\xd4'), 'expected pcap'
endian = '<' if data[:4] == b'\xd4\xc3\xb2\xa1' else '>'
assert struct.unpack_from(endian + 'I', data, 20)[0] == 1, 'expected Ethernet'
size = struct.unpack_from(endian + 'I', data, 32)[0]
frame = data[40:40 + size]
assert frame[6:12] == bytes.fromhex(mac.replace(':', '')), 'Ethernet source MAC'
assert frame[12:14] == b'\x86\xdd'
ip = frame[14:54]
assert ip[0] >> 4 == 6 and ip[6:8] == b'\x3a\xff', 'ICMPv6/hop limit'
assert ip[8:24] == ipaddress.IPv6Address(source).packed, 'IPv6 source'
expected_target = ipaddress.IPv6Address(target).packed
assert ip[24:40] == b'\xff\x02' + b'\x00' * 9 + b'\x01\xff' + expected_target[-3:], 'solicited-node multicast'
length = struct.unpack_from('!H', ip, 4)[0]
ns = frame[54:54 + length]
assert len(ns) == 32 and ns[:2] == b'\x87\x00', 'NS type/code/length'
assert ns[8:24] == expected_target, 'NS target'
assert ns[24:] == b'\x01\x01' + frame[6:12], 'source link-layer option'
pseudo = ip[8:40] + struct.pack('!I', len(ns)) + b'\x00\x00\x00\x3a' + ns
if len(pseudo) % 2:
    pseudo += b'\x00'
checksum = sum(struct.unpack('!' + 'H' * (len(pseudo) // 2), pseudo))
while checksum >> 16:
    checksum = (checksum & 65535) + (checksum >> 16)
assert checksum == 65535, f'ICMPv6 checksum: {checksum:04x}'
print(f'{source}: registration source, target, checksum, hop limit and MAC passed')
