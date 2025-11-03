#!/usr/bin/env python3
"""
Test client for Protohackers "Means to an End" challenge.
Tests a local TCP server that tracks timestamped prices.
"""

import socket
import struct
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import List, Tuple, Optional


class PriceClient:
    """Client for the Means to an End protocol."""

    def __init__(self, host: str = "localhost", port: int = 8080):
        self.host = host
        self.port = port
        self.sock = None

    def connect(self):
        """Connect to the server."""
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.connect((self.host, self.port))

    def close(self):
        """Close the connection."""
        if self.sock:
            self.sock.close()

    def insert(self, timestamp: int, price: int):
        """Insert a price at a timestamp."""
        # Format: 'I' (1 byte) + timestamp (4 bytes, big-endian) + price (4 bytes, big-endian)
        message = struct.pack('>cii', b'I', timestamp, price)
        self.sock.sendall(message)

    def query(self, mintime: int, maxtime: int) -> int:
        """Query the mean price between mintime and maxtime."""
        # Format: 'Q' (1 byte) + mintime (4 bytes) + maxtime (4 bytes)
        message = struct.pack('>cii', b'Q', mintime, maxtime)
        self.sock.sendall(message)

        # Receive response: 4 bytes (int32)
        response = self.sock.recv(4)
        if len(response) != 4:
            raise Exception(f"Expected 4 bytes, got {len(response)}")

        mean = struct.unpack('>i', response)[0]
        return mean

    def __enter__(self):
        self.connect()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.close()


def test_basic_example(host: str, port: int) -> bool:
    """Test the example from the problem statement."""
    print("\n=== Test: Basic Example ===")
    try:
        with PriceClient(host, port) as client:
            # Insert from example
            client.insert(12345, 101)
            client.insert(12346, 102)
            client.insert(12347, 100)
            client.insert(40960, 5)

            # Query from example
            result = client.query(12288, 16384)
            expected = 101  # Mean of 101, 102, 100 = 303/3 = 101

            print(f"Query [12288, 16384]: got {result}, expected {expected}")
            if result == expected:
                print("✓ PASSED")
                return True
            else:
                print("✗ FAILED")
                return False
    except Exception as e:
        print(f"✗ FAILED with exception: {e}")
        return False


def test_out_of_order_inserts(host: str, port: int) -> bool:
    """Test that out-of-order inserts work correctly."""
    print("\n=== Test: Out of Order Inserts ===")
    try:
        with PriceClient(host, port) as client:
            # Insert in non-chronological order
            client.insert(1000, 100)
            client.insert(3000, 300)
            client.insert(2000, 200)
            client.insert(500, 50)

            # Query all
            result = client.query(0, 4000)
            expected = 162  # (100 + 300 + 200 + 50) / 4 = 162.5, rounds to 162 or 163

            print(f"Query [0, 4000]: got {result}, expected ~{expected}")
            # Allow for rounding either way
            if result in [162, 163]:
                print("✓ PASSED")
                return True
            else:
                print(f"✗ FAILED (expected 162 or 163)")
                return False
    except Exception as e:
        print(f"✗ FAILED with exception: {e}")
        return False


def test_empty_query(host: str, port: int) -> bool:
    """Test query with no data in range returns 0."""
    print("\n=== Test: Empty Query ===")
    try:
        with PriceClient(host, port) as client:
            client.insert(1000, 100)
            client.insert(2000, 200)

            # Query outside range
            result = client.query(3000, 4000)
            expected = 0

            print(f"Query [3000, 4000] (no data): got {result}, expected {expected}")
            if result == expected:
                print("✓ PASSED")
                return True
            else:
                print("✗ FAILED")
                return False
    except Exception as e:
        print(f"✗ FAILED with exception: {e}")
        return False


def test_inverted_range(host: str, port: int) -> bool:
    """Test query where mintime > maxtime returns 0."""
    print("\n=== Test: Inverted Range ===")
    try:
        with PriceClient(host, port) as client:
            client.insert(1000, 100)
            client.insert(2000, 200)

            # Query with mintime > maxtime
            result = client.query(2000, 1000)
            expected = 0

            print(f"Query [2000, 1000] (inverted): got {result}, expected {expected}")
            if result == expected:
                print("✓ PASSED")
                return True
            else:
                print("✗ FAILED")
                return False
    except Exception as e:
        print(f"✗ FAILED with exception: {e}")
        return False


