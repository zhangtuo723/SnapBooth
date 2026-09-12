#!/usr/bin/env python3
"""Execute and trace a full Mijia photo job over the shared USB interface."""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import time

import usb.core
import usb.util


VID = 0x302C
PID = 0x3008
INTERFACE = 2
OUT = 0x06
IN = 0x86
JSON_HEADER = b"cmd json\n"
CHUNK = 10215


def decode_packet(raw: bytes) -> object | None:
    body = raw[len(JSON_HEADER):] if raw.startswith(JSON_HEADER) else raw
    try:
        return json.loads(body.decode("utf-8").strip())
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None


def read_packet(device: usb.core.Device, timeout: int = 3000) -> tuple[bytes, object | None]:
    raw = bytes(device.read(IN, 65536, timeout=timeout))
    decoded = decode_packet(raw)
    print(json.dumps({
        "direction": "in",
        "text": raw.decode("utf-8", errors="replace"),
        "json": decoded,
    }, ensure_ascii=False))
    return raw, decoded


def send_json(device: usb.core.Device, method: str, params: object, request_id: int) -> object:
    request = {"method": method, "params": params, "id": request_id}
    payload = JSON_HEADER + json.dumps(request, separators=(",", ":")).encode()
    print(json.dumps({"direction": "out", "json": request}, ensure_ascii=False))
    device.write(OUT, payload, timeout=3000)
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        _, decoded = read_packet(device)
        if isinstance(decoded, dict) and decoded.get("id") == request_id:
            return decoded
    raise TimeoutError(f"no response for request {request_id}")


def find_job_id(value: object) -> int:
    if isinstance(value, dict):
        for key in ("job-id", "job_id"):
            if key in value:
                return int(value[key])
        for child in value.values():
            try:
                return find_job_id(child)
            except LookupError:
                pass
    if isinstance(value, list):
        for child in value:
            try:
                return find_job_id(child)
            except LookupError:
                pass
    raise LookupError("job id not found")


def send_data(device: usb.core.Device, job_id: int, image: bytes, extlen_adds_id: bool) -> None:
    for offset in range(0, len(image), CHUNK):
        chunk = image[offset:offset + CHUNK]
        extlen = len(chunk) + (4 if extlen_adds_id else 0)
        packet = b"cmd data EXTLEN=" + str(extlen).encode() + b"\n" + struct.pack("<I", job_id) + chunk
        for packet_offset in range(0, len(packet), 1024):
            device.write(OUT, packet[packet_offset:packet_offset + 1024], timeout=10000)
        while True:
            raw, decoded = read_packet(device, timeout=10000)
            if decoded is not None:
                continue
            if b"cmd data EXTLEN=" in raw and b"OK" in raw:
                break
        print(json.dumps({"sent": offset + len(chunk), "total": len(image)}))
        time.sleep(0.02)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("jpeg")
    parser.add_argument("--extlen-adds-id", action="store_true")
    args = parser.parse_args()
    image = open(args.jpeg, "rb").read()
    if not image.startswith(b"\xff\xd8"):
        raise SystemExit("not a JPEG")

    device = usb.core.find(idVendor=VID, idProduct=PID)
    if device is None:
        raise SystemExit("printer not connected")
    try:
        if device.is_kernel_driver_active(INTERFACE):
            device.detach_kernel_driver(INTERFACE)
    except (NotImplementedError, usb.core.USBError):
        pass
    usb.util.claim_interface(device, INTERFACE)
    now = int(time.time())
    try:
        create = send_json(device, "print-job", {
            "media-size": 5012,
            "media-type": 2010,
            "job-type": 0,
            "channel": 30784,
            "file-size": len(image),
            "document-format": 9,
            "document-name": f"{now}.jpeg",
            "hash-method": 1,
            "hash-value": hashlib.sha1(image).hexdigest(),
            "user-account": "000000.00000000000000000000000000000000.0000",
            "link-type": 1000,
            "job-send-time": now,
            "copies": 1,
        }, 5001)
        job_id = find_job_id(create)
        print(json.dumps({"job-id": job_id, "file-size": len(image)}))
        send_data(device, job_id, image, args.extlen_adds_id)
        for poll in range(90):
            try:
                info = send_json(device, "get-job-info", {"job-id": job_id}, 5100 + poll)
            except usb.core.USBTimeoutError:
                print(json.dumps({"poll": poll, "timeout": True}))
                continue
            print(json.dumps({"poll": poll, "job-info": info}, ensure_ascii=False))
            time.sleep(0.5)
        return 0
    finally:
        usb.util.release_interface(device, INTERFACE)


if __name__ == "__main__":
    raise SystemExit(main())
