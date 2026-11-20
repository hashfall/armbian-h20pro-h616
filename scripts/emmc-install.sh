#!/bin/bash
# ---------------------------------------------------------------------------
# emmc-install.sh
#
# Executado automaticamente no primeiro boot do cartao SD.
#   1. apaga completamente o eMMC (tabela de particoes + dados);
#   2. grava a imagem Armbian que esta em /root/armbian-install.img;
#   3. expande a particao e o filesystem para ocupar todo o eMMC;
#   4. troca o UUID do rootfs do eMMC (para nao colidir com o SD);
#   5. remove este instalador da copia do eMMC;
#   6. grava os logs no proprio SD e desliga a caixa.
#
# O conteudo do cartao SD nao e apagado: o script apenas grava logs e
# marcadores nele. O cartao SD NAO e formatado.
# Ele so roda quando o sistema foi iniciado pelo SD e existe o marcador
# /boot/emmc-install/enabled.
# ---------------------------------------------------------------------------
set -Eeuo pipefail

MARKER_DIR=/boot/emmc-install
ENABLED="$MARKER_DIR/enabled"
DONE="$MARKER_DIR/done"
FAILED="$MARKER_DIR/failed"
LOG_DIR="$MARKER_DIR/logs"
PAYLOAD_LABEL=payload
PAYLOAD_MNT=/mnt/emmc-payload
IMAGE="$PAYLOAD_MNT/armbian-install.img"
IMAGE_SHA256="$PAYLOAD_MNT/armbian-install.img.sha256"
MOUNT_DIR=/mnt/emmc-install
TARGET_PART=1

mkdir -p "$LOG_DIR"
RUN=1
while [[ -e "$LOG_DIR/install-$(printf '%03d' "$RUN").log" ]]; do
	RUN=$((RUN + 1))
done
LOG="$LOG_DIR/install-$(printf '%03d' "$RUN").log"
ln -sfn "$(basename "$LOG")" "$LOG_DIR/latest.log" 2>/dev/null || true
exec >>"$LOG" 2>&1

log() {
	local msg
	msg="[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $*"
	printf '%s\n' "$msg"
	printf '%s\n' "$msg" >/dev/console 2>/dev/null || true
}

die() {
	log "ERRO: $*"
	touch "$FAILED" 2>/dev/null || true
	sync
	exit 1
}

on_error() {
	local rc=$?
	set +e
	log "FALHOU (rc=$rc) em ${BASH_SOURCE[0]}:${BASH_LINENO[0]}: ${BASH_COMMAND}"
	touch "$FAILED" 2>/dev/null || true
	sync
	exit "$rc"
}
trap on_error ERR

log "=== Instalador Armbian -> eMMC (execucao $RUN) ==="
log "Log: $LOG"

# ---------------------------------------------------------------------------
# Condicoes de execucao
# ---------------------------------------------------------------------------
if [[ -e "$DONE" ]]; then
	log "Instalacao ja concluida ($DONE). Nada a fazer."
	exit 0
fi
if [[ -e "$FAILED" ]]; then
	log "Ja existe uma falha registrada ($FAILED)."
	log "Leia os logs e remova esse arquivo para tentar de novo."
	exit 0
fi
if [[ ! -e "$ENABLED" ]]; then
	log "Marcador $ENABLED ausente; instalador ignorado."
	exit 0
fi

ROOT_SRC=$(findmnt -n -o SOURCE /)
ROOT_DISK_NAME=$(lsblk -n -o PKNAME "$ROOT_SRC" | head -n1)
ROOT_DISK="/dev/$ROOT_DISK_NAME"
ROOT_TYPE=$(cat "/sys/class/block/$ROOT_DISK_NAME/device/type" 2>/dev/null || true)

log "Sistema rodando de: $ROOT_SRC ($ROOT_DISK, tipo=${ROOT_TYPE:-desconhecido})"
if [[ "$ROOT_TYPE" != "SD" ]]; then
	log "Nao estou rodando de um cartao SD. Abortando por seguranca."
	exit 0
fi

