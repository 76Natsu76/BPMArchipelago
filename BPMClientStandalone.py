#!/usr/bin/env python3
import argparse
import json
import sys
import time
import uuid
import threading
from pathlib import Path

try:
    import websocket
except ImportError:
    print("Missing dependency: websocket-client")
    print("Install with: py -m pip install websocket-client")
    sys.exit(1)


GAME = "BPM: Bullets Per Minute"

CLIENT_VERSION = {
    "major": 0,
    "minor": 6,
    "build": 7,
    "class": "Version"
}

CLIENT_STATUS_GOAL = 30


class Client:
    def __init__(self, args):
        self.args = args

        self.ipc = Path(args.ipc_dir).resolve()
        self.ipc.mkdir(parents=True, exist_ok=True)

        self.incoming = self.ipc / "incoming.txt"
        self.outgoing = self.ipc / "outgoing.txt"
        self.status = self.ipc / "client_status.txt"
        self.connected_flag = self.ipc / "ap_connected.flag"

        # Tracks every item received from Archipelago.
        self.items_received = []

        # Tracks locations already checked.
        self.checked = set()

        # Tracks item indexes which BPM has successfully acknowledged.
        self.delivered_items = set()

        self.slot = None
        self.slot_info = {}
        self.missing = set()
        self.seed = ""

        self.running = True
        self.lock = threading.Lock()
        self.ws = None

        self.load_delivered_items()

    # ============================================================
    # Logging
    # ============================================================

    def log(self, message):
        print(message, flush=True)

    # ============================================================
    # Persistent delivered-item tracking
    # ============================================================

    def load_delivered_items(self):
        path = self.ipc / "delivered_items.txt"

        try:
            if not path.exists():
                return

            text = path.read_text(
                encoding="utf-8"
            )

            for line in text.splitlines():
                line = line.strip()

                if not line:
                    continue

                try:
                    self.delivered_items.add(
                        int(line)
                    )
                except ValueError:
                    continue

        except Exception as e:
            self.log(
                f"Could not load delivered item list: {e}"
            )

    def record_delivered_item(self, absolute_index):
        self.delivered_items.add(
            absolute_index
        )

        path = self.ipc / "delivered_items.txt"

        try:
            with path.open(
                "a",
                encoding="utf-8"
            ) as f:
                f.write(
                    str(absolute_index) +
                    "\n"
                )

        except Exception as e:
            self.log(
                "WARNING: Could not record delivered "
                f"item {absolute_index}: {e}"
            )

    # ============================================================
    # WebSocket
    # ============================================================

    def send(self, messages):
        if self.ws is None:
            self.log("[WS] SEND FAILED: websocket is None")
            return False

        try:
            payload = json.dumps(messages, separators=(",", ":"))

            self.log(
                "[WS SEND] "
                + payload
            )

            self.ws.send(payload)

            self.log(
                "[WS SEND] OK"
            )

            return True

        except Exception as e:
            self.log(
                "[WS SEND ERROR] "
                + repr(e)
            )

            return False

    def make_urls(self):
        address = self.args.connect.strip()

        if address.startswith("ws://"):
            host = address[5:]
        elif address.startswith("wss://"):
            host = address[6:]
        else:
            host = address

        return [
            "ws://" + host,
            "wss://" + host
        ]

    def set_connected_flag(self, connected):
        try:
            if connected:
                self.connected_flag.write_text(
                    "connected\n",
                    encoding="utf-8"
                )
            else:
                if self.connected_flag.exists():
                    self.connected_flag.unlink()

        except Exception as e:
            self.log(
                f"Could not update connection flag: {e}"
            )

    def connect(self):
        urls = self.make_urls()

        last_error = None
        connection_succeeded = False

        for attempt, url in enumerate(urls, start=1):

            self.log("")
            self.log("========================================")
            self.log(
                f"WebSocket connection attempt {attempt}/2"
            )
            self.log(f"Connecting to {url}")
            self.log("========================================")

            try:
                if self.ws is not None:
                    try:
                        self.ws.close()
                    except Exception:
                        pass

                    self.ws = None

                if url.startswith("wss://"):
                    self.log(
                        "WARNING: TLS certificate verification "
                        "disabled for testing."
                    )

                    self.ws = websocket.create_connection(
                        url,
                        timeout=10,
                        ping_interval=None,
                        sslopt={
                            "cert_reqs": 0
                        }
                    )

                else:
                    self.ws = websocket.create_connection(
                        url,
                        timeout=10,
                        ping_interval=None
                    )

                self.log(
                    "WebSocket connection established."
                )

                self.log(
                    "Waiting for Archipelago RoomInfo..."
                )

                self.ws.settimeout(10)

                raw = self.ws.recv()

                if not raw:
                    raise RuntimeError(
                        "Server closed the connection before "
                        "sending RoomInfo."
                    )

                self.log(
                    "Received initial server response."
                )

                try:
                    messages = json.loads(raw)

                except json.JSONDecodeError as e:
                    raise RuntimeError(
                        "Server sent invalid JSON during "
                        f"RoomInfo: {e}"
                    )

                if not isinstance(messages, list):
                    raise RuntimeError(
                        "Archipelago response was not a "
                        "JSON message list."
                    )

                if not messages:
                    raise RuntimeError(
                        "Archipelago sent an empty message list."
                    )

                first = messages[0]

                if not isinstance(first, dict):
                    raise RuntimeError(
                        "Archipelago's first message was "
                        "not an object."
                    )

                cmd = first.get("cmd")

                if cmd != "RoomInfo":
                    raise RuntimeError(
                        f"Expected RoomInfo, got {cmd!r}"
                    )

                self.seed = first.get(
                    "seed_name",
                    ""
                )

                self.log(
                    "Received RoomInfo successfully."
                )

                self.log(
                    f"Room: {self.seed}"
                )

                payload = {
                    "cmd": "Connect",
                    "password": self.args.password,
                    "game": GAME,
                    "name": self.args.name,
                    "uuid": str(uuid.uuid4()),
                    "version": CLIENT_VERSION,
                    "tags": ["BPM"],
                    "items_handling": 7,
                    "slot_data": True
                }

                self.log(
                    "Sending Archipelago Connect packet..."
                )

                self.send([payload])

                while True:
                    raw = self.ws.recv()

                    if not raw:
                        raise RuntimeError(
                            "Server closed the connection while "
                            "waiting for Connect response."
                        )

                    try:
                        messages = json.loads(raw)

                    except json.JSONDecodeError as e:
                        raise RuntimeError(
                            f"Invalid JSON from Archipelago: {e}"
                        )

                    if not isinstance(messages, list):
                        raise RuntimeError(
                            "Archipelago response was not a "
                            "JSON message list."
                        )

                    for message in messages:

                        if not isinstance(message, dict):
                            continue

                        cmd = message.get("cmd")

                        if cmd == "Connected":

                            self.slot = message["slot"]

                            self.slot_info = message.get(
                                "slot_info",
                                {}
                            )

                            self.missing = set(
                                message.get(
                                    "missing_locations",
                                    []
                                )
                            )

                            self.checked = set(
                                message.get(
                                    "checked_locations",
                                    []
                                )
                            )

                            self.write_status(
                                "connected=true "
                                f"slot={self.slot} "
                                f"seed={self.seed} "
                                f"checked={len(self.checked)} "
                                f"items={len(self.items_received)} "
                                f"delivered={len(self.delivered_items)}\n"
                            )

                            self.set_connected_flag(True)

                            self.log("")
                            self.log(
                                "========================================"
                            )
                            self.log(
                                "ARCHIPELAGO CONNECTION SUCCESSFUL"
                            )
                            self.log(
                                "========================================"
                            )

                            self.log(
                                f"Connected as slot {self.slot} "
                                f"({self.args.name})"
                            )

                            self.log(
                                f"Seed: {self.seed}"
                            )

                            self.log("")

                            self.flush_session()

                            # CRITICAL:
                            # Keep the WebSocket alive after connect().
                            connection_succeeded = True

                            return

                        if cmd == "ConnectionRefused":

                            errors = message.get(
                                "errors"
                            )

                            raise RuntimeError(
                                "Archipelago refused the "
                                "connection: " +
                                str(errors)
                            )

            except websocket.WebSocketException as e:

                last_error = e

                self.log("")
                self.log(
                    f"WebSocket error while connecting "
                    f"to {url}:"
                )
                self.log(
                    f"  {type(e).__name__}: {e}"
                )

            except OSError as e:

                last_error = e

                self.log("")
                self.log(
                    f"Network error while connecting "
                    f"to {url}:"
                )
                self.log(
                    f"  {type(e).__name__}: {e}"
                )

            except Exception as e:

                last_error = e

                self.log("")
                self.log(
                    f"Connection attempt to {url} failed:"
                )
                self.log(
                    f"  {type(e).__name__}: {e}"
                )

            finally:

                # ONLY close the socket when the attempt failed.
                # On success, self.ws must remain alive.

                if not connection_succeeded:

                    self.set_connected_flag(False)

                    if self.ws is not None:

                        try:
                            self.ws.close()
                        except Exception:
                            pass

                        self.ws = None

            if attempt < len(urls):

                self.log("")
                self.log(
                    f"{url} failed."
                )
                self.log(
                    "Trying the alternate WebSocket "
                    "protocol..."
                )

        raise RuntimeError(
            "Could not establish a connection to the "
            "Archipelago server.\n"
            f"Last error: {last_error}"
        )

    # ============================================================
    # Session / status
    # ============================================================

    def flush_session(self):
        session = f"SESSION|{self.seed}"

        try:
            # Look at the most recent SESSION marker already in incoming.txt.
            # Reconnecting to the same AP seed must NOT append another marker,
            # because Lua treats the latest SESSION as the beginning of the
            # currently active item stream.
            if self.incoming.exists():
                latest_session = None

                with self.incoming.open(
                    "r",
                    encoding="utf-8"
                ) as f:
                    for line in f:
                        line = line.strip()

                        if line.startswith("SESSION|"):
                            latest_session = line

                if latest_session == session:
                    return

            with self.incoming.open(
                "a",
                encoding="utf-8"
            ) as f:
                f.write(session + "\n")

        except Exception as e:
            self.log(
                f"[IPC] Could not update session marker: {e}"
            )

    def write_status(self, text):
        self.status.write_text(
            text,
            encoding="utf-8"
        )

    # ============================================================
    # Archipelago server messages
    # ============================================================

    def handle_server(self, messages):
        for message in messages:
            if not isinstance(message, dict):
                continue

            # Diagnostic: show every packet received from Archipelago.
            # This lets us see errors/rejections that were previously ignored.
            cmd = message.get("cmd")
            self.log(
                "[AP RAW] "
                + json.dumps(message, separators=(",", ":"), default=str)
            )

            if cmd == "ReceivedItems":
                self.handle_items(message)

            elif cmd == "RoomUpdate":
                if "missing_locations" in message:
                    self.missing = set(message["missing_locations"])

                if "checked_locations" in message:
                    self.checked = set(message["checked_locations"])

            elif cmd == "Print":
                self.log("[AP] " + str(message.get("text", "")))

            elif cmd == "PrintJSON":
                self.log("[AP] item/event message received")

            elif cmd == "ConnectionRefused":
                self.log(
                    "Connection refused: "
                    + str(message.get("errors"))
                )
                self.running = False

            elif cmd == "InvalidPacket":
                self.log(
                    "[AP] InvalidPacket: "
                    + json.dumps(
                        message,
                        separators=(",", ":"),
                        default=str
                    )
                )

            else:
                # Keep unknown packets visible during diagnostics.
                self.log(
                    "[AP] Unhandled server command: "
                    + str(cmd)
                )

    def append_incoming(self, text):
        """Append a line to the BPM -> Lua incoming IPC file."""
        try:
            with self.incoming.open("a", encoding="utf-8") as f:
                f.write(text)
            return True
        except Exception as e:
            self.log(f"[IPC] Could not write incoming.txt: {e}")
            return False

    def handle_items(self, message):
        start_index = int(message.get("index", 0))
        items = message.get("items", [])

        if start_index == 0:
            # Index 0 means the server is giving us the complete
            # received-item stream from the beginning.
            self.items_received.clear()

        # IMPORTANT:
        # items_received contains only items retained in memory for this
        # process. It is NOT a reliable absolute ReceivedItems position,
        # because already-delivered items are intentionally omitted below
        # and delivered_items persists across client restarts.
        #
        # Therefore, do not compare Archipelago's absolute start index
        # against len(self.items_received). That caused new packets such
        # as index=8 to be discarded after eight previously delivered items.
        #
        # The server's ReceivedItems stream is authoritative here.
        # Deduplicate using the persisted delivered_items set plus the
        # absolute packet index.
        if start_index < 0:
            self.log(
                f"[AP] Invalid ReceivedItems start index: {start_index}"
            )
            return

        new_items = 0
        skipped_delivered = 0

        for offset, row in enumerate(items):
            try:
                if isinstance(row, dict):
                    item_id = int(row["item"])
                    location_id = int(row.get("location", -1))
                    player_id = int(row.get("player", 0))
                    flags = int(row.get("flags", 0))
                else:
                    # Defensive fallback for a list/tuple representation.
                    item_id = int(row[0])
                    location_id = int(row[1])
                    player_id = int(row[2])
                    flags = int(row[3]) if len(row) > 3 else 0

            except (KeyError, IndexError, TypeError, ValueError) as exc:
                self.log(f"[AP] Invalid NetworkItem row: {row!r}")
                self.log(f"[AP] Parse error: {exc}")
                continue

            # Archipelago's ReceivedItems.index is the absolute starting
            # index for this packet. Add the row's offset within the packet.
            absolute_index = start_index + offset

            # If BPM has already acknowledged this item, there is
            # nothing new for Lua to process.
            if absolute_index in self.delivered_items:
                skipped_delivered += 1
                self.log(
                    "[AP ITEM] "
                    f"index={absolute_index} already delivered; "
                    "not re-queuing"
                )

                continue

            new_items += 1

            self.items_received.append(
                (
                    item_id,
                    location_id,
                    player_id,
                    flags,
                )
            )

            line = (
                f"ITEM|{absolute_index}|{item_id}|"
                f"AP item {item_id}\n"
            )

            if not self.append_incoming(line):
                self.log(
                    f"[AP ITEM] WARNING: item {absolute_index} "
                    "was received but could not be written to incoming.txt"
                )

            self.log(
                "[AP ITEM] "
                f"index={absolute_index} "
                f"item={item_id} "
                f"location={location_id} "
                f"player={player_id} "
                f"flags={flags}"
            )

        self.log(
            "[AP ITEMS] packet processed "
            f"start={start_index} count={len(items)} "
            f"new={new_items} skipped_delivered={skipped_delivered}"
        )

    # ============================================================
    # Archipelago location checks
    # ============================================================

    def send_check(self, location_id):
        if self.slot is None:
            self.log("[IPC] Cannot send location check: not connected")
            return

        payload = [
            {
                "cmd": "LocationChecks",
                "locations": [int(location_id)]
            }
        ]

        self.log(
            "[AP SEND] "
            + json.dumps(payload, separators=(",", ":"))
        )

        self.send(payload)

        self.log(
            f"[AP SEND] LocationChecks packet sent for {int(location_id)}"
        )

        self.checked.add(int(location_id))

    def goal(self):

        if self.slot is not None:

            self.log(
                "[IPC] Sending goal status"
            )

            self.send([
                {
                    "cmd": "StatusUpdate",
                    "status": CLIENT_STATUS_GOAL
                }
            ])

    # ============================================================
    # IPC ACK handling
    # ============================================================

    def handle_item_ack(self, parts):

        if len(parts) < 3:
            return

        try:
            absolute_index = int(
                parts[1]
            )

        except ValueError:
            self.log(
                "[IPC] Invalid ITEM_ACK index: " +
                str(parts[1])
            )

            return

        result = parts[2]

        detail = ""

        if len(parts) >= 4:
            detail = parts[3]

        if result == "OK":

            if absolute_index in self.delivered_items:

                self.log(
                    "[IPC] Item "
                    f"{absolute_index} already recorded "
                    "as delivered"
                )

                return

            self.record_delivered_item(
                absolute_index
            )

            self.log(
                "[IPC] Item "
                f"{absolute_index} delivered successfully"
                + (
                    f": {detail}"
                    if detail
                    else ""
                )
            )

        elif result == "ERROR":

            self.log(
                "[IPC] BPM failed to deliver item "
                f"{absolute_index}"
                + (
                    f": {detail}"
                    if detail
                    else ""
                )
            )

        else:

            self.log(
                "[IPC] Unknown ITEM_ACK result: "
                f"{result}"
            )

    # ============================================================
    # IPC loop
    # ============================================================

    def ipc_loop(self):

        self.outgoing.touch(
            exist_ok=True
        )

        while self.running:

            try:

                text = self.outgoing.read_text(
                    encoding="utf-8"
                )

                self.outgoing.write_text(
                    "",
                    encoding="utf-8"
                )

            except Exception:

                text = ""

            for line in text.splitlines():

                parts = line.split(
                    "|",
                    3
                )

                if not parts:
                    continue

                # ------------------------------------------------
                # Location check
                # ------------------------------------------------

                if (
                    parts[0] == "CHECK"
                    and len(parts) >= 2
                ):

                    try:

                        location_id = int(
                            parts[1]
                        )

                    except ValueError:
                        continue

                    self.log(
                        f"[IPC] Received CHECK "
                        f"from BPM: {location_id}"
                    )

                    if (
                        location_id in self.missing
                        or location_id not in self.checked
                    ):

                        self.send_check(
                            location_id
                        )

                    else:

                        self.log(
                            f"[IPC] Location {location_id} "
                            "already checked"
                        )

                # ------------------------------------------------
                # Goal
                # ------------------------------------------------

                elif parts[0] == "GOAL":

                    self.goal()

                # ------------------------------------------------
                # Item delivery acknowledgement
                # ------------------------------------------------

                elif parts[0] == "ITEM_ACK":

                    self.handle_item_ack(
                        parts
                    )

            time.sleep(
                0.15
            )

    # ============================================================
    # Status loop
    # ============================================================

    def write_status_loop(self):

        while self.running:

            connected = (
                self.ws is not None
            )

            self.write_status(
                f"connected={connected} "
                f"slot={self.slot} "
                f"seed={self.seed} "
                f"checked={len(self.checked)} "
                f"items={len(self.items_received)} "
                f"delivered={len(self.delivered_items)}\n"
            )

            time.sleep(
                1
            )

    # ============================================================
    # Main runtime
    # ============================================================

    def run(self):

        try:

            self.connect()

        except Exception as e:

            self.set_connected_flag(False)

            self.log("")
            self.log(
                "========================================"
            )
            self.log(
                "ARCHIPELAGO CONNECTION FAILED"
            )
            self.log(
                "========================================"
            )
            self.log(
                str(e)
            )
            self.log("")

            self.write_status(
                "connected=false "
                f"slot={self.slot} "
                f"seed={self.seed} "
                f"checked={len(self.checked)} "
                f"items={len(self.items_received)} "
                f"delivered={len(self.delivered_items)}\n"
            )

            self.running = False

            return

        thread_ipc = threading.Thread(
            target=self.ipc_loop,
            daemon=True
        )

        thread_status = threading.Thread(
            target=self.write_status_loop,
            daemon=True
        )

        thread_ipc.start()
        thread_status.start()

        try:

            while self.running:

                try:
                    self.log(
                        "[WS RECV] Waiting for server packet..."
                    )

                    data = self.ws.recv()

                except websocket.WebSocketTimeoutException:
                    self.log(
                        "[WS RECV] Timeout - still connected"
                    )
                    continue

                except Exception as e:
                    self.log(
                        "[WS RECV ERROR] " +
                        repr(e)
                    )
                    break

                if not data:
                    self.log(
                        "[WS RECV] Archipelago closed the connection."
                    )
                    break

                self.log(
                    "[WS RECV] Raw data received: " +
                    repr(data)
                )

                try:
                    messages = json.loads(data)

                except json.JSONDecodeError as e:
                    self.log(
                        "[WS RECV] Invalid JSON: " +
                        str(e)
                    )
                    continue

                self.log(
                    "[WS RECV] JSON decoded successfully"
                )

                if isinstance(messages, list):

                    self.log(
                        f"[WS RECV] Dispatching "
                        f"{len(messages)} server message(s)"
                    )

                    self.handle_server(
                        messages
                    )

                else:

                    self.log(
                        "[WS RECV] Unexpected JSON type: " +
                        type(messages).__name__
                    )

        finally:

            self.running = False

            self.set_connected_flag(
                False
            )

            try:

                if self.ws is not None:
                    self.ws.close()

            except Exception:
                pass

            self.ws = None

def main():

    parser = argparse.ArgumentParser(
        description=(
            "BPM Archipelago standalone client v1.4.0"
        )
    )

    parser.add_argument(
        "--connect",
        required=True,
        help=(
            "host:port, e.g. localhost:38281 "
            "or archipelago.gg:38281"
        )
    )

    parser.add_argument(
        "--name",
        required=True,
        help=(
            "slot name exactly as in the YAML"
        )
    )

    parser.add_argument(
        "--password",
        default="",
        help=(
            "room password, if any"
        )
    )

    parser.add_argument(
        "--ipc-dir",
        required=True,
        help=(
            "BPMArchipelago IPC directory"
        )
    )

    args = parser.parse_args()

    client = Client(
        args
    )

    client.run()


if __name__ == "__main__":
    main()
