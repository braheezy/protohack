#!/usr/bin/env python3
"""
Test client for Protohackers "Unusual Database Program" challenge.
Tests a local UDP server implementing Ken's key-value store protocol.
"""

import socket
import time
from typing import Optional

HOST = '127.0.0.1'
PORT = 3004


class UDPClient:
    """Client for Ken's Unusual Database Program."""

    def __init__(self, host: str = HOST, port: int = PORT):
        self.host = host
        self.port = port
        self.sock = None

    def connect(self):
        """Create UDP socket."""
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.settimeout(1.0)  # 1 second timeout for responses

    def close(self):
        """Close the socket."""
        if self.sock:
            self.sock.close()

    def insert(self, key: str, value: str):
        """Insert a key-value pair. Returns None (no response expected)."""
        message = f"{key}={value}"
        self.sock.sendto(message.encode('utf-8'), (self.host, self.port))
        # No response expected for inserts

    def retrieve(self, key: str) -> Optional[str]:
        """Retrieve a value for a key. Returns the full response or None if no response."""
        message = key
        self.sock.sendto(message.encode('utf-8'), (self.host, self.port))

        try:
            data, _ = self.sock.recvfrom(1000)
            return data.decode('utf-8')
        except socket.timeout:
            return None

    def __enter__(self):
        self.connect()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.close()


def test_basic_insert_retrieve():
    """Test basic insert and retrieve operations."""
    print("\n=== Test: Basic Insert and Retrieve ===")
    try:
        with UDPClient() as client:
            # Insert a key-value pair
            client.insert("foo", "bar")
            time.sleep(0.1)  # Small delay

            # Retrieve it
            response = client.retrieve("foo")
            expected = "foo=bar"

            print(f"Insert: foo=bar")
            print(f"Retrieve 'foo': got '{response}', expected '{expected}'")

            if response == expected:
                print("✓ PASSED")
                return True
            else:
                print("✗ FAILED")
                return False
    except Exception as e:
        print(f"✗ FAILED with exception: {e}")
        return False


def test_value_with_equals():
    """Test that values can contain equals signs."""
    print("\n=== Test: Value with Equals Signs ===")
    try:
        with UDPClient() as client:
            # Insert with equals in value
            client.insert("foo", "bar=baz")
            time.sleep(0.1)

            response = client.retrieve("foo")
            expected = "foo=bar=baz"

            print(f"Insert: foo=bar=baz")
            print(f"Retrieve 'foo': got '{response}', expected '{expected}'")

            if response == expected:
                print("✓ PASSED")
                return True
            else:
                print("✗ FAILED")
                return False
    except Exception as e:
        print(f"✗ FAILED with exception: {e}")
        return False


def test_empty_value():
    """Test that empty values work correctly."""
    print("\n=== Test: Empty Value ===")
    try:
        with UDPClient() as client:
            # Insert with empty value
            client.insert("foo", "")
            time.sleep(0.1)

            response = client.retrieve("foo")
            expected = "foo="

            print(f"Insert: foo=")
            print(f"Retrieve 'foo': got '{response}', expected '{expected}'")

            if response == expected:
                print("✓ PASSED")
                return True
            else:
                print("✗ FAILED")
                return False
    except Exception as e:
        print(f"✗ FAILED with exception: {e}")
        return False


def test_empty_key():
    """Test that empty keys work correctly."""
    print("\n=== Test: Empty Key ===")
    try:
        with UDPClient() as client:
            # Insert with empty key
            client.insert("", "foo")
            time.sleep(0.1)

            response = client.retrieve("")
            expected = "=foo"

            print(f"Insert: =foo")
            print(f"Retrieve '': got '{response}', expected '{expected}'")

            if response == expected:
                print("✓ PASSED")
                return True
            else:
                print("✗ FAILED")
                return False
    except Exception as e:
        print(f"✗ FAILED with exception: {e}")
        return False


def test_multiple_equals_in_value():
    """Test values with multiple equals signs."""
    print("\n=== Test: Multiple Equals in Value ===")
    try:
        with UDPClient() as client:
            client.insert("foo", "==")
            time.sleep(0.1)

            response = client.retrieve("foo")
            expected = "foo==="

            print(f"Insert: foo===")
            print(f"Retrieve 'foo': got '{response}', expected '{expected}'")

            if response == expected:
                print("✓ PASSED")
                return True
            else:
                print("✗ FAILED")
                return False
    except Exception as e:
        print(f"✗ FAILED with exception: {e}")
        return False


def test_update_existing_key():
    """Test that updating existing keys works correctly."""
    print("\n=== Test: Update Existing Key ===")
    try:
        with UDPClient() as client:
            # Insert initial value
            client.insert("foo", "bar")
            time.sleep(0.1)

            # Update with new value
            client.insert("foo", "baz")
            time.sleep(0.1)

            # Should get the most recent value
            response = client.retrieve("foo")
            expected = "foo=baz"

            print(f"Insert: foo=bar, then foo=baz")
            print(f"Retrieve 'foo': got '{response}', expected '{expected}'")

            if response == expected:
                print("✓ PASSED")
                return True
            else:
                print("✗ FAILED")
                return False
    except Exception as e:
        print(f"✗ FAILED with exception: {e}")
        return False