# ---------------------------------------------------------------------------
# Localiza o eMMC (nunca o disco que esta servindo de root)
# ---------------------------------------------------------------------------
EMMC=""
if [[ -f "$MARKER_DIR/emmc-dev" ]]; then
	EMMC=$(tr -d '[:space:]' <"$MARKER_DIR/emmc-dev")
	log "eMMC forcado por $MARKER_DIR/emmc-dev: $EMMC"
	[[ -b "$EMMC" ]] || die "Dispositivo indicado em emmc-dev nao existe: $EMMC"
else
	BEST_SIZE=0
	for SYSBLK in /sys/block/mmcblk*; do
		NAME=${SYSBLK##*/}
		[[ "$NAME" == "$ROOT_DISK_NAME" ]] && continue
		[[ "$NAME" =~ boot[0-9]$ || "$NAME" =~ rpmb$ ]] && continue
		[[ -r "$SYSBLK/device/type" ]] || continue
		TYPE=$(cat "$SYSBLK/device/type")
		[[ "$TYPE" == "MMC" ]] || continue
		REMOVABLE=$(cat "$SYSBLK/removable" 2>/dev/null || echo 0)
		[[ "$REMOVABLE" == "0" ]] || continue
		SIZE=$(blockdev --getsize64 "/dev/$NAME" 2>/dev/null || echo 0)
		log "Candidato a eMMC: /dev/$NAME (tipo=$TYPE, ${SIZE} bytes)"
		if ((SIZE > BEST_SIZE)); then
			BEST_SIZE=$SIZE
			EMMC="/dev/$NAME"
		fi
	done
fi

[[ -n "$EMMC" ]] || die "Nenhum eMMC encontrado."
[[ "$EMMC" != "$ROOT_DISK" ]] || die "O eMMC detectado e o proprio disco raiz. Abortando."
[[ -b "$EMMC" ]] || die "eMMC nao e um dispositivo de bloco: $EMMC"

list_partitions() {
	lsblk -ln -o NAME "$1" | tail -n +2 | grep -E "^${1##*/}p[0-9]+$" || true
}

mount_payload() {
	mkdir -p "$PAYLOAD_MNT"
	if mountpoint -q "$PAYLOAD_MNT"; then
		return 0
	fi
	mount -o ro "LABEL=$PAYLOAD_LABEL" "$PAYLOAD_MNT" ||
		die "Particao '$PAYLOAD_LABEL' com a imagem nao encontrada no SD."
}
mount_payload

IMG_SIZE=$(stat -c %s "$IMAGE")
EMMC_SIZE=$(blockdev --getsize64 "$EMMC")
log "eMMC: $EMMC ($((EMMC_SIZE / 1024 / 1024)) MiB)"
log "Imagem: $IMAGE ($((IMG_SIZE / 1024 / 1024)) MiB)"

((EMMC_SIZE > IMG_SIZE + 512 * 1024 * 1024)) ||
	die "eMMC pequeno demais para a imagem (precisa de pelo menos 512 MiB livres)."

# ---------------------------------------------------------------------------
# Valida a imagem antes de destruir qualquer coisa
# ---------------------------------------------------------------------------
[[ -f "$IMAGE" ]] || die "Imagem nao encontrada: $IMAGE"
[[ -f "$IMAGE_SHA256" ]] || die "Checksum nao encontrado: $IMAGE_SHA256"

EXPECTED_SHA=$(awk '{print $1}' "$IMAGE_SHA256")
ACTUAL_SHA=$(sha256sum "$IMAGE" | awk '{print $1}')
[[ "$EXPECTED_SHA" == "$ACTUAL_SHA" ]] ||
	die "Checksum da imagem no SD nao confere (arquivo corrompido)."
log "Checksum da imagem OK: $ACTUAL_SHA"

# ---------------------------------------------------------------------------
# Desmonta qualquer coisa que esteja usando o eMMC
# ---------------------------------------------------------------------------
while read -r PART_NAME; do
	[[ -n "$PART_NAME" ]] || continue
	umount -f "/dev/$PART_NAME" 2>/dev/null || true
done < <(list_partitions "$EMMC")
swapoff -a 2>/dev/null || true
sync

# ---------------------------------------------------------------------------
# Limpa o eMMC: tabela de particoes + dados (nao deixa Android para tras)
# ---------------------------------------------------------------------------
log "Apagando tabela de particoes e dados do eMMC..."
wipefs -a -f "$EMMC" 2>/dev/null || log "wipefs retornou erro (seguindo)."
blkdiscard -f "$EMMC" 2>/dev/null || log "blkdiscard nao suportado (seguindo)."

# Garante que MBR/GPT do Android sumiram (inicio e fim do dispositivo).
dd if=/dev/zero of="$EMMC" bs=1M count=32 conv=fsync status=none
TAIL_SEEK=$((EMMC_SIZE / 1024 / 1024 - 32))
if ((TAIL_SEEK > 0)); then
	dd if=/dev/zero of="$EMMC" bs=1M count=32 seek="$TAIL_SEEK" conv=fsync status=none
fi
sync
partprobe "$EMMC" 2>/dev/null || true
udevadm settle 2>/dev/null || true
log "eMMC limpo."

# ---------------------------------------------------------------------------
# Grava a imagem Armbian (inclui U-Boot, kernel, DTB e rootfs)
# ---------------------------------------------------------------------------
log "Gravando a imagem no eMMC. Isso pode levar alguns minutos..."
dd if="$IMAGE" of="$EMMC" bs=8M conv=fsync status=progress
sync
blockdev --flushbufs "$EMMC" 2>/dev/null || true
partprobe "$EMMC" 2>/dev/null || true
udevadm settle 2>/dev/null || true

log "Conferindo a gravacao (SHA256 do eMMC)..."
EMMC_SHA=$(head -c "$IMG_SIZE" "$EMMC" | sha256sum | awk '{print $1}')
[[ "$EMMC_SHA" == "$ACTUAL_SHA" ]] ||
	die "SHA256 do eMMC nao confere. A gravacao falhou."
log "Gravacao conferida com sucesso."

# ---------------------------------------------------------------------------
# Expande a particao e o filesystem para todo o eMMC
# ---------------------------------------------------------------------------
for _ in {1..10}; do
	mapfile -t PARTS < <(list_partitions "$EMMC")
	[[ ${#PARTS[@]} -eq 1 ]] && break
	partx -u "$EMMC" 2>/dev/null || true
	partprobe "$EMMC" 2>/dev/null || true
	udevadm settle 2>/dev/null || true
	sleep 1
done
[[ ${#PARTS[@]} -eq 1 ]] ||
	die "Esperava exatamente 1 particao na imagem, encontrei ${#PARTS[@]}."
PART="/dev/${PARTS[0]}"
log "Particao da imagem: $PART"

OLD_PART_SIZE=$(blockdev --getsize64 "$PART")
log "Expandindo a particao $TARGET_PART ate o fim do eMMC..."
parted -s -f "$EMMC" resizepart "$TARGET_PART" 100%
partx -u "$EMMC" 2>/dev/null || true
partprobe "$EMMC" 2>/dev/null || true
udevadm settle 2>/dev/null || true

for _ in {1..10}; do
	CUR_SIZE=$(blockdev --getsize64 "$PART" 2>/dev/null || echo 0)
	((CUR_SIZE > OLD_PART_SIZE)) && break
	partx -u "$EMMC" 2>/dev/null || true
	partprobe "$EMMC" 2>/dev/null || true
	udevadm settle 2>/dev/null || true
	sleep 1
done
CUR_SIZE=$(blockdev --getsize64 "$PART" 2>/dev/null || echo 0)
((CUR_SIZE > OLD_PART_SIZE)) ||
	die "O kernel nao atualizou o tamanho da particao $PART."
log "Particao: $OLD_PART_SIZE -> $CUR_SIZE bytes"

log "Verificando e expandindo o filesystem..."
E2RC=0
e2fsck -f -y "$PART" || E2RC=$?
((E2RC <= 1)) || die "e2fsck falhou (rc=$E2RC)."
resize2fs "$PART"
log "Filesystem expandido."

# ---------------------------------------------------------------------------
# Novo UUID para o rootfs do eMMC (o SD continua com o UUID original)
# ---------------------------------------------------------------------------
OLD_UUID=$(blkid -p -s UUID -o value "$PART")
[[ -n "$OLD_UUID" ]] || die "Nao foi possivel ler o UUID do eMMC."
tune2fs -U random "$PART" >/dev/null 2>&1
udevadm settle 2>/dev/null || true
NEW_UUID=$(blkid -p -s UUID -o value "$PART")
[[ -n "$NEW_UUID" && "$NEW_UUID" != "$OLD_UUID" ]] ||
	die "Falha ao gerar o novo UUID do eMMC."
log "UUID do rootfs do eMMC: $OLD_UUID -> $NEW_UUID"

mkdir -p "$MOUNT_DIR"
mount "$PART" "$MOUNT_DIR"
cleanup() {
	umount "$MOUNT_DIR" 2>/dev/null || true
	umount "$PAYLOAD_MNT" 2>/dev/null || true
}
trap cleanup EXIT

log "Atualizando rootdev/fstab do eMMC para o novo UUID..."
while IFS= read -r FILE; do
	[[ -n "$FILE" ]] || continue
	sed -i "s/$OLD_UUID/$NEW_UUID/g" "$FILE"
	log "  UUID atualizado em ${FILE#"$MOUNT_DIR"}"
done < <(grep -rIl --exclude-dir=lost+found -- "$OLD_UUID" \
	"$MOUNT_DIR/boot" "$MOUNT_DIR/etc" 2>/dev/null || true)

grep -q "$NEW_UUID" "$MOUNT_DIR/boot/armbianEnv.txt" ||
	die "armbianEnv.txt do eMMC nao aponta para o novo UUID."
grep -q "$NEW_UUID" "$MOUNT_DIR/etc/fstab" ||
	die "fstab do eMMC nao aponta para o novo UUID."

# ---------------------------------------------------------------------------
# Remove o instalador da copia do eMMC (para nao rodar de novo)
# ---------------------------------------------------------------------------
log "Removendo o instalador da copia do eMMC..."
rm -f "$MOUNT_DIR/etc/systemd/system/multi-user.target.wants/emmc-install.service"
rm -f "$MOUNT_DIR/etc/systemd/system/emmc-install.service"
rm -f "$MOUNT_DIR/usr/local/sbin/emmc-install.sh"
rm -rf "$MOUNT_DIR/boot/emmc-install"
rm -f "$MOUNT_DIR/root/.not_logged_in_yet"

grep -q '^glenda:' "$MOUNT_DIR/etc/passwd" ||
	die "Usuario glenda nao encontrado no eMMC."
[[ -x "$MOUNT_DIR/usr/local/sbin/expand-rootfs.sh" ]] ||
	die "Helper expand-rootfs.sh nao encontrado no eMMC."

sync
DF_LINE=$(df -h "$PART" 2>/dev/null | tail -n1 || true)
umount "$MOUNT_DIR"
trap - EXIT

# ---------------------------------------------------------------------------
# Resumo no SD + desliga
# ---------------------------------------------------------------------------
{
	echo "Instalacao concluida em $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
	echo "eMMC: $EMMC"
	echo "Particao: $PART"
	echo "Tamanho da particao: $CUR_SIZE bytes"
	echo "UUID do rootfs: $NEW_UUID"
	echo
	sfdisk -d "$EMMC" 2>&1 || true
	echo
	blkid "$PART" 2>&1 || true
	echo
	echo "$DF_LINE"
} >"$MARKER_DIR/RESULTADO.txt" 2>&1 || true

touch "$DONE"
sync
log "=== INSTALACAO CONCLUIDA COM SUCESSO ==="
log "O eMMC esta pronto. Desligando para voce remover o cartao SD."
trap - ERR
systemctl poweroff || true
exit 0
