#!/bin/bash
# ---------------------------------------------------------------------------
# expand-rootfs.sh
#
# Expande a ultima particao e o filesystem root para ocupar todo o disco.
#
# Uso:
#   expand-rootfs.sh                 # sistema em execucao (root montado)
#   expand-rootfs.sh /dev/mmcblk2p1  # modo offline (particao desmontada)
#
# O modo offline e util quando se inicializa pelo SD para arrumar o eMMC.
# ---------------------------------------------------------------------------
set -Eeuo pipefail

log() { printf '[expand-rootfs] %s\n' "$*"; }
die() { log "ERRO: $*"; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "execute como root."

TARGET=${1:-}
OFFLINE=0

if [[ -n "$TARGET" ]]; then
	OFFLINE=1
	[[ -b "$TARGET" ]] || die "nao e um dispositivo de bloco: $TARGET"
	PART="$TARGET"
else
	ROOT_SRC=$(findmnt -n -o SOURCE /)
	PART="$ROOT_SRC"
fi

[[ -b "$PART" ]] || die "particao nao encontrada: $PART"

DISK_NAME=$(lsblk -n -o PKNAME "$PART" | head -n1)
[[ -n "$DISK_NAME" ]] || die "nao foi possivel descobrir o disco de $PART."
DISK="/dev/$DISK_NAME"
PART_NUM=$(cat "/sys/class/block/$(basename "$PART")/partition" 2>/dev/null || true)
[[ -n "$PART_NUM" ]] || die "nao foi possivel descobrir o numero da particao."

LAST_PART=$(lsblk -ln -o NAME "$DISK" | tail -n +2 | grep -E "^${DISK##*/}p[0-9]+$" | tail -n1)
[[ "$LAST_PART" == "$(basename "$PART")" ]] ||
	die "$PART nao e a ultima particao de $DISK; nao vou mexer."

BEFORE=$(blockdev --getsize64 "$PART")
DISK_SIZE=$(blockdev --getsize64 "$DISK")
FREE=$((DISK_SIZE - BEFORE))
log "Disco: $DISK ($((DISK_SIZE / 1024 / 1024)) MiB)"
log "Particao $PART: $((BEFORE / 1024 / 1024)) MiB; livre depois dela: $((FREE / 1024 / 1024)) MiB"

if ((FREE < 16 * 1024 * 1024)); then
	log "Nao ha espaco relevante para expandir. Nada a fazer."
	df -h / 2>/dev/null || true
	exit 0
fi

if ((OFFLINE)); then
	mountpoint -q "$PART" && die "$PART esta montada; desmonte antes."
	log "Expandindo a particao (offline)..."
	printf 'size=+\n' | sfdisk --force --no-reread -N "$PART_NUM" "$DISK"
	partx -u "$DISK" 2>/dev/null || true
	partprobe "$DISK" 2>/dev/null || true
	udevadm settle 2>/dev/null || true

	AFTER=$(blockdev --getsize64 "$PART")
	((AFTER > BEFORE)) || die "a particao nao cresceu."
	log "Verificando o filesystem..."
	E2RC=0
	e2fsck -f -y "$PART" || E2RC=$?
	((E2RC <= 1)) || die "e2fsck falhou (rc=$E2RC)."
	resize2fs "$PART"
else
	log "Expandindo a particao (online)..."
	printf 'size=+\n' | sfdisk --force --no-reread -N "$PART_NUM" "$DISK"
	partx -u "$DISK" 2>/dev/null || partprobe "$DISK" 2>/dev/null || true
	udevadm settle 2>/dev/null || true

	AFTER=$(blockdev --getsize64 "$PART")
	if ((AFTER <= BEFORE)); then
		die "o kernel nao atualizou o tamanho da particao. Reinicie e rode novamente, ou use o modo offline a partir do SD."
	fi
	log "Redimensionando o filesystem online..."
	resize2fs "$PART"
fi

df -h / 2>/dev/null || true
log "Concluido."
