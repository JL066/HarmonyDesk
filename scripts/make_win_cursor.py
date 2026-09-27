import os
import struct
import zlib
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CUR = Path(os.environ.get("HARMONY_CURSOR_SOURCE", Path(os.environ.get("WINDIR", r"C:\Windows")) / "Cursors" / "aero_arrow_xl.cur"))
OUT = REPO_ROOT / "ohos" / "entry" / "src" / "main" / "resources" / "base" / "media" / "win_cursor.png"


def chunk(tag: bytes, data: bytes) -> bytes:
    crc = zlib.crc32(tag + data) & 0xFFFFFFFF
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)


def write_png(path: Path, width: int, height: int, rgba: bytes) -> None:
    raw = b""
    stride = width * 4
    for y in range(height):
        raw += b"\x00" + rgba[y * stride:(y + 1) * stride]
    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(png)


def extract_best(data: bytes) -> tuple[int, int, bytes]:
    count = int.from_bytes(data[4:6], "little")
    best = None
    off = 6
    for _ in range(count):
        size = int.from_bytes(data[off + 8:off + 12], "little")
        imgoff = int.from_bytes(data[off + 12:off + 16], "little")
        bi_size, width, height, _planes, bpp, _comp, _img = struct.unpack_from("<IiiHHII", data, imgoff)
        xor_h = abs(height) // 2 if abs(height) >= 2 * abs(width) else abs(height)
        if bpp == 32 and xor_h == 64:
            pixels = decode_32(data, imgoff + bi_size, width, xor_h)
            return width, xor_h, pixels
        if bpp == 32:
            best = (imgoff, bi_size, width, xor_h)
        off += 16
    if best is None:
        raise RuntimeError("no 32-bit cursor image")
    imgoff, bi_size, width, xor_h = best
    return width, xor_h, decode_32(data, imgoff + bi_size, width, xor_h)


def decode_32(data: bytes, pix_off: int, width: int, height: int) -> bytes:
    row = width * 4
    rgba = bytearray(width * height * 4)
    opaque = 0
    for y in range(height):
        src = pix_off + (height - 1 - y) * row
        dst = y * row
        for x in range(width):
            b, g, r, a = data[src + x * 4:src + x * 4 + 4]
            rgba[dst + x * 4:dst + x * 4 + 4] = bytes((r, g, b, a))
            if a:
                opaque += 1
    if opaque == 0:
        mask_off = pix_off + row * height
        mask_stride = ((width + 31) // 32) * 4
        for y in range(height):
            src = mask_off + (height - 1 - y) * mask_stride
            dst = y * row
            for x in range(width):
                bit = (data[src + (x // 8)] >> (7 - (x % 8))) & 1
                if bit == 0:
                    rgba[dst + x * 4 + 3] = 255
    return bytes(rgba)


def crop_opaque(width: int, height: int, rgba: bytes) -> tuple[int, int, bytes]:
    min_x, min_y = width, height
    max_x, max_y = 0, 0
    for y in range(height):
        for x in range(width):
            if rgba[(y * width + x) * 4 + 3] > 16:
                if x < min_x:
                    min_x = x
                if y < min_y:
                    min_y = y
                if x > max_x:
                    max_x = x
                if y > max_y:
                    max_y = y
    if max_x < min_x:
        return width, height, rgba
    min_x = max(0, min_x - 1)
    min_y = max(0, min_y - 1)
    max_x = min(width - 1, max_x + 1)
    max_y = min(height - 1, max_y + 1)
    cw = max_x - min_x + 1
    ch = max_y - min_y + 1
    out = bytearray(cw * ch * 4)
    for y in range(ch):
        src = ((min_y + y) * width + min_x) * 4
        dst = y * cw * 4
        out[dst:dst + cw * 4] = rgba[src:src + cw * 4]
    return cw, ch, bytes(out)


def main() -> None:
    width, height, rgba = extract_best(CUR.read_bytes())
    width, height, rgba = crop_opaque(width, height, rgba)
    write_png(OUT, width, height, rgba)
    opaque = sum(1 for i in range(3, len(rgba), 4) if rgba[i] > 0)
    print(f"wrote {OUT} {width}x{height} opaque={opaque} bytes={OUT.stat().st_size}")


if __name__ == "__main__":
    main()
