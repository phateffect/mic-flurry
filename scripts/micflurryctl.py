#!/usr/bin/env python3
"""Send JSON-RPC requests to a running micflurryd control socket.

Usage:
  micflurryctl.py status [--compact]
  micflurryctl.py devices
  micflurryctl.py refresh
  micflurryctl.py connect <device-uuid>
  micflurryctl.py release
  micflurryctl.py settings
  micflurryctl.py reload-keymap
  micflurryctl.py call <method> [params-json]

The default socket is ~/Library/Application Support/MicFlurry/run/control.sock.
Override it with --socket PATH or MICFLURRY_SOCKET.
"""

import argparse
import json
import os
import socket
import sys

DEFAULT_SOCKET = os.path.expanduser(
    "~/Library/Application Support/MicFlurry/run/control.sock"
)

REQUEST_TIMEOUT_SECONDS = 15


class ControlError(Exception):
    pass


def request(socket_path, method, params=None, timeout=REQUEST_TIMEOUT_SECONDS):
    payload = {"jsonrpc": "2.0", "id": 1, "method": method}
    if params is not None:
        payload["params"] = params

    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.settimeout(timeout)
    try:
        connection.connect(socket_path)
        connection.sendall(json.dumps(payload).encode() + b"\n")
        buffer = b""
        while True:
            chunk = connection.recv(65536)
            if not chunk:
                break
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                if not line:
                    continue
                message = json.loads(line.decode())
                # Skip asynchronous status events; wait for the response.
                if message.get("id") == 1:
                    if "error" in message:
                        raise ControlError(
                            f"{method}: {message['error'].get('message', message['error'])}"
                        )
                    return message.get("result")
    finally:
        connection.close()
    raise ControlError(f"{method}: connection closed before a response arrived")


def print_json(value, compact=False):
    if compact:
        print(json.dumps(value, ensure_ascii=False))
    else:
        print(json.dumps(value, indent=2, ensure_ascii=False))


def summarize_devices(status, compact=False):
    print_json(status.get("devices", []), compact)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--socket", default=os.environ.get("MICFLURRY_SOCKET", DEFAULT_SOCKET))
    parser.add_argument("--compact", action="store_true", help="print single-line JSON")
    subcommands = parser.add_subparsers(dest="command", required=True)

    subcommands.add_parser("status", help="full v1.status response")
    subcommands.add_parser("devices", help="only the device list from v1.status")
    subcommands.add_parser("refresh", help="v1.refresh_devices")
    connect = subcommands.add_parser("connect", help="attach to a device")
    connect.add_argument("device", help="CoreBluetooth UUID of the device")
    subcommands.add_parser("release", help="release the attached device")
    subcommands.add_parser("settings", help="v1.settings")
    subcommands.add_parser("reload-keymap", help="reload the attached model TOML keymap")
    call = subcommands.add_parser("call", help="raw method call")
    call.add_argument("method", help="for example v1.start_recording")
    call.add_argument("params", nargs="?", help="JSON object of params")

    args = parser.parse_args()

    if args.command == "status":
        print_json(request(args.socket, "v1.status"), args.compact)
    elif args.command == "devices":
        summarize_devices(request(args.socket, "v1.status"), args.compact)
    elif args.command == "refresh":
        print_json(request(args.socket, "v1.refresh_devices"), args.compact)
    elif args.command == "connect":
        print_json(request(args.socket, "v1.connect", {"device": args.device}), args.compact)
    elif args.command == "release":
        print_json(request(args.socket, "v1.release"), args.compact)
    elif args.command == "settings":
        print_json(request(args.socket, "v1.settings"), args.compact)
    elif args.command == "reload-keymap":
        print_json(request(args.socket, "v1.reload_keymap"), args.compact)
    elif args.command == "call":
        params = json.loads(args.params) if args.params else None
        print_json(request(args.socket, args.method, params), args.compact)


if __name__ == "__main__":
    try:
        main()
    except (ControlError, OSError, json.JSONDecodeError) as error:
        print(f"micflurryctl: {error}", file=sys.stderr)
        sys.exit(1)
