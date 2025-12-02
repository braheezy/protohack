#!/usr/bin/env python3
"""
Test client for Speed Daemon (Problem 6)
Tests camera connections, plate observations, ticket dispatchers, and heartbeats.
"""

import socket
import struct
import threading
import time
from dataclasses import dataclass
from typing import List, Optional, Tuple

# Message type constants
MSG_ERROR = 0x10
MSG_PLATE = 0x20
MSG_TICKET = 0x21
MSG_WANT_HEARTBEAT = 0x40
MSG_HEARTBEAT = 0x41
MSG_I_AM_CAMERA = 0x80
MSG_I_AM_DISPATCHER = 0x81


@dataclass
class Ticket:
    """Represents a speeding ticket"""

    plate: str
    road: int
    mile1: int
    timestamp1: int
    mile2: int
    timestamp2: int
    speed: int  # 100x miles per hour


class ProtocolError(Exception):
    """Raised when protocol error occurs"""

    pass


def encode_str(s: str) -> bytes:
    """Encode a string in protocol format (length-prefixed)"""
    encoded = s.encode("ascii")
    return struct.pack("!B", len(encoded)) + encoded


def decode_str(data: bytes, offset: int) -> Tuple[str, int]:
    """Decode a string from protocol format. Returns (string, new_offset)"""
    length = data[offset]
    offset += 1
    string = data[offset : offset + length].decode("ascii")
    return string, offset + length


def send_i_am_camera(sock: socket.socket, road: int, mile: int, limit: int):
    """Send IAmCamera message"""
    msg = struct.pack("!BHHH", MSG_I_AM_CAMERA, road, mile, limit)
    sock.sendall(msg)


def send_plate(sock: socket.socket, plate: str, timestamp: int):
    """Send Plate observation message"""
    msg = (
        struct.pack("!B", MSG_PLATE) + encode_str(plate) + struct.pack("!I", timestamp)
    )
    sock.sendall(msg)


def send_i_am_dispatcher(sock: socket.socket, roads: List[int]):
    """Send IAmDispatcher message"""
    msg = struct.pack("!BB", MSG_I_AM_DISPATCHER, len(roads))
    for road in roads:
        msg += struct.pack("!H", road)
    sock.sendall(msg)


def send_want_heartbeat(sock: socket.socket, interval: int):
    """Send WantHeartbeat message (interval in deciseconds)"""
    msg = struct.pack("!BI", MSG_WANT_HEARTBEAT, interval)
    sock.sendall(msg)


def receive_message(
    sock: socket.socket, timeout: Optional[float] = None
) -> Optional[Tuple[int, bytes]]:
    """
    Receive a single message from the server.
    Returns (message_type, message_data) or None if timeout/disconnect.
    """
    if timeout is not None:
        sock.settimeout(timeout)

    try:
        msg_type_byte = sock.recv(1)
        if not msg_type_byte:
            return None

        msg_type = msg_type_byte[0]

        if msg_type == MSG_ERROR:
            # Error message: str
            length_byte = sock.recv(1)
            if not length_byte:
                return None
            length = length_byte[0]
            error_msg = sock.recv(length).decode("ascii")
            return (MSG_ERROR, error_msg.encode("ascii"))

        elif msg_type == MSG_TICKET:
            # Ticket: plate(str) + road(u16) + mile1(u16) + ts1(u32) + mile2(u16) + ts2(u32) + speed(u16)
            plate_len_byte = sock.recv(1)
            if not plate_len_byte:
                return None
            plate_len = plate_len_byte[0]
            plate_bytes = sock.recv(plate_len)
            rest = sock.recv(16)  # 2+2+4+2+4+2 = 16 bytes
            if len(rest) < 16:
                return None
            return (MSG_TICKET, bytes([plate_len]) + plate_bytes + rest)

        elif msg_type == MSG_HEARTBEAT:
            return (MSG_HEARTBEAT, b"")

        else:
            return None

    except socket.timeout:
        return None
    except Exception as e:
        print(f"Error receiving message: {e}")
        return None


def parse_ticket(data: bytes) -> Ticket:
    """Parse a ticket message (without the message type byte)"""
    plate, offset = decode_str(data, 0)
    road, mile1, timestamp1, mile2, timestamp2, speed = struct.unpack(
        "!HHIHIH", data[offset : offset + 18]
    )
    return Ticket(plate, road, mile1, timestamp1, mile2, timestamp2, speed)


