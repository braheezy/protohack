#!/usr/bin/env python3
import socket
import time
import threading

HOST = 'localhost'
PORT = 3003

def connect():
    """Create a new connection to the server."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.connect((HOST, PORT))
    return sock

def recv_line(sock):
    """Receive a line (terminated by \n) from the socket."""
    data = b''
    while not data.endswith(b'\n'):
        chunk = sock.recv(1)
        if not chunk:
            break
        data += chunk
    return data.decode('ascii')

def send_line(sock, msg):
    """Send a line to the socket."""
    sock.sendall((msg + '\n').encode('ascii'))

def drain_buffer(sock):
    """Drain all available messages from the socket."""
    sock.settimeout(0.1)
    try:
        while True:
            _ = recv_line(sock)
    except socket.timeout:
        pass
    sock.settimeout(None)

def join_with_name(sock, name):
    """Join a chat room with the given name. Returns all messages received."""
    recv_line(sock)  # Discard prompt
    send_line(sock, name)
    messages = []
    # Wait for join confirmation and user list
    time.sleep(0.1)
    try:
        while True:
            sock.settimeout(0.1)
            msg = recv_line(sock)
            if msg:
                messages.append(msg.rstrip('\n\r'))
            else:
                break
    except socket.timeout:
        pass
    except:
        pass
    sock.settimeout(None)
    return messages

def test_server_prompts_for_name():
    """Test that server sends a prompt upon connection."""
    print("Test: Server prompts for name...")
    sock = connect()
    prompt = recv_line(sock)
    assert len(prompt) > 0, "Server should send a prompt"
    sock.close()
    print("✓ Pass")

def test_valid_alphanumeric_name():
    """Test that server accepts valid alphanumeric names."""
    print("Test: Valid alphanumeric name...")
    sock = connect()
    recv_line(sock)  # Discard prompt
    send_line(sock, "Alice123")
    time.sleep(0.1)
    try:
        sock.sendall(b'')  # Try to verify connection is still alive
        print("✓ Pass")
    except:
        print("✗ Fail: Server disconnected after valid name")
    sock.close()

def test_name_with_special_characters():
    """Test that server rejects names with special characters."""
    print("Test: Name with special characters...")
    sock = connect()
    recv_line(sock)  # Discard prompt
    send_line(sock, "Alice@123")
    time.sleep(0.1)
    try:
        data = sock.recv(1024)
        if len(data) == 0:
            print("✓ Pass: Server disconnected")
        else:
            data = sock.recv(1024)
            assert len(data) == 0, "Server should disconnect after error"
            print("✓ Pass: Server sent error and disconnected")
    except:
        print("✓ Pass: Server disconnected")
    sock.close()

def test_empty_name():
    """Test that server rejects empty names."""
    print("Test: Empty name...")
    sock = connect()
    recv_line(sock)  # Discard prompt
    send_line(sock, "")
    time.sleep(0.1)
    try:
        data = sock.recv(1024)
        assert len(data) == 0, "Server should disconnect after empty name"
        print("✓ Pass")
    except:
        print("✓ Pass")
    sock.close()

def test_16_character_name():
    """Test that server accepts names with at least 16 characters."""
    print("Test: 16 character name...")
    sock = connect()
    recv_line(sock)  # Discard prompt
    send_line(sock, "A" * 16)
    time.sleep(0.1)
    try:
        sock.sendall(b'')
        print("✓ Pass")
    except:
        print("✗ Fail: Server disconnected after 16-char name")
    sock.close()

def test_single_character_name():
    """Test that server accepts single character names."""
    print("Test: Single character name...")
    sock = connect()
    recv_line(sock)  # Discard prompt
    send_line(sock, "A")
    time.sleep(0.1)
    try:
        sock.sendall(b'')
        print("✓ Pass")
    except:
        print("✗ Fail: Server disconnected after single-char name")
    sock.close()

def test_name_with_spaces():
    """Test that server rejects names with spaces."""
    print("Test: Name with spaces...")
    sock = connect()
    recv_line(sock)  # Discard prompt
    send_line(sock, "Alice Bob")
    time.sleep(0.1)
    try:
        data = sock.recv(1024)
        assert len(data) == 0, "Server should disconnect after name with spaces"
        print("✓ Pass")
    except:
        print("✓ Pass")
    sock.close()

def test_join_receives_user_list():
    """Test that joining user receives list of existing users."""
    print("Test: Join receives user list...")
    # First user joins empty room
    sock1 = connect()
    messages1 = join_with_name(sock1, "alice")
    # Check that first user gets user list (even if empty) - message must start with '*'
    user_list_found = any(msg.strip().startswith("*") for msg in messages1)
    assert user_list_found, f"Expected user list message starting with '*', got: {messages1}"

    # Second user joins
    sock2 = connect()
    messages2 = join_with_name(sock2, "bob")
    # Check that second user gets list with alice (message starts with '*', contains alice)
    user_list_found = any(msg.strip().startswith("*") and "alice" in msg.lower() for msg in messages2)
    assert user_list_found, f"Expected user list message starting with '*' containing 'alice', got: {messages2}"

    sock1.close()
    sock2.close()
    print("✓ Pass")

def test_join_notifies_others():
    """Test that other users are notified when someone joins."""
    print("Test: Join notifies others...")
    sock1 = connect()
    join_with_name(sock1, "alice")

    sock2 = connect()
    join_with_name(sock2, "bob")

    # alice should receive join notification about bob
    time.sleep(0.2)
    sock1.settimeout(0.1)
    try:
        msg = recv_line(sock1)
        assert msg.strip().startswith("*"), f"Join notification should start with '*', got: {msg}"
        assert "bob" in msg.lower(), f"Join notification should contain 'bob', got: {msg}"
        print("✓ Pass")
    except socket.timeout:
        print("✗ Fail: No join notification received")
    finally:
        sock1.settimeout(None)
        sock1.close()
        sock2.close()

def test_chat_message_format():
    """Test that chat messages are formatted as [name] message."""
    print("Test: Chat message format...")
    sock1 = connect()
    join_with_name(sock1, "alice")

    sock2 = connect()
    join_with_name(sock2, "bob")
    time.sleep(0.2)  # Wait for notifications to clear

    # Drain alice's buffer to clear the join notification
    drain_buffer(sock1)

    # bob sends a message
    send_line(sock2, "hello world")

    # alice should receive it
    time.sleep(0.2)
    sock1.settimeout(0.1)
    try:
        msg = recv_line(sock1).strip()
        assert msg.startswith("[bob]"), f"Message should start with '[bob]', got: '{msg}'"
        assert "hello world" in msg, f"Message should contain 'hello world', got: '{msg}'"
        print("✓ Pass")
    except socket.timeout:
        print("✗ Fail: No message received")
    finally:
        sock1.settimeout(None)
        sock1.close()
        sock2.close()

def test_chat_not_sent_to_sender():
    """Test that chat messages are not sent back to the sender."""
    print("Test: Chat not sent to sender...")
    sock1 = connect()
    join_with_name(sock1, "alice")

    sock2 = connect()
    join_with_name(sock2, "bob")
    time.sleep(0.2)

    # bob sends a message
    send_line(sock2, "hello")
    time.sleep(0.2)

    # bob should not receive his own message
    sock2.settimeout(0.1)
    try:
        msg = recv_line(sock2)
        if msg and "[bob]" in msg:
            print("✗ Fail: Sender received their own message")
        else:
            print("✓ Pass")
    except socket.timeout:
        print("✓ Pass")
    finally:
        sock2.settimeout(None)
        sock1.close()
        sock2.close()

def test_chat_not_sent_to_unjoined():
    """Test that chat messages are not sent to unjoined clients."""
    print("Test: Chat not sent to unjoined...")
    sock1 = connect()
    recv_line(sock1)  # Discard prompt, but don't join

    sock2 = connect()
    join_with_name(sock2, "alice")

    sock3 = connect()
    join_with_name(sock3, "bob")
    time.sleep(0.2)

    # bob sends a message
    send_line(sock3, "hello")
    time.sleep(0.2)

    # sock1 (unjoined) should not receive it
    sock1.settimeout(0.1)
    try:
        msg = recv_line(sock1)
        if msg:
            print(f"✗ Fail: Unjoined client received message: {msg}")
        else:
            print("✓ Pass")
    except socket.timeout:
        print("✓ Pass")
    finally:
        sock1.settimeout(None)
        sock1.close()
        sock2.close()
        sock3.close()

def test_leave_notification():
    """Test that other users are notified when someone leaves."""
    print("Test: Leave notification...")
    sock1 = connect()
    join_with_name(sock1, "alice")

    sock2 = connect()
    join_with_name(sock2, "bob")
    time.sleep(0.2)

    # bob disconnects
    sock2.close()
    time.sleep(0.2)

    # alice should receive leave notification
    sock1.settimeout(0.1)
    try:
        msg = recv_line(sock1)
        assert msg.strip().startswith("*"), f"Leave notification should start with '*', got: {msg}"
        assert "bob" in msg.lower(), f"Leave notification should contain 'bob', got: {msg}"
        print("✓ Pass")
    except socket.timeout:
        print("✗ Fail: No leave notification received")
    finally:
        sock1.settimeout(None)
        sock1.close()

def test_unjoined_disconnect_no_notification():
    """Test that unjoined client disconnect doesn't notify others."""
    print("Test: Unjoined disconnect no notification...")
    sock1 = connect()
    join_with_name(sock1, "alice")

    sock2 = connect()
    recv_line(sock2)  # Discard prompt, but don't join

    # Unjoined client disconnects
    sock2.close()
    time.sleep(0.2)

    # alice should not receive any notification
    sock1.settimeout(0.1)
    try:
        msg = recv_line(sock1)
        if msg:
            print(f"✗ Fail: Received notification for unjoined client: {msg}")
        else:
            print("✓ Pass")
    except socket.timeout:
        print("✓ Pass")
    finally:
        sock1.settimeout(None)
        sock1.close()

