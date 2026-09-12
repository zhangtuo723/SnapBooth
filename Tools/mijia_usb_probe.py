#!/usr/bin/env python3
"""Read-only USB descriptor probe for Mijia Instant Photo Printer 2."""

from __future__ import annotations

import argparse
import json
import sys
import time

import usb.core
import usb.util


VID = 0x302C
PID = 0x3008
COMMAND_INTERFACE = 2
COMMAND_OUT = 0x06
COMMAND_IN = 0x86
CMD_JSON_HEADER = b"cmd json\n"


def safe_string(device: usb.core.Device, index: int) -> str:
    if not index:
        return ""
    try:
        return usb.util.get_string(device, index) or ""
    except usb.core.USBError as error:
        return f"<unavailable: {error}>"


def read_device_id(device: usb.core.Device) -> str:
    # USB Printer Class GET_DEVICE_ID. The first two bytes are a big-endian
    # length that includes the length field itself.
    raw = bytes(device.ctrl_transfer(0xA1, 0, 0, 0, 1024, timeout=2000))
    if len(raw) < 2:
        return raw.decode("ascii", errors="replace")
    declared_length = int.from_bytes(raw[:2], "big")
    return raw[2:declared_length].decode("ascii", errors="replace").rstrip("\x00")


def send_json(device: usb.core.Device, method: str, params: object, request_id: int) -> object:
    payload = json.dumps(
        {"method": method, "params": params, "id": request_id},
        separators=(",", ":"),
    ).encode("utf-8")
    device.write(COMMAND_OUT, CMD_JSON_HEADER + payload, timeout=3000)
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        response = bytes(device.read(COMMAND_IN, 65536, timeout=3000))
        if response.startswith(CMD_JSON_HEADER):
            response = response[len(CMD_JSON_HEADER):]
        try:
            decoded = json.loads(response.decode("utf-8", errors="replace").strip())
        except json.JSONDecodeError:
            # A shared command/data endpoint can emit a small binary data ACK
            # before the JSON response to the next command.
            continue
        if isinstance(decoded, dict) and str(decoded.get("method", "")).startswith("event."):
            continue
        if not isinstance(decoded, dict) or decoded.get("id") == request_id:
            return decoded
    raise TimeoutError(f"no response for request {request_id}")


def read_status(device: usb.core.Device) -> dict[str, object]:
    try:
        if device.is_kernel_driver_active(COMMAND_INTERFACE):
            device.detach_kernel_driver(COMMAND_INTERFACE)
    except (NotImplementedError, usb.core.USBError):
        pass
    usb.util.claim_interface(device, COMMAND_INTERFACE)
    try:
        return {
            "status": send_json(
                device,
                "get-prop",
                ["printer-state", "printer-sub-state", "printer-state-alerts"],
                1001,
            ),
            "device-info": send_json(device, "get-prop", ["device-info"], 1002),
        }
    finally:
        usb.util.release_interface(device, COMMAND_INTERFACE)


def read_job_status(device: usb.core.Device) -> object:
    properties = [
        "printer-state",
        "printer-sub-state",
        "printer-state-alerts",
        "job-id",
        "job-state",
        "job-state-reasons",
        "transfer-status",
        "transfer-size",
        "media-size",
        "paper-size",
    ]
    try:
        if device.is_kernel_driver_active(COMMAND_INTERFACE):
            device.detach_kernel_driver(COMMAND_INTERFACE)
    except (NotImplementedError, usb.core.USBError):
        pass
    usb.util.claim_interface(device, COMMAND_INTERFACE)
    try:
        return send_json(device, "get-prop", properties, 1010)
    finally:
        usb.util.release_interface(device, COMMAND_INTERFACE)


def read_properties(device: usb.core.Device, properties: list[str]) -> object:
    try:
        if device.is_kernel_driver_active(COMMAND_INTERFACE):
            device.detach_kernel_driver(COMMAND_INTERFACE)
    except (NotImplementedError, usb.core.USBError):
        pass
    usb.util.claim_interface(device, COMMAND_INTERFACE)
    try:
        return send_json(device, "get-prop", properties, 1020)
    finally:
        usb.util.release_interface(device, COMMAND_INTERFACE)