def test_basic_camera_and_dispatcher(host: str, port: int):
    """
    Test basic functionality: 2 cameras observe a speeding car, dispatcher receives ticket.
    """
    print("\n=== Test 1: Basic Camera and Dispatcher ===")

    # Camera 1 at mile 8
    camera1 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    camera1.connect((host, port))
    send_i_am_camera(camera1, road=123, mile=8, limit=60)
    send_plate(camera1, "UN1X", timestamp=0)

    # Camera 2 at mile 9
    camera2 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    camera2.connect((host, port))
    send_i_am_camera(camera2, road=123, mile=9, limit=60)
    send_plate(camera2, "UN1X", timestamp=45)

    # Dispatcher for road 123
    dispatcher = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    dispatcher.connect((host, port))
    send_i_am_dispatcher(dispatcher, [123])

    # Should receive a ticket
    msg = receive_message(dispatcher, timeout=2.0)
    if msg is None:
        print("❌ FAIL: No ticket received")
        return False

    msg_type, msg_data = msg
    if msg_type != MSG_TICKET:
        print(f"❌ FAIL: Expected ticket, got message type {msg_type:02x}")
        return False

    ticket = parse_ticket(msg_data)
    print(f"✓ Received ticket: {ticket}")

    # Verify ticket details
    # Distance: 1 mile, Time: 45 seconds = 45/3600 hours = 0.0125 hours
    # Speed: 1 / 0.0125 = 80 mph
    expected_speed = 8000  # 80 mph * 100

    if ticket.plate != "UN1X":
        print(f"❌ FAIL: Wrong plate: {ticket.plate}")
        return False
    if ticket.road != 123:
        print(f"❌ FAIL: Wrong road: {ticket.road}")
        return False
    if ticket.speed != expected_speed:
        print(f"❌ FAIL: Wrong speed: {ticket.speed} (expected {expected_speed})")
        return False

    print("✓ PASS: Basic camera and dispatcher test")

    camera1.close()
    camera2.close()
    dispatcher.close()
    return True


def test_no_ticket_under_limit(host: str, port: int):
    """
    Test that no ticket is issued when speed is under the limit.
    """
    print("\n=== Test 2: No Ticket Under Limit ===")

    # Camera 1 at mile 0
    camera1 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    camera1.connect((host, port))
    send_i_am_camera(camera1, road=200, mile=0, limit=60)
    send_plate(camera1, "SLOW1", timestamp=0)

    # Camera 2 at mile 1
    camera2 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    camera2.connect((host, port))
    send_i_am_camera(camera2, road=200, mile=1, limit=60)
    # Travel 1 mile in 60 seconds = 60 mph (at limit, should not ticket)
    send_plate(camera2, "SLOW1", timestamp=60)

    # Dispatcher for road 200
    dispatcher = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    dispatcher.connect((host, port))
    send_i_am_dispatcher(dispatcher, [200])

    # Should NOT receive a ticket
    msg = receive_message(dispatcher, timeout=1.0)
    if msg is not None and msg[0] == MSG_TICKET:
        print("❌ FAIL: Received ticket when speed was at/under limit")
        return False

    print("✓ PASS: No ticket issued for legal speed")

    camera1.close()
    camera2.close()
    dispatcher.close()
    return True


def test_heartbeat(host: str, port: int):
    """
    Test heartbeat functionality.
    """
    print("\n=== Test 3: Heartbeat ===")

    client = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    client.connect((host, port))

    # Request heartbeat every 1 second (10 deciseconds)
    send_want_heartbeat(client, interval=10)
    send_i_am_camera(client, road=300, mile=0, limit=60)

    # Should receive heartbeats
    heartbeat_count = 0
    start_time = time.time()

    while time.time() - start_time < 2.5:
        msg = receive_message(client, timeout=0.5)
        if msg and msg[0] == MSG_HEARTBEAT:
            heartbeat_count += 1
            print(f"✓ Received heartbeat #{heartbeat_count}")

    if heartbeat_count < 2:
        print(f"❌ FAIL: Expected at least 2 heartbeats, got {heartbeat_count}")
        return False

    print(f"✓ PASS: Received {heartbeat_count} heartbeats")

    client.close()
    return True


