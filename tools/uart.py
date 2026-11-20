#!/usr/bin/env python3
"""Console UART da caixa (H20 Pro): 115200 8N1, sem flow control.

O adaptador CP2102 reenumera e pode aparecer como /dev/ttyUSB0 ou
/dev/ttyUSB1.  Use $UART para escolher, ou deixe a ferramenta achar.

uso:
  tools/uart.py 'comando' [mais comandos...]   # envia cada um + CR
  tools/uart.py -t 5 'comando'                 # espera 5 s por resposta
  tools/uart.py -i                             # interativo (stdin <-> UART)

exemplos:
  tools/uart.py 'ls /' 'cat /dev/user'
  UART=/dev/ttyUSB1 tools/uart.py 'cat /dev/sdM0/ctl'
  tools/uart.py -i

Notas do console do 9front:
  - o prompt do root e' '% ';
  - ^D no inicio da linha e' EOF (encerra `cat > arquivo`);
  - quebrar linha no rc com aspas/`{` abertas prende o shell; ^D/^\\ ajuda.
"""

import os, select, sys, termios, time, tty

DEFAULT_BAUD = termios.B115200


def find_dev():
    d = os.environ.get("UART")
    if d:
        return d
    for p in ("/dev/ttyUSB0", "/dev/ttyUSB1", "/dev/ttyUSB2"):
        if os.path.exists(p):
            return p
    return "/dev/ttyUSB0"


def open_port(dev):
    fd = os.open(dev, os.O_RDWR | os.O_NOCTTY)
    tty.setraw(fd)
    attrs = termios.tcgetattr(fd)
    attrs[2] |= termios.CLOCAL | termios.CREAD
    attrs[4] = attrs[5] = DEFAULT_BAUD
    attrs[6][termios.VMIN] = 1
    attrs[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    os.set_blocking(fd, False)
    return fd


def read_for(fd, secs):
    out = b""
    end = time.time() + secs
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], max(0, end - time.time()))
        if not r:
            break
        try:
            d = os.read(fd, 4096)
        except OSError:
            break
        if not d:
            break
        out += d
        end = time.time() + 0.05  # drena o que chegar em rajada
    return out


def interactive(fd):
    print("# interativo; Ctrl-] sai", file=sys.stderr)
    while True:
        r, _, _ = select.select([fd, sys.stdin], [], [], 0.5)
        if fd in r:
            d = os.read(fd, 4096)
            if d:
                sys.stdout.buffer.write(d)
                sys.stdout.buffer.flush()
        if sys.stdin in r:
            d = os.read(sys.stdin.fileno(), 4096)
            if not d:
                break
            if b"\x1d" in d:  # Ctrl-]
                break
            os.write(fd, d)


def main():
    args = sys.argv[1:]
    t = 1.5
    if args and args[0] == "-t":
        t = float(args[1])
        args = args[2:]
    dev = find_dev()
    fd = open_port(dev)
    if args and args[0] in ("-i", "--interactive"):
        interactive(fd)
        os.close(fd)
        return
    read_for(fd, 0.2)
    for cmd in args:
        os.write(fd, cmd.encode() + b"\r")
        d = read_for(fd, t)
        sys.stdout.write(d.decode("latin-1"))
        sys.stdout.flush()
    os.close(fd)


main()
