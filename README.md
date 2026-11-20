# Armbian H20 Pro (Allwinner H616) — boot pelo cartão SD

Objetivo: **Armbian totalmente funcional a partir do cartão SD**, com HDMI,
Ethernet 100M, Wi-Fi/BT e USB. O **eMMC fica intocado**; este projeto não
instala mais o sistema no eMMC.

## Base usada

- Armbian Community X96Q (sun50iw9 / Allwinner H313, LPDDR3)
- Debian Trixie minimal, kernel 6.18.x `current-sunxi64`
- U-Boot do Armbian com LPDDR3

A imagem do **X96 Mate** (H616 + DDR3 1333) não treina a DRAM desta caixa:
o SPL para em `This DRAM setup is currently not supported.` e reinicia em
loop. Use a variante **X96Q LPDDR3**.

## Gravar e iniciar pelo SD

1. Grave a imagem em um cartão **genuíno** (Balena Etcher ou `dd`).
2. Antes de bootar, confira se o SD **não** tem
   `/boot/emmc-install/enabled`. Esse marcador pertence ao instalador antigo
   de eMMC; se existir, remova. O instalador legado apaga o eMMC.
3. Boote a caixa com o SD. Console UART: `ttyS0`, **115200 8N1**.
4. Login: usuário `glenda`, senha `glenda` (troque depois).
5. Expanda o rootfs do SD:

   ```bash
   sudo ./scripts/expand-rootfs.sh
   ```

   Se o helper já estiver instalado na imagem, também vale
   `sudo /usr/local/sbin/expand-rootfs.sh`.

6. Confirme que o sistema está no SD:

   ```bash
   findmnt -no SOURCE /
   # esperado: /dev/mmcblk0p1 (SD)
   # se aparecer /dev/mmcblk2p1, você está no eMMC: pare
   ```

## Estado do port

| Bloco | Situação |
|---|---|
| Boot pelo SD | funciona com a imagem X96Q LPDDR3 |
| HDMI | em ajuste; aplicar patches 0005/0006 (ver abaixo) |
| Ethernet 100M | driver AC300/EMAC1 já está no kernel 6.18; validar DTS |
| Wi-Fi/BT | driver UWE5622 disponível; falta firmware + nós DTS |
| eMMC | intocado por decisão de projeto |

## Kernel, DTB e HDMI

O build do kernel fica no diretório irmão `../armbian-build/`:

Todos os patches estão em `patches/` e são copiados para
`../armbian-build/userpatches/kernel/archive/sunxi-6.18/` por
`scripts/build-kernel.sh`. Ordem (léxica): **0003 → 0005 → 0006 → 0010 →
0011**.

- `0003` — pad-select do TCON (o kernel 6.18 já faz via quirk; inofensivo).
- `0005` — substitui as tabelas H616 pelas **97 entradas** extraídas do
  Android stock (PHY phy301).
- `0006` — seleciona a interface I2C da PHY (`JTAG_PHY_CONFIG = 0x10`), que o
  stock escreve antes de cada configuração; sem isso os writes podem ser
  descartados em silêncio.
- `0010` — diagnóstico: readback I2C e estado da PHY no power-on.
- `0011` — pulso real de reset na PHY antes de configurar.

`0006` só atua se o nó HDMI mantiver o compatible
`allwinner,sun50i-h616-dw-hdmi`.

Detalhes da engenharia reversa: `docs/hdmi-stock-re.md`.
Tabela extraída: `docs/h616_phy_tables.c` (referência gerada; o patch real é
o `0005`).

Para reproduzir em outro PC (host, build, instalação no SD, diagnóstico e
estado atual), siga **`docs/HANDOFF.md`**. Kernel pronto em `artifacts/` e DTB
final em `dtb/`.

## Ethernet e Wi-Fi

- **Ethernet:** `gmac1` em `0x05030000`, RMII, PHY interno **AC300**.
  O kernel 6.18 já tem `ac300-phy.c` e o variante H616 do `dwmac-sun8i`.
  Para o X96Q (mesmo AC300/EMAC1), a receita é PWM5 em 2 MHz no PA12,
  calibration do eFUSE, `mdio-mux` e nó AC300. Confirme pinos/calibração na
  H20 Pro antes de copiar o DTS.
- **Wi-Fi/BT:** **UWE5622 / AW859A** via SDIO (`sprd,marlin3`).
  Use o driver `uwe5622` da Armbian (ou `uwe5622-ng`) e os blobs do firmware
  stock (`wcnmodem.bin`, `wifi_2355b001_1ant.ini`). O DTS precisa do SDIO,
  `mmc-pwrseq` e do nó `uwe-bsp`.

Não use a imagem/DTB do T95: a RAM (DDR3 vs LPDDR3), o PMIC (AXP305 vs
AXP313a) e a pinagem são diferentes. Os drivers são reaproveitáveis; o DTB
não é.

## Verificação

```bash
findmnt -no SOURCE /
dmesg | grep -Ei 'hdmi|phy|dwmac|ac300|uwe|sprd'
cat /sys/class/drm/card*-HDMI-A-1/status
ip link
iw dev
```

Para testar HDMI sem EDID, force no cmdline:

```text
video=HDMI-A-1:1024x768@60
```

## eMMC (legado, não usar)

Os arquivos `scripts/emmc-install.sh` e `scripts/emmc-install.service`
continuam no repositório apenas como legado de recuperação. Eles **apagam o
eMMC inteiro** e agora só rodam com o marcador explícito
`/boot/emmc-install/allow-emmc-install`; não crie esse marcador no fluxo
normal. Em um SD antigo, remova `/boot/emmc-install/enabled` antes de bootar.

## Arquivos deste repositório

- `docs/HANDOFF.md` — **comece por aqui para continuar em outro PC**.
- `docs/hdmi-stock-re.md` — engenharia reversa do HDMI stock.
- `docs/h616_phy_tables.c` — tabela de referência extraída do stock.
- `patches/` — patches de kernel (0003, 0005, 0006, 0010, 0011).
- `dtb/` — DTS/DTB final da X96Q LPDDR3.
- `artifacts/` — `.deb` do kernel/DTB prontos (não versionados no git).
- `scripts/setup-host.sh` — Docker + qemu/binfmt + dtc.
- `scripts/build-kernel.sh` — clona/atualiza `armbian-build` e compila.
- `scripts/install-kernel-to-sd.sh` — instala kernel+DTB no SD pelo PC.
- `tools/uart.py` / `tools/send_dtb.py` — UART e envio alternativo de DTB.
- `scripts/expand-rootfs.sh` — expansão do rootfs (SD ou eMMC desmontado).
- `scripts/emmc-install.sh` / `scripts/emmc-install.service` — legado; não usar.
- `scripts/LEIA-ME-SD.txt` — resumo para o cartão SD.
- `docs/hdmi-stock-re.md` — engenharia reversa do HDMI stock.
- `patches/0005-*.patch` / `patches/0006-*.patch` — correções de HDMI.