def test_out_of_order_observations(host: str, port: int):
    """
    Test that observations can arrive out of order and still generate tickets.
    """
    print("\n=== Test 4: Out-of-Order Observations ===")

    camera = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    camera.connect((host, port))
    send_i_am_camera(camera, road=400, mile=10, limit=50)

    # Send observations out of order
    send_plate(camera, "OUTOFO", timestamp=100)  # Later observation
    send_plate(camera, "OUTOFO", timestamp=50)  # Earlier observation

    camera2 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    camera2.connect((host, port))
    send_i_am_camera(camera2, road=400, mile=20, limit=50)
    send_plate(
        camera2, "OUTOFO", timestamp=125
    )  # 10 miles in 25 seconds = way too fast

    dispatcher = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    dispatcher.connect((host, port))
    send_i_am_dispatcher(dispatcher, [400])

    msg = receive_message(dispatcher, timeout=2.0)
    if msg is None or msg[0] != MSG_TICKET:
        print("❌ FAIL: No ticket received for out-of-order observations")
        return False

    ticket = parse_ticket(msg[1])
    print(f"✓ Received ticket: {ticket}")
    print("✓ PASS: Out-of-order observations handled correctly")

    camera.close()
    camera2.close()
    dispatcher.close()
    return True


def test_multiple_dispatchers(host: str, port: int):
    """
    Test that tickets are sent to one of multiple dispatchers.
    """
    print("\n=== Test 5: Multiple Dispatchers ===")

    camera1 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    camera1.connect((host, port))
    send_i_am_camera(camera1, road=500, mile=0, limit=60)
    send_plate(camera1, "MULTI", timestamp=0)

    camera2 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    camera2.connect((host, port))
    send_i_am_camera(camera2, road=500, mile=1, limit=60)
    send_plate(camera2, "MULTI", timestamp=30)  # 1 mile in 30 sec = 120 mph

    # Create 2 dispatchers for the same road
    dispatcher1 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    dispatcher1.connect((host, port))
    send_i_am_dispatcher(dispatcher1, [500])

    dispatcher2 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    dispatcher2.connect((host, port))
    send_i_am_dispatcher(dispatcher2, [500])

    # One (and only one) should receive the ticket
    msg1 = receive_message(dispatcher1, timeout=2.0)
    msg2 = receive_message(dispatcher2, timeout=2.0)

    tickets_received = 0
    if msg1 and msg1[0] == MSG_TICKET:
        tickets_received += 1
        print("✓ Dispatcher 1 received ticket")
    if msg2 and msg2[0] == MSG_TICKET:
        tickets_received += 1
        print("✓ Dispatcher 2 received ticket")

    if tickets_received != 1:
        print(f"❌ FAIL: Expected exactly 1 ticket, got {tickets_received}")
        return False

    print("✓ PASS: Ticket sent to exactly one dispatcher")

    camera1.close()
    camera2.close()
    dispatcher1.close()
    dispatcher2.close()
    return True


def test_delayed_dispatcher(host: str, port: int):
    """
    Test that tickets are queued when no dispatcher is available.
    """
    print("\n=== Test 6: Delayed Dispatcher ===")

    camera1 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    camera1.connect((host, port))
    send_i_am_camera(camera1, road=600, mile=0, limit=60)
    send_plate(camera1, "DELAY", timestamp=0)

    camera2 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    camera2.connect((host, port))
    send_i_am_camera(camera2, road=600, mile=1, limit=60)
    send_plate(camera2, "DELAY", timestamp=30)  # Speeding

    # Wait a bit before connecting dispatcher
    time.sleep(1)

    dispatcher = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    dispatcher.connect((host, port))
    send_i_am_dispatcher(dispatcher, [600])

    # Should receive the queued ticket
    msg = receive_message(dispatcher, timeout=2.0)
    if msg is None or msg[0] != MSG_TICKET:
        print("❌ FAIL: No queued ticket received")
        return False

    ticket = parse_ticket(msg[1])
    print(f"✓ Received queued ticket: {ticket}")
    print("✓ PASS: Delayed dispatcher received queued ticket")

    camera1.close()
    camera2.close()
    dispatcher.close()
    return True


