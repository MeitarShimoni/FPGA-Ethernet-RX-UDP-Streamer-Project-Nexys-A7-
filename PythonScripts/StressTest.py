import socket
import time

FPGA_IP = "192.168.1.2"
FPGA_PORT = 5000

# Create socket
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(3.0) # Increased timeout for larger packets

def test_burst():
    print("\n--- [TEST 1] Starting Burst Test (50 packets) ---")
    for i in range(50):
        sock.sendto(f"burst {i}".encode(), (FPGA_IP, FPGA_PORT))
    print("Burst sent. Check logic/Wireshark: the FPGA should drop packets while BUSY.")

def test_max_mtu():
    print("\n--- [TEST 2] Starting MTU Stress Test (1400 bytes) ---")
    # Wait for the burst test to finish
    time.sleep(2) 
    
    msg = "A" * 1400 
    print("Sending 1400 bytes...")
    sock.sendto(msg.encode(), (FPGA_IP, FPGA_PORT))
    
    try:
        data, _ = sock.recvfrom(2048)
        print(f"Received back {len(data)} bytes.")
        if len(data) == 1400:
            print("SUCCESS: Full MTU packet echoed perfectly!")
        else:
            print(f"FAILURE: Expected 1400 bytes, got {len(data)}.")
            print(f"Raw data head: {data[:20]}")
    except socket.timeout:
        print("TIMEOUT: The FPGA did not respond. Check if it's stuck in a state.")

def test_multi_client():
    print("\n--- [TEST 3] Starting Multi-Client Test ---")
    time.sleep(1)
    
    s1 = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s2 = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    
    print("Sending from Client 1 (Port 5001)...")
    s1.sendto("client1".encode(), (FPGA_IP, FPGA_PORT))
    
    print("Sending from Client 2 (Port 5002)...")
    s2.sendto("client2".encode(), (FPGA_IP, FPGA_PORT))
    
    # We expect two responses
    for i in range(2):
        try:
            data, addr = sock.recvfrom(1024)
            print(f"Received '{data.decode()}' from {addr}")
        except socket.timeout:
            print("One of the clients timed out.")


def test_single_mtu():
    print("\n--- Starting SINGLE MTU Test (1400 bytes) ---")
    # Send one large packet
    msg = "A" * 1400 
    sock.sendto(msg.encode(), (FPGA_IP, FPGA_PORT))
    
    try:
        data, _ = sock.recvfrom(2048)
        print(f"Received {len(data)} bytes.")
        # Check if we got the 'A's back
        if data[0:5] == b'AAAAA':
            print("SUCCESS: Data integrity verified!")
    except socket.timeout:
        print("TIMEOUT: FPGA unresponsive.")

if __name__ == "__main__":
    # test_burst()
    test_single_mtu()
    # time.sleep(2)
    # test_max_mtu()
    # time.sleep(2)
    # test_multi_client()
    # time.sleep(2)
    # print("\n--- All tests completed ---")