def call_command(device: usb.core.Device, method: str, params: object, request_id: int) -> object:
    try:
        if device.is_kernel_driver_active(COMMAND_INTERFACE):
            device.detach_kernel_driver(COMMAND_INTERFACE)
    except (NotImplementedError, usb.core.USBError):
        pass
    usb.util.claim_interface(device, COMMAND_INTERFACE)
    try:
        return send_json(device, method, params, request_id)
    finally:
        usb.util.release_interface(device, COMMAND_INTERFACE)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--device-id",
        action="store_true",
        help="read the standard USB Printer Class device ID",
    )
    parser.add_argument(
        "--status",
        action="store_true",
        help="send read-only status and device-info queries",
    )
    parser.add_argument(
        "--job-status",
        action="store_true",
        help="read current job and transfer properties without creating a job",
    )
    parser.add_argument(
        "--properties",
        nargs="+",
        metavar="NAME",
        help="read arbitrary printer properties without changing printer state",
    )
    parser.add_argument("--job-info", type=int, metavar="JOB_ID")
    parser.add_argument("--resume", action="store_true")
    arguments = parser.parse_args()
    device = usb.core.find(idVendor=VID, idProduct=PID)
    if device is None:
        print("Mijia Instant Photo Printer 2 is not connected.", file=sys.stderr)
        return 1

    print(f"device {device.idVendor:04x}:{device.idProduct:04x}")
    print(f"manufacturer: {safe_string(device, device.iManufacturer)}")
    print(f"product: {safe_string(device, device.iProduct)}")
    print(f"serial: {safe_string(device, device.iSerialNumber)}")

    for configuration in device:
        print(f"configuration {configuration.bConfigurationValue}")
        for interface in configuration:
            print(
                "  interface "
                f"{interface.bInterfaceNumber} alt={interface.bAlternateSetting} "
                f"class={interface.bInterfaceClass:#04x} "
                f"subclass={interface.bInterfaceSubClass:#04x} "
                f"protocol={interface.bInterfaceProtocol:#04x} "
                f"name={safe_string(device, interface.iInterface)!r}"
            )
            for endpoint in interface:
                direction = "IN" if usb.util.endpoint_direction(endpoint.bEndpointAddress) == usb.util.ENDPOINT_IN else "OUT"
                transfer_type = usb.util.endpoint_type(endpoint.bmAttributes)
                print(
                    f"    endpoint {endpoint.bEndpointAddress:#04x} {direction} "
                    f"type={transfer_type} packet={endpoint.wMaxPacketSize}"
                )

    if arguments.device_id:
        try:
            print(f"printer-device-id: {read_device_id(device)}")
        except usb.core.USBError as error:
            print(f"printer-device-id unavailable: {error}", file=sys.stderr)
            return 2
    if arguments.status:
        try:
            print(json.dumps(read_status(device), ensure_ascii=False, indent=2, sort_keys=True))
        except (usb.core.USBError, ValueError, TimeoutError) as error:
            print(f"status unavailable: {error}", file=sys.stderr)
            return 3
    if arguments.job_status:
        try:
            print(json.dumps(read_job_status(device), ensure_ascii=False, indent=2, sort_keys=True))
        except (usb.core.USBError, ValueError, TimeoutError) as error:
            print(f"job status unavailable: {error}", file=sys.stderr)
            return 4
    if arguments.properties:
        try:
            value = read_properties(device, arguments.properties)
            print(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True))
        except (usb.core.USBError, ValueError, TimeoutError) as error:
            print(f"properties unavailable: {error}", file=sys.stderr)
            return 5
    if arguments.job_info is not None:
        try:
            value = call_command(device, "get-job-info", {"job-id": arguments.job_info}, 1030)
            print(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True))
        except (usb.core.USBError, ValueError, TimeoutError) as error:
            print(f"job info unavailable: {error}", file=sys.stderr)
            return 6
    if arguments.resume:
        try:
            value = call_command(device, "resume-printer", {}, 1040)
            print(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True))
        except (usb.core.USBError, ValueError, TimeoutError) as error:
            print(f"resume unavailable: {error}", file=sys.stderr)
            return 7
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