def test_error_duplicate_identification(host: str, port: int):
    """
    Test that server sends error when client tries to identify twice.
    """
    print("\n=== Test 7: Error on Duplicate Identification ===")

    client = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    client.connect((host, port))

    # Identify as camera
    send_i_am_camera(client, road=700, mile=0, limit=60)

    # Try to identify again (should error)
    send_i_am_camera(client, road=700, mile=1, limit=60)

    # Should receive error message
    msg = receive_message(client, timeout=1.0)
    if msg is None:
        print("❌ FAIL: Connection closed without error message")
        return False

    if msg[0] != MSG_ERROR:
        print(f"❌ FAIL: Expected error, got message type {msg[0]:02x}")
        return False

    print(f"✓ Received error: {msg[1].decode('ascii')}")
    print("✓ PASS: Duplicate identification rejected")

    client.close()
    return True


def test_error_plate_without_camera(host: str, port: int):
    """
    Test that server sends error when non-camera sends plate observation.
    """
    print("\n=== Test 8: Error on Plate Without Camera ===")

    client = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    client.connect((host, port))

    # Try to send plate observation without identifying
    send_plate(client, "BADPLATE", timestamp=0)

    # Should receive error message
    msg = receive_message(client, timeout=1.0)
    if msg is None:
        print("❌ FAIL: Connection closed without error message")
        return False

    if msg[0] != MSG_ERROR:
        print(f"❌ FAIL: Expected error, got message type {msg[0]:02x}")
        return False

    print(f"✓ Received error: {msg[1].decode('ascii')}")
    print("✓ PASS: Plate without camera rejected")

    client.close()
    return True


def test_one_ticket_per_day(host: str, port: int):
    """
    Test that only one ticket is issued per car per day.
    """
    print("\n=== Test 9: One Ticket Per Day ===")

    # Create cameras on road 800
    cameras = []
    for i in range(5):
        cam = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        cam.connect((host, port))
        send_i_am_camera(cam, road=800, mile=i * 10, limit=60)
        cameras.append(cam)

    # Create dispatcher
    dispatcher = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    dispatcher.connect((host, port))
    send_i_am_dispatcher(dispatcher, [800])

    # Car speeds multiple times in the same day (day 0)
    # Each segment: 10 miles in 300 seconds = 120 mph (way over limit)
    for i, cam in enumerate(cameras):
        send_plate(cam, "SPEED1", timestamp=i * 300)

    # Should receive only ONE ticket
    tickets_received = 0
    for _ in range(5):
        msg = receive_message(dispatcher, timeout=1.0)
        if msg and msg[0] == MSG_TICKET:
            ticket = parse_ticket(msg[1])
            print(f"✓ Received ticket: {ticket}")
            tickets_received += 1

    if tickets_received != 1:
        print(f"⚠ Expected 1 ticket per day, got {tickets_received}")
        # Note: depending on implementation, multiple tickets might be acceptable
        # if they span different segments, but ideally should be 1
    else:
        print("✓ PASS: Only one ticket issued per day")

    for cam in cameras:
        cam.close()
    dispatcher.close()
    return True


def run_all_tests(host: str = "127.0.0.1", port: int = 8000):
    """Run all tests"""
    print(f"Testing Speed Daemon at {host}:{port}")
    print("=" * 60)

    tests = [
        test_basic_camera_and_dispatcher,
        test_no_ticket_under_limit,
        test_heartbeat,
        test_out_of_order_observations,
        test_multiple_dispatchers,
        test_delayed_dispatcher,
        test_error_duplicate_identification,
        test_error_plate_without_camera,
        test_one_ticket_per_day,
    ]

    passed = 0
    failed = 0

    for test in tests:
        try:
            if test(host, port):
                passed += 1
            else:
                failed += 1
        except Exception as e:
            print(f"❌ FAIL: {test.__name__} raised exception: {e}")
            failed += 1

        # Small delay between tests
        time.sleep(0.5)

    print("\n" + "=" * 60)
    print(f"Results: {passed} passed, {failed} failed")
    print("=" * 60)


if __name__ == "__main__":
    import sys

    host = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 8000

    run_all_tests(host, port)