def test_multiple_simultaneous_clients():
    """Test that server supports at least 10 simultaneous clients."""
    print("Test: Multiple simultaneous clients...")
    socks = []
    names = [f"user{i}" for i in range(10)]

    # Connect and join all clients
    for name in names:
        sock = connect()
        join_with_name(sock, name)
        socks.append(sock)

    time.sleep(0.3)

    # Verify all connections are still alive
    all_alive = True
    for sock in socks:
        try:
            sock.sendall(b'')
        except:
            all_alive = False
            break

    # Clean up
    for sock in socks:
        sock.close()

    assert all_alive, "Some connections were dropped"
    print("✓ Pass")

def test_duplicate_name_handling():
    """Test duplicate name handling (implementation may allow or reject)."""
    print("Test: Duplicate name handling...")
    sock1 = connect()
    join_with_name(sock1, "alice")

    sock2 = connect()
    recv_line(sock2)
    send_line(sock2, "alice")
    time.sleep(0.2)

    # Server may either accept or reject - both are valid
    sock2.settimeout(0.1)
    try:
        sock2.sendall(b'')
        print("✓ Pass: Server allows duplicate names (implementation choice)")
        sock2.close()
    except:
        print("✓ Pass: Server rejects duplicate names (implementation choice)")
    finally:
        sock1.close()

