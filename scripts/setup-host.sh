#!/bin/bash
# Prepara uma maquina Linux (Arch/CachyOS ou Debian/Ubuntu) para compilar o
# kernel e instalar no SD via chroot aarch64.
set -Eeuo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "rode como root (sudo $0)" >&2
    exit 1
fi

if command -v pacman >/dev/null 2>&1; then
    pacman -S --needed --noconfirm docker qemu-user-static qemu-user-binfmt \
        dtc gzip coreutils git
elif command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        docker.io qemu-user-static device-tree-compiler gzip git
else
    echo "gerenciador de pacotes nao suportado" >&2
    exit 1
fi

# binfmt para aarch64 usando o qemu ESTATICO (necessario dentro do chroot).
MAGIC='\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00'
MASK='\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff'
if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || \
   ! grep -q qemu-aarch64-static /proc/sys/fs/binfmt_misc/qemu-aarch64 2>/dev/null; then
    echo -1 > /proc/sys/fs/binfmt_misc/qemu-aarch64 2>/dev/null || true
    printf ':qemu-aarch64:M::%s:%s:/usr/bin/qemu-aarch64-static:FP' \
        "$MAGIC" "$MASK" > /proc/sys/fs/binfmt_misc/register
fi

echo "OK: host pronto"
echo "  docker: $(docker --version 2>/dev/null || echo ausente)"
echo "  qemu  : $(command -v qemu-aarch64-static)"