def test_negative_prices(host: str, port: int) -> bool:
    """Test that negative prices work correctly."""
    print("\n=== Test: Negative Prices ===")
    try:
        with PriceClient(host, port) as client:
            client.insert(1000, -100)
            client.insert(2000, 100)
            client.insert(3000, -50)

            # Query all
            result = client.query(0, 4000)
            expected = -16  # (-100 + 100 + -50) / 3 = -16.666..., rounds to -16 or -17

            print(f"Query [0, 4000]: got {result}, expected ~{expected}")
            if result in [-16, -17]:
                print("✓ PASSED")
                return True
            else:
                print(f"✗ FAILED (expected -16 or -17)")
                return False
    except Exception as e:
        print(f"✗ FAILED with exception: {e}")
        return False


def test_edge_case_single_value(host: str, port: int) -> bool:
    """Test query with exactly one value in range."""
    print("\n=== Test: Single Value in Range ===")
    try:
        with PriceClient(host, port) as client:
            client.insert(1000, 42)
            client.insert(2000, 100)

            # Query that includes only one value
            result = client.query(1000, 1000)
            expected = 42

            print(f"Query [1000, 1000]: got {result}, expected {expected}")
            if result == expected:
                print("✓ PASSED")
                return True
            else:
                print("✗ FAILED")
                return False
    except Exception as e:
        print(f"✗ FAILED with exception: {e}")
        return False


def test_boundary_values(host: str, port: int) -> bool:
    """Test with boundary timestamp values."""
    print("\n=== Test: Boundary Values ===")
    try:
        with PriceClient(host, port) as client:
            # Test with 0 timestamp
            client.insert(0, 100)
            result = client.query(0, 0)

            print(f"Query at timestamp 0: got {result}, expected 100")
            if result != 100:
                print("✗ FAILED")
                return False

            # Test with large timestamp
            client.insert(2147483647, 200)  # Max int32
            result = client.query(2147483647, 2147483647)

            print(f"Query at max timestamp: got {result}, expected 200")
            if result == 200:
                print("✓ PASSED")
                return True
            else:
                print("✗ FAILED")
                return False
    except Exception as e:
        print(f"✗ FAILED with exception: {e}")
        return False


def test_many_inserts(host: str, port: int) -> bool:
    """Test with many inserts."""
    print("\n=== Test: Many Inserts ===")
    try:
        with PriceClient(host, port) as client:
            # Insert 100 values
            for i in range(100):
                client.insert(i * 100, i)

            # Query all - mean should be 49.5
            result = client.query(0, 10000)

            print(f"Query [0, 10000] with 100 values: got {result}, expected 49 or 50")
            if result in [49, 50]:
                print("✓ PASSED")
                return True
            else:
                print("✗ FAILED")
                return False
    except Exception as e:
        print(f"✗ FAILED with exception: {e}")
        return False


def test_multiple_queries(host: str, port: int) -> bool:
    """Test multiple queries on the same connection."""
    print("\n=== Test: Multiple Queries ===")
    try:
        with PriceClient(host, port) as client:
            # Insert some data
            client.insert(1000, 100)
            client.insert(2000, 200)
            client.insert(3000, 300)

            # Multiple queries
            result1 = client.query(1000, 1000)
            result2 = client.query(2000, 2000)
            result3 = client.query(1000, 3000)

            print(f"Query 1 [1000, 1000]: got {result1}, expected 100")
            print(f"Query 2 [2000, 2000]: got {result2}, expected 200")
            print(f"Query 3 [1000, 3000]: got {result3}, expected 200")

            if result1 == 100 and result2 == 200 and result3 == 200:
                print("✓ PASSED")
                return True
            else:
                print("✗ FAILED")
                return False
    except Exception as e:
        print(f"✗ FAILED with exception: {e}")
        return False


