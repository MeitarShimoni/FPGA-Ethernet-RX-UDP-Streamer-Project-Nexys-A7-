import socket, time

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)

i = 0
while True:
    print(f"sending hello fpga {i}")
    s.sendto(f"hello fpga {i}".encode(), ("192.168.1.255", 5000))
    i += 1
    time.sleep(0.005)