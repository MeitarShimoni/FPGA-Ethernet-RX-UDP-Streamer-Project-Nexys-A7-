import socket
import time

# FPGA Configuration (Must match your SystemVerilog parameters)
FPGA_IP = "192.168.1.2"
FPGA_PORT = 5000

# Create a UDP socket
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

# Set a timeout so the script doesn't hang forever if a packet is lost
sock.settimeout(2.0)

print(f"Starting UDP Echo Test to {FPGA_IP}:{FPGA_PORT}...")
print("Press Ctrl+C to stop.\n")

i = 0
while True:
    message = f"hello fpga {i}"
    
    # 1. Send the data to the FPGA
    print(f"[TX] Sending : '{message}'")
    sock.sendto(message.encode('utf-8'), (FPGA_IP, FPGA_PORT))
    
    # 2. Wait for the echo response
    try:
        # Buffer size is 1024 bytes
        data, addr = sock.recvfrom(1024)
        print(f"[RX] Received: '{data.decode('utf-8')}' from {addr}")
        
        # Verify the payload matches
        if data.decode('utf-8') == message:
            print(" -> Status: PASS (Echo matched perfectly)\n")
        else:
            print(" -> Status: FAIL (Data mismatch)\n")
            
    except socket.timeout:
        print(" -> Status: TIMEOUT (No response from FPGA)\n")
    except Exception as e:
        print(f" -> Status: ERROR ({e})\n")
        
    i += 1
    time.sleep(1) # Wait 1 second before the next ping