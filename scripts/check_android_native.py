#!/usr/bin/env python3
"""Verify the PDF engine is bundled and 64-bit ELF files support 16 KB pages.

Usage: python3 scripts/check_android_native.py path/to/app-release.aab
Also accepts APKs. APK ZIP alignment is separately checked by zipalign -c -P 16 4.
"""
import argparse
import struct
import zipfile


def check(path):
    failures = []
    with zipfile.ZipFile(path) as archive:
        libraries = [name for name in archive.namelist() if name.endswith('.so')]
        for abi in ('arm64-v8a', 'armeabi-v7a', 'x86_64'):
            if not any(name.endswith(f'lib/{abi}/libpdf_ffi.so') for name in libraries):
                failures.append(f'Missing PDF engine for {abi}')
        checked = 0
        for name in libraries:
            if '/arm64-v8a/' not in name and '/x86_64/' not in name:
                continue
            data = archive.read(name)
            if data[:6] != b'\x7fELF\x02\x01':
                failures.append(f'{name}: expected a little-endian ELF64 library')
                continue
            offset = struct.unpack_from('<Q', data, 32)[0]
            entry_size, count = struct.unpack_from('<HH', data, 54)
            loads = 0
            writable = []
            relro = []
            for index in range(count):
                kind, flags, file_offset, address, _, _, memory_size, alignment = struct.unpack_from(
                    '<IIQQQQQQ', data, offset + index * entry_size)
                if kind == 1:  # PT_LOAD
                    loads += 1
                    if flags & 2:
                        writable.append((address, address + memory_size))
                    if alignment < 16384 or file_offset % 16384 != address % 16384:
                        failures.append(f'{name}: LOAD segment is not 16 KB aligned')
                if kind == 0x6474E552:
                    relro.append((address, address + memory_size))
            for start, end in relro:
                # Some SDKs end RELRO within padding before the next LOAD.
                # Rounding into unused padding is safe; rounding over mutable
                # data would make that data read-only and crash on a 16 KB OS.
                rounded_end = (end + 16383) // 16384 * 16384
                for load_start, load_end in writable:
                    if max(end, load_start) < min(rounded_end, load_end):
                        failures.append(f'{name}: rounded RELRO overlaps writable data')
            if not loads:
                failures.append(f'{name}: no LOAD segments')
            checked += 1
    if failures:
        raise SystemExit('\n'.join(failures))
    print(f'PASS: PDF engine present for 3 ABIs; {checked} ELF64 libraries support 16 KB alignment.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('artifact')
    check(parser.parse_args().artifact)