def test_nonexistent_key():
    """Test retrieving a key that doesn't exist."""
    print("\n=== Test: Nonexistent Key ===")
    try:
        with UDPClient() as client:
            response = client.retrieve("nonexistent")

            print(f"Retrieve 'nonexistent': got '{response}'")

            # Server can return either "nonexistent=" or None
            if response is None or response == "nonexistent=":
                print("✓ PASSED (server can return empty value or no response)")
                return True
            else:
                print("✗ FAILED")
                return False
    except Exception as e:
        print(f"✗ FAILED with exception: {e}")
        return False


def test_version_key():
    """Test the special 'version' key."""
    print("\n=== Test: Version Key ===")
    try:
        with UDPClient() as client:
            response = client.retrieve("version")

            print(f"Retrieve 'version': got '{response}'")

            if response and response.startswith("version=") and len(response) > 8:
                print("✓ PASSED")
                return True
            else:
                print("✗ FAILED (version must not be empty)")
                return False
    except Exception as e:
        print(f"✗ FAILED with exception: {e}")
        return False


def test_version_immutable():
    """Test that the 'version' key cannot be modified."""
    print("\n=== Test: Version is Immutable ===")
    try:
        with UDPClient() as client:
            # Get initial version
            initial_version = client.retrieve("version")
            print(f"Initial version: {initial_version}")

            # Try to update it
            client.insert("version", "hacked!")
            time.sleep(0.1)

            # Version should remain unchanged
            final_version = client.retrieve("version")
            print(f"After attempted update: {final_version}")

            if initial_version == final_version:
                print("✓ PASSED")
                return True
            else:
                print("✗ FAILED (version should not change)")
                return False
    except Exception as e:
        print(f"✗ FAILED with exception: {e}")
        return False


def test_multiple_keys():
    """Test storing and retrieving multiple different keys."""
    print("\n=== Test: Multiple Keys ===")
    try:
        with UDPClient() as client:
            # Insert multiple keys
            client.insert("key1", "value1")
            client.insert("key2", "value2")
            client.insert("key3", "value3")
            time.sleep(0.1)

            # Retrieve all of them
            r1 = client.retrieve("key1")
            r2 = client.retrieve("key2")
            r3 = client.retrieve("key3")

            print(f"key1: {r1}")
            print(f"key2: {r2}")
            print(f"key3: {r3}")

            if r1 == "key1=value1" and r2 == "key2=value2" and r3 == "key3=value3":
                print("✓ PASSED")
                return True
            else:
                print("✗ FAILED")
                return False
    except Exception as e:
        print(f"✗ FAILED with exception: {e}")
        return False


def test_special_characters():
    """Test keys and values with special characters."""
    print("\n=== Test: Special Characters ===")
    try:
        with UDPClient() as client:
            # Test various special characters (but not equals in keys)
            client.insert("key-with-dashes", "value with spaces!")
            client.insert("key_with_underscores", "value@#$%")
            time.sleep(0.1)

            r1 = client.retrieve("key-with-dashes")
            r2 = client.retrieve("key_with_underscores")

            print(f"key-with-dashes: {r1}")
            print(f"key_with_underscores: {r2}")

            if r1 == "key-with-dashes=value with spaces!" and r2 == "key_with_underscores=value@#$%":
                print("✓ PASSED")
                return True
            else:
                print("✗ FAILED")
                return False
    except Exception as e:
        print(f"✗ FAILED with exception: {e}")
        return False


def test_long_messages():
    """Test messages close to the 1000 byte limit."""
    print("\n=== Test: Long Messages (< 1000 bytes) ===")
    try:
        with UDPClient() as client:
            # Create a long value (but keep total message under 1000 bytes)
            long_value = "x" * 900
            client.insert("longkey", long_value)
            time.sleep(0.1)

            response = client.retrieve("longkey")
            expected = f"longkey={long_value}"

            print(f"Inserted value of length {len(long_value)}")
            print(f"Response length: {len(response) if response else 0}")

            if response == expected:
                print("✓ PASSED")
                return True
            else:
                print("✗ FAILED")
                return False
    except Exception as e:
        print(f"✗ FAILED with exception: {e}")
        return False


def run_all_tests():
    """Run all test cases."""
    print(f"\n{'='*60}")
    print(f"Running Unusual Database Program Test Suite")
    print(f"Testing server at {HOST}:{PORT}")
    print(f"{'='*60}")

    tests = [
        ("Basic Insert and Retrieve", test_basic_insert_retrieve),
        ("Value with Equals Signs", test_value_with_equals),
        ("Empty Value", test_empty_value),
        ("Empty Key", test_empty_key),
        ("Multiple Equals in Value", test_multiple_equals_in_value),
        ("Update Existing Key", test_update_existing_key),
        ("Nonexistent Key", test_nonexistent_key),
        ("Version Key", test_version_key),
        ("Version is Immutable", test_version_immutable),
        ("Multiple Keys", test_multiple_keys),
        ("Special Characters", test_special_characters),
        ("Long Messages", test_long_messages),
    ]

    results = []
    for name, test_func in tests:
        try:
            result = test_func()
            results.append((name, result))
            time.sleep(0.2)  # Small delay between tests
        except Exception as e:
            print(f"\n✗ Test '{name}' crashed: {e}")
            results.append((name, False))

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

    try:
        run_all_tests()
    except KeyboardInterrupt:
        print("\n\nTests interrupted by user.")
    except Exception as e:
        print(f"\n\nFatal error: {e}")
        sys.exit(1)
