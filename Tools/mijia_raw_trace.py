#!/usr/bin/env python3
"""Trace raw responses to a read-only Mijia USB status request."""

from __future__ import annotations

import json
import time

import usb.core
import usb.util


VID = 0x302C
PID = 0x3008
INTERFACE = 2
OUT = 0x06
IN = 0x86


def main() -> int:
    device = usb.core.find(idVendor=VID, idProduct=PID)
    if device is None:
        raise SystemExit("printer is not connected")
    try:
        if device.is_kernel_driver_active(INTERFACE):
            device.detach_kernel_driver(INTERFACE)
    except (NotImplementedError, usb.core.USBError):
        pass
    usb.util.claim_interface(device, INTERFACE)
    request_id = 4501
    payload = json.dumps(
        {
            "method": "get-prop",
            "params": [
                "printer-state",
                "printer-sub-state",
                "printer-state-alerts",
                "job-id",
                "job-state",
                "job-state-reasons",
                "transfer-status",
                "transfer-size",
                "media-size",
            ],
            "id": request_id,
        },
        separators=(",", ":"),
    ).encode()
    try:
        for send_attempt in range(3):
            device.write(OUT, b"cmd json\n" + payload, timeout=3000)
            print(f"sent request id={request_id} attempt={send_attempt + 1}")
            deadline = time.monotonic() + 4
            while time.monotonic() < deadline:
                try:
                    raw = bytes(device.read(IN, 65536, timeout=750))
                except usb.core.USBTimeoutError:
                    print("read timeout")
                    continue
                print(f"received {len(raw)} bytes hex={raw.hex()}")
                print(f"text={raw.decode('utf-8', errors='replace')!r}")
                if f'\"id\":{request_id}'.encode() in raw:
                    return 0
        return 2
    finally:
        usb.util.release_interface(device, INTERFACE)


if __name__ == "__main__":
    raise SystemExit(main())
