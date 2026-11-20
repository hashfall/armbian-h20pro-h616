# AGENTS.md — Armbian H20 Pro (H616) — boot pelo SD

## Objetivo atual

- Armbian **totalmente funcional a partir do cartão SD**: HDMI, Ethernet 100M, Wi-Fi/BT e USB.
- O **eMMC fica intocado**. Não instalar, gravar, formatar nem “aproveitar” o eMMC.
- Build do kernel em `../armbian-build/`; firmware stock em `../9front-h20pro/H20 PRO 5G_20240409.zip`; notas de HDMI em `docs/`.

## Regras duras (SD-only)

- Não rode `scripts/emmc-install.sh` e **não crie** `/boot/emmc-install/allow-emmc-install`. O instalador é legado e apaga o eMMC.
- Em SD antigo, remova `/boot/emmc-install/enabled` antes de bootar; o serviço antigo ainda pode existir nesse cartão.
- Não escreva em `mmcblk2`/`boot0`/`boot1` e não leia `mmcblk2boot1` (relato de `hung_task` no projeto 9front).
- Confirme que o root é o SD: `findmnt -no SOURCE /` deve ser `/dev/mmcblk0p1`. Se for `/dev/mmcblk2p1`, você está no eMMC: pare.
- Expansão do rootfs do SD: `sudo ./scripts/expand-rootfs.sh` (ou o helper já instalado, se existir). Ele exige que a partição seja a última.
- Não remova checagens de segurança dos scripts para “testar”.

## Boot / hardware

- Imagem base: **X96Q LPDDR3** (sun50iw9). A X96 Mate (DDR3 1333) falha em `This DRAM setup is currently not supported.`.
- Console: `ttyS0`, 115200 8N1, getty habilitado. Use UART para debug; o HDMI pode falhar até o patch 0006.
- O SD tem prioridade de boot no H616; não é preciso tocar no eMMC.
- Login `glenda`/`glenda` (senha fraca; troque).

## Build e patches (HDMI)

- Build: `../armbian-build/`. Patches de kernel em `../armbian-build/userpatches/kernel/sunxi-6.18/`.
- Lá já existem `0003-drm-sun4i-tcon-pad-select.patch` e `0004-drm-sun4i-h616-hdmi-phy.patch`. Os patches deste repo (`patches/0005`, `0006`) ainda **não** estão instalados; copie para `userpatches/kernel/sunxi-6.18/` antes de compilar.
- Ordem: 0003 → 0004 → 0005 → 0006. `0005` substitui as tabelas H616; `0006` adiciona o select I2C/JTAG do PHY (provável causa do `PHY PLL failed to lock`).
- `0006` só atua se o nó HDMI mantiver o compatible `allwinner,sun50i-h616-dw-hdmi`; não remova esse compatible do DTS.
- O kernel 6.18 já tem `CONFIG_AC300_PHY=y`, `CONFIG_DWMAC_SUN8I=m`, `CONFIG_WLAN_UWE5622=m`, `CONFIG_TTY_OVERY_SDIO=m`.

## HDMI (fatos do stock)

- O stock usa DWC HDMI 2.0 com PHY **phy301** (não phy303), I2C `0x69`, GMP=3. A tabela tem 97 clocks; as entradas de 1080p/297 MHz do patch batem com o stock, mas 65 MHz e 594 MHz não. Leia `docs/hdmi-stock-re.md`.
- `docs/h616_phy_tables.c` é referência gerada a partir do kernel stock; não edite à mão. O patch real é `patches/0005`.
- Sintoma no mainline: `sun8i-dw-hdmi 6000000.hdmi: PHY PLL failed to lock`. Para testar sem EDID, force `video=HDMI-A-1:1024x768@60`.

## Ethernet / WiFi

- Ethernet: `gmac1` em `0x05030000`, RMII, PHY interno **AC300**. O driver está no kernel 6.18. No X96Q (mesmo AC300/EMAC1) a receita é PWM5 2 MHz no PA12, calibration do eFUSE, `mdio-mux` e nó AC300; confirme pinos/calibração na H20 Pro. Referência: `ryzen30xx/x96q-lan-enabler` — adapte, não copie o DTB.
- WiFi/BT: **UWE5622/AW859A** via SDIO (`sprd,marlin3`). Use o driver `uwe5622` da Armbian (ou `uwe5622-ng`), firmware `wcnmodem.bin` + `wifi_2355b001_1ant.ini` extraídos do stock, e DT com SDIO + `mmc-pwrseq` + nó `uwe-bsp`. Driver não substitui firmware/DT.
- Não use o DTB/imagem do T95: RAM (DDR3 vs LPDDR3), PMIC (AXP305 vs AXP313a) e pinagem são diferentes. Os drivers são reaproveitáveis; o DTB não.

## Verificação

- Não há suíte de testes. Para scripts: `bash -n scripts/*.sh` (e `shellcheck` se disponível).
- Na caixa: `findmnt -no SOURCE /`; `dmesg | grep -Ei 'hdmi|phy|dwmac|ac300|uwe|sprd'`; `cat /sys/class/drm/card*-HDMI-A-1/status`; `ip link`; `iw dev`.
- Kernel/DTB atualizados no SD pelo build em `../armbian-build`; não invente um fluxo de build neste repo.

## Convenções

- Scripts são Bash com `set -Eeuo pipefail` e mensagens em português; preserve o estilo.
- O foco é Armbian/mainline. Não proponha Android/stock como solução.