def single_client_session(client_id: int, host: str, port: int) -> bool:
    """Run a single client session for concurrent testing."""
    try:
        with PriceClient(host, port) as client:
            # Each client inserts its own data
            base = client_id * 1000
            client.insert(base + 1, 100)
            client.insert(base + 2, 200)
            client.insert(base + 3, 300)

            # Query own data
            result = client.query(base, base + 10)
            expected = 200  # Mean of 100, 200, 300

            return result == expected
    except Exception as e:
        print(f"Client {client_id} failed: {e}")
        return False


def test_concurrent_clients(host: str, port: int) -> bool:
    """Test multiple concurrent client connections."""
    print("\n=== Test: Concurrent Clients (5 simultaneous) ===")
    try:
        num_clients = 5
        with ThreadPoolExecutor(max_workers=num_clients) as executor:
            futures = [
                executor.submit(single_client_session, i, host, port)
                for i in range(num_clients)
            ]

            results = [future.result() for future in as_completed(futures)]

            passed = sum(results)
            print(f"Passed: {passed}/{num_clients} clients")

            if passed == num_clients:
                print("✓ PASSED")
                return True
            else:
                print("✗ FAILED")
                return False
    except Exception as e:
        print(f"✗ FAILED with exception: {e}")
        return False


def test_interleaved_operations(host: str, port: int) -> bool:
    """Test interleaved inserts and queries."""
    print("\n=== Test: Interleaved Operations ===")
    try:
        with PriceClient(host, port) as client:
            client.insert(1000, 100)
            result1 = client.query(1000, 1000)

            client.insert(2000, 200)
            result2 = client.query(1000, 2000)

            client.insert(3000, 300)
            result3 = client.query(1000, 3000)

            print(f"After 1 insert: {result1} (expected 100)")
            print(f"After 2 inserts: {result2} (expected 150)")
            print(f"After 3 inserts: {result3} (expected 200)")

            if result1 == 100 and result2 == 150 and result3 == 200:
                print("✓ PASSED")
                return True
            else:
                print("✗ FAILED")
                return False
    except Exception as e:
        print(f"✗ FAILED with exception: {e}")
        return False


def run_all_tests(host: str = "localhost", port: int = 8080, exit_on_failure: bool = True):
    """Run all test cases."""
    print(f"\n{'='*60}")
    print(f"Running Means to an End Test Suite")
    print(f"Testing server at {host}:{port}")
    print(f"{'='*60}")

    tests = [
        ("Basic Example", test_basic_example),
        ("Out of Order Inserts", test_out_of_order_inserts),
        ("Empty Query", test_empty_query),
        ("Inverted Range", test_inverted_range),
        ("Negative Prices", test_negative_prices),
        ("Single Value in Range", test_edge_case_single_value),
        ("Boundary Values", test_boundary_values),
        ("Many Inserts", test_many_inserts),
        ("Multiple Queries", test_multiple_queries),
        ("Interleaved Operations", test_interleaved_operations),
        ("Concurrent Clients", test_concurrent_clients),
    ]

    results = []
    for name, test_func in tests:
        try:
            result = test_func(host, port)
            results.append((name, result))

            if not result and exit_on_failure:
                print(f"\n{'='*60}")
                print(f"⛔ Stopping on first failure: {name}")
                print(f"{'='*60}")
                return False

            time.sleep(0.1)  # Small delay between tests
        except Exception as e:
            print(f"\n✗ Test '{name}' crashed: {e}")
            results.append((name, False))

            if exit_on_failure:
                print(f"\n{'='*60}")
                print(f"⛔ Stopping on first failure: {name}")
                print(f"{'='*60}")
                return False

    # Summary
    print(f"\n{'='*60}")
    print("Test Summary")
    print(f"{'='*60}")

    passed = sum(1 for _, result in results if result)
    total = len(results)

    for name, result in results:
        status = "✓ PASS" if result else "✗ FAIL"
        print(f"{status}: {name}")

    print(f"\n{passed}/{total} tests passed")

    if passed == total:
        print("\n🎉 All tests passed! Your server is ready.")
    else:
        print(f"\n⚠️  {total - passed} test(s) failed. Keep debugging!")

    return passed == total


if __name__ == "__main__":
    import sys

    host = "localhost"
    port = 3002

    try:
        run_all_tests(host, port)
    except KeyboardInterrupt:
        print("\n\nTests interrupted by user.")
    except Exception as e:
        print(f"\n\nFatal error: {e}")
        sys.exit(1)