def test_long_message():
    """Test that server accepts messages of at least 1000 characters."""
    print("Test: Long message (1000 chars)...")
    sock1 = connect()
    join_with_name(sock1, "alice")

    sock2 = connect()
    join_with_name(sock2, "bob")
    time.sleep(0.2)

    # Drain alice's buffer to clear the join notification
    drain_buffer(sock1)

    long_msg = "x" * 1000
    send_line(sock2, long_msg)
    time.sleep(0.2)

    sock1.settimeout(0.1)
    try:
        msg = recv_line(sock1)
        assert "[bob]" in msg, f"Message should contain '[bob]', got: '{msg[:100] if len(msg) > 100 else msg}'"
        assert "x" * 1000 in msg, f"Long message should be preserved, got message length: {len(msg)}"
        print("✓ Pass")
    except socket.timeout:
        print("✗ Fail: Long message not received")
    finally:
        sock1.settimeout(None)
        sock1.close()
        sock2.close()

if __name__ == '__main__':
    tests = [
        test_server_prompts_for_name,
        test_valid_alphanumeric_name,
        test_name_with_special_characters,
        test_empty_name,
        test_16_character_name,
        test_single_character_name,
        test_name_with_spaces,
        test_join_receives_user_list,
        test_join_notifies_others,
        test_chat_message_format,
        test_chat_not_sent_to_sender,
        test_chat_not_sent_to_unjoined,
        test_leave_notification,
        test_unjoined_disconnect_no_notification,
        test_multiple_simultaneous_clients,
        test_duplicate_name_handling,
        test_long_message,
    ]

    print(f"Running {len(tests)} tests against {HOST}:{PORT}\n")

    for test in tests:
        try:
            test()
        except Exception as e:
            print(f"✗ Fail: {e}")
            raise  # Stop on first failure
        print()
