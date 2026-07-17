import socket
import select
import time

FPGA_IP = "192.168.1.2"
FPGA_PORT = 5000

def test_bandwidth():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    # Send large packets to maximize payload utilization
    payload = b"A" * 1400 
    
    duration = 5  # seconds
    bytes_sent = 0
    
    print(f"--- Starting Bandwidth Test ({duration} seconds) ---")
    start_time = time.time()
    
    while time.time() - start_time < duration:
        sock.sendto(payload, (FPGA_IP, FPGA_PORT))
        bytes_sent += len(payload)
        # We don't sleep here to push the FPGA to its limit
    
    end_time = time.time()
    total_time = end_time - start_time
    
    # Calculate Mbps: (total_bytes * 8 bits) / 1,000,000 / seconds
    mbps = (bytes_sent * 8) / (1_000_000 * total_time)
    
    print(f"Total data sent: {bytes_sent / 1_000_000:.2f} MB")
    print(f"Measured Throughput: {mbps:.2f} Mbps")

def test_live_burst():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setblocking(False) # Non-blocking mode
    sock.bind(("", 0))   # Bind to a local port to receive replies

    print(f"--- Starting Live Burst Test ---")
    
    # 1. Fire off the burst
    for i in range(50):
        msg = f"burst {i}".encode()
        sock.sendto(msg, (FPGA_IP, FPGA_PORT))
    
    print("All 50 packets sent. Monitoring for replies...")

    # 2. Live Monitoring Loop
    start_time = time.time()
    received_count = 0
    
    # Listen for 5 seconds for replies
    while time.time() - start_time < 5:
        # Use select to wait for data without freezing the script
        ready = select.select([sock], [], [], 0.1)
        if ready[0]:
            data, addr = sock.recvfrom(2048)
            received_count += 1
            print(f"[{received_count}] Received {len(data)} bytes: {data.decode()}")
            
    print(f"\nTest finished. Total replies captured: {received_count}/50")

if __name__ == "__main__":
    # test_live_burst()
    # time.sleep(0.2)
    
    test_bandwidth()
    test_bandwidth()
    test_bandwidth()
    test_bandwidth()
    test_bandwidth()