#!/bin/bash
# Instala no SD (montado ou detectado) o kernel/dtb mais recente e o DTB final.
# Uso: sudo ./scripts/install-kernel-to-sd.sh [/dev/mmcblk0p1]
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${ARMBIAN_BUILD_DIR:-$ROOT/../armbian-build}"
MNT="${SD_MNT:-/mnt/h20sd}"
DTB="$ROOT/dtb/sun50i-h313-x96q-lpddr3-final.dtb"

if [ "$(id -u)" -ne 0 ]; then
    echo "rode como root (sudo $0)" >&2
    exit 1
fi

find_part() {
    local d name size t
    for d in /sys/block/mmcblk* /sys/block/sd*; do
        [ -e "$d" ] || continue
        name=$(basename "$d")
        size=$(blockdev --getsize64 "/dev/$name" 2>/dev/null) || continue
        [ "$size" -ge 30000000000 ] && [ "$size" -le 90000000000 ] || continue
        for p in "/dev/${name}p1" "/dev/${name}1"; do
            [ -b "$p" ] || continue
            t=$(blkid -o value -s TYPE "$p" 2>/dev/null || true)
            [ "$t" = ext4 ] && { echo "$p"; return 0; }
        done
    done
    return 1
}

PART="${1:-}"
if [ -z "$PART" ]; then
    PART=$(find_part) || { echo "SD nao encontrado; passe o dispositivo (ex: /dev/mmcblk0p1)" >&2; exit 1; }
fi
echo "SD: $PART"

mkdir -p "$MNT"
mountpoint -q "$MNT" && umount "$MNT"
mount "$PART" "$MNT"
trap 'sync; for d in dev proc sys; do mountpoint -q "$MNT/$d" && umount "$MNT/$d" || true; done; umount "$MNT" || true' EXIT

grep -q h20pro "$MNT/etc/hostname" || { echo "rootfs nao e o h20pro" >&2; exit 1; }

DEBS="$BUILD/output/debs"
[ -e "$DEBS"/linux-image-*.deb ] || DEBS="$ROOT/artifacts"
mkdir -p "$MNT/tmp/debs"
cp -f "$DEBS"/linux-image-*.deb "$DEBS"/linux-dtb-*.deb "$MNT/tmp/debs/"
ls -lh "$MNT/tmp/debs"

# binfmt estatico: garante execucao aarch64 dentro do chroot
if [ ! -x "$MNT/usr/bin/qemu-aarch64-static" ] && [ -x /usr/bin/qemu-aarch64-static ]; then
    cp -f /usr/bin/qemu-aarch64-static "$MNT/usr/bin/"
fi

for d in dev proc sys; do
    mountpoint -q "$MNT/$d" || mount --bind "/$d" "$MNT/$d"
done

chroot "$MNT" /bin/bash -c '
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive
dpkg -i /tmp/debs/*.deb && rm -f /tmp/debs/*.deb
'

VER=$(basename "$(ls "$MNT"/boot/vmlinuz-6.18.* | head -1)" | sed 's/^vmlinuz-//')
TD="$MNT/boot/dtb-$VER/allwinner/sun50i-h313-x96q-lpddr3.dtb"
[ -f "$TD" ] && cp -f "$TD" "$TD.bak"
[ -d "$(dirname "$TD")" ] || { echo "DTB de destino nao existe: $TD" >&2; exit 1; }
cp -f "$DTB" "$TD"
md5sum "$TD" "$DTB"
sync
echo "OK: kernel $VER + DTB instalados"
