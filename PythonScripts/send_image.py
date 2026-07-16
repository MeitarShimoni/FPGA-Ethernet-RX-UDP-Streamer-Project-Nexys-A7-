#!/usr/bin/env python3
"""
send_image.py -- read an image file, convert to RGB565, and stream it to the
FPGA in self-describing UDP chunks.

Chunk payload layout (big-endian, matching the RTL consumer):
    [ image_id (2B) | byte_offset (4B) | length (2B) | pixel data ... ]

Usage:
    python send_image.py picture.jpg
    python send_image.py picture.png --width 320 --height 240 --fps 5

Requires:  pip install pillow numpy
"""

import argparse
import socket
import struct
import time

import numpy as np
from PIL import Image

CHUNK_PIXEL_BYTES = 1440          # pixel bytes per UDP frame (720 px in RGB565)
DEST = ("192.168.1.255", 5000)    # broadcast to the FPGA's listen port


def image_to_rgb565(path: str, width: int, height: int) -> bytes:
    """Load, resize, and convert an image to big-endian RGB565 raw bytes."""
    img = Image.open(path).convert("RGB").resize((width, height))
    a = np.asarray(img, dtype=np.uint16)             # H x W x 3

    r = (a[:, :, 0] >> 3) & 0x1F                     # 5 bits red
    g = (a[:, :, 1] >> 2) & 0x3F                     # 6 bits green
    b = (a[:, :, 2] >> 3) & 0x1F                     # 5 bits blue
    rgb565 = (r << 11) | (g << 5) | b                # H x W, uint16

    return rgb565.astype(">u2").tobytes()            # big-endian on the wire


def checksum8(data: bytes) -> int:
    """Simple XOR-of-all-bytes checksum -- mirror this in the RTL consumer."""
    c = 0
    for byte in data:
        c ^= byte
    return c


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("--width", type=int, default=160)
    ap.add_argument("--height", type=int, default=120)
    ap.add_argument("--fps", type=float, default=1.0,
                    help="images per second (chunks are paced within each)")
    ap.add_argument("--loop", action="store_true",
                    help="resend forever (for a live-updating demo)")
    args = ap.parse_args()

    data = image_to_rgb565(args.image, args.width, args.height)
    total = len(data)
    n_chunks = (total + CHUNK_PIXEL_BYTES - 1) // CHUNK_PIXEL_BYTES

    print(f"{args.image}: {args.width}x{args.height} RGB565 = {total} bytes "
          f"in {n_chunks} chunks, XOR checksum = 0x{checksum8(data):02X}")

    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)

    image_id = 0
    while True:
        chunk_gap = (1.0 / args.fps) / n_chunks      # pace chunks evenly
        for off in range(0, total, CHUNK_PIXEL_BYTES):
            chunk = data[off:off + CHUNK_PIXEL_BYTES]
            header = struct.pack(">HIH", image_id & 0xFFFF, off, len(chunk))
            s.sendto(header + chunk, DEST)
            time.sleep(chunk_gap)

        print(f"image_id {image_id} sent")
        image_id += 1
        if not args.loop:
            break


if __name__ == "__main__":
    main()