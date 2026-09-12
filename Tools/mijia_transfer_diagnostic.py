#!/usr/bin/env python3
"""Send one incomplete data frame, then read job progress. Never completes a print."""

from __future__ import annotations

import argparse
import json
import struct
import time

import usb.core
import usb.util

from mijia_usb_probe import PID, VID, send_json


COMMAND_INTERFACE = 2
DATA_INTERFACE = 0
DATA_OUT = 0x01
DATA_IN = 0x81
CHUNK_SIZE = 10215


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


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("jpeg")
    parser.add_argument(
        "--shared-command-data",
        action="store_true",
        help="send the single data frame through interface 2 endpoints 06/86",
    )
    arguments = parser.parse_args()
    image = open(arguments.jpeg, "rb").read()
    if not image.startswith(b"\xff\xd8"):
        raise SystemExit("input is not a JPEG")

    device = usb.core.find(idVendor=VID, idProduct=PID)
    if device is None:
        raise SystemExit("printer is not connected")
    interfaces = (COMMAND_INTERFACE,) if arguments.shared_command_data else (COMMAND_INTERFACE, DATA_INTERFACE)
    for interface in interfaces:
        try:
            if device.is_kernel_driver_active(interface):
                device.detach_kernel_driver(interface)
        except (NotImplementedError, usb.core.USBError):
            pass
        usb.util.claim_interface(device, interface)

    try:
        create = send_json(
            device,
            "print-job",
            {
                "channel": 2,
                "copies": 1,
                "media-size": 5012,
                "media-type": 2010,
                "job-type": 0,
                "file-size": len(image),
            },
            1101,
        )
        job_id = find_job_id(create)
        chunk = image[:CHUNK_SIZE]
        packet = (
            b"cmd data EXTLEN="
            + str(len(chunk)).encode("ascii")
            + b"\n"
            + struct.pack("<I", job_id)
            + chunk
        )
        data_out = 0x06 if arguments.shared_command_data else DATA_OUT
        data_in = 0x86 if arguments.shared_command_data else DATA_IN
        for offset in range(0, len(packet), 1024):
            device.write(data_out, packet[offset:offset + 1024], timeout=3000)

        ack: str | None
        try:
            ack = bytes(device.read(data_in, 4096, timeout=500)).hex()
        except usb.core.USBTimeoutError:
            ack = None

        job_info = send_json(device, "get-job-info", {"job-id": job_id}, 1102)
        props = send_json(
            device,
            "get-prop",
            ["printer-state", "printer-sub-state", "printer-state-alerts",
             "job-state", "transfer-status", "transfer-size", "media-size"],
            1103,
        )
        print(json.dumps({
            "note": "Only the first data frame was sent; this job cannot print.",
            "job-id": job_id,
            "create": create,
            "data-endpoint-ack": ack,
            "job-info": job_info,
            "properties": props,
        }, ensure_ascii=False, indent=2, sort_keys=True))
        return 0
    finally:
        time.sleep(0.05)
        for interface in reversed(interfaces):
            try:
                usb.util.release_interface(device, interface)
            except usb.core.USBError:
                pass


if __name__ == "__main__":
    raise SystemExit(main())
