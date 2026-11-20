#!/usr/bin/env python3
import os, sys, termios, tty, time, select

DEV = "/dev/ttyUSB0"
BAUD = termios.B115200


def open_port():
    fd = os.open(DEV, os.O_RDWR | os.O_NOCTTY)
    tty.setraw(fd)
    a = termios.tcgetattr(fd)
    a[2] |= termios.CLOCAL | termios.CREAD
    a[4] = a[5] = BAUD
    a[6][termios.VMIN] = 1
    a[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, a)
    os.set_blocking(fd, False)
    return fd


def drain(fd, secs=0.15):
    end = time.time() + secs
    out = b""
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], max(0, end - time.time()))
        if not r:
            break
        try:
            d = os.read(fd, 8192)
        except OSError:
            break
        if not d:
            break
        out += d
        end = time.time() + 0.05
    return out


def sendline(fd, line, wait=0.06):
    os.write(fd, line.encode() + b"\r")
    time.sleep(wait)
    drain(fd, 0.01)


def main():
    data = open(sys.argv[1]).read()
    chunk = int(sys.argv[2]) if len(sys.argv) > 2 else 180
    fd = open_port()
    drain(fd, 0.3)
    sendline(fd, "rm -f /tmp/f.b64", 0.2)
    sendline(fd, "cat > /tmp/f.b64 <<'XEOF'", 0.2)
    n = 0
    for i in range(0, len(data), chunk):
        sendline(fd, data[i : i + chunk])
        n += 1
    sendline(fd, "XEOF", 0.5)
    print(f"enviados {n} blocos, {len(data)} bytes", file=sys.stderr)
    os.write(fd, b"wc -c /tmp/f.b64; md5sum /tmp/f.b64\r")
    time.sleep(1.0)
    print(drain(fd, 5).decode("latin-1"))
    os.close(fd)


main()
