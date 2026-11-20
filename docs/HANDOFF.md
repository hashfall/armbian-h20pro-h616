# HANDOFF — continuar em outro PC

Tudo que é necessário para reproduzir o trabalho está **neste repositório**.
Arquivos grandes ficam em `artifacts/` (kernel pronto) e o firmware stock em
`H20 PRO 5G_20240409.zip` (raiz).

## 1. Hardware

- TV box **X96Q LPDDR3 / H20 Pro**, SoC **Allwinner H616 (H313)**, 1 GiB.
- PMIC **AXP313A**; eMMC 8 GB; SD de 64 GB.
- Monitor 2K na HDMI; UART em `ttyS0` **115200 8N1**.
- **Regra do projeto: boot e sistema somente pelo SD; eMMC intocado.**

## 2. Repositórios e versões

| item | valor |
|---|---|
| framework de build | `armbian/build` (clone `--depth 1`, commit `1ce67c2`) |
| kernel | stable `linux-6.18.y`, commit `fd7cfd39c885` (o build busca sozinho) |
| família | `sunxi64`, board `x96q`, release `trixie`, `KERNEL_ONLY=yes` |
| firmware stock analisado | `H20 PRO 5G_20240409.zip` (sha256 começa com `64ce8ddd…`) |

O build fica em `../armbian-build` (fora do repo); ele é recriado pelo
`scripts/build-kernel.sh`.

## 3. Preparar o PC

```bash
sudo ./scripts/setup-host.sh
```

Instala Docker, `qemu-user-static`, `qemu-user-binfmt`, `dtc` e registra o
binfmt **estático** de aarch64 (necessário para `chroot` no rootfs do SD).
Testado em Arch/CachyOS; há caminho para Debian/Ubuntu.

## 4. Patches (ordem léxica = ordem de aplicação)

| patch | o que faz |
|---|---|
| `0003-drm-sun4i-tcon-pad-select.patch` | liga o pad-select do TCON (redundante no 6.18, inofensivo) |
| `0005-drm-sun4i-h616-hdmi-phy-stock-tables.patch` | **97 entradas** de PLL/terminação extraídas do kernel stock (phy301) |
| `0006-drm-bridge-dw-hdmi-select-phy-i2c.patch` | escreve `JTAG_PHY_CONFIG (0x3034)=0x10` antes de configurar a PHY |
| `0010-drm-sun4i-hdmi-phy-debug.patch` | **diagnóstico**: readback I2C da PHY + estado no power-on |
| `0011-drm-sun4i-hdmi-phy-reset-pulse.patch` | **diagnóstico/correção**: pulso real de reset na PHY |

`0005`/`0006` vêm da engenharia reversa do stock (ver
`docs/hdmi-stock-re.md`). `0010`/`0011` podem ser removidos quando o HDMI
estiver estável.

## 5. Compilar

```bash
./scripts/build-kernel.sh
# debs em ../armbian-build/output/debs/
```

Ou manualmente:

```bash
cd ../armbian-build
./compile.sh kernel BOARD=x96q BRANCH=current RELEASE=trixie \
  BUILD_MINIMAL=yes KERNEL_ONLY=yes KERNEL_CONFIGURE=no DOCKER=yes
```

## 6. Instalar no SD (pelo PC)

1. Desligue a caixa e ponha o SD no PC.
2. `lsblk` para conferir o dispositivo (ex.: `/dev/mmcblk0p1`).
3. 

```bash
sudo ./scripts/install-kernel-to-sd.sh /dev/mmcblk0p1
```

O script monta, instala `linux-image`/`linux-dtb`, gera initramfs/uInitrd,
grava `dtb/sun50i-h313-x96q-lpddr3-final.dtb` e desmonta. Sem argumento, ele
procura um SD removível de 30–90 GB com ext4 e hostname `h20pro`.

Artefatos prontos (sem rebuild): `artifacts/linux-image-*.deb` e
`artifacts/linux-dtb-*.deb`.

## 7. DTB final

`dtb/sun50i-h313-x96q-lpddr3-final.dts` → `.dtb` contém:

- PHY H616 (`allwinner,sun50i-h616-hdmi-phy`);
- limites de MMC (25 MHz, sem DDR/1.8 V) para o SD/eMMC desta caixa;
- pinctrl do DDC (`PI0/PI1/PI2` em função `hdmi`);
- resets iguais ao DTB vendor.

Regerar:

```bash
dtc -I dts -O dtb -o dtb/sun50i-h313-x96q-lpddr3-final.dtb \
    dtb/sun50i-h313-x96q-lpddr3-final.dts
```

## 8. Diagnóstico na caixa

UART (ferramenta incluída): `tools/uart.py -t 5 'comando'`.

```bash
uname -r
cat /sys/class/drm/card0-HDMI-A-1/status
cat /sys/class/drm/card0-HDMI-A-1/modes
tail -400 /var/log/kern.log | grep -iE 'hdmi|phy|pll|edid'
```

Regmap em debugfs:

```bash
cat /sys/kernel/debug/regmap/6000000.hdmi/registers
cat /sys/kernel/debug/regmap/6010000.hdmi-phy-phy/registers
```

O kernel com `0010` imprime:

```
PHY readback: 00=.. 05=.. 06=.. 09=.. 0e=.. 10=.. 13=..
PHY power_on: mpixel=.. conf0=.. stat0=.. clkdis=.. phyrstz=..
PHY lock loop: i=.. val=.. stat0=..
```

## 9. Estado em 2026-11-20

- Boot SD, UART, SSH local e eMMC intocado OK.
- HDMI: `PHY PLL failed to lock`.
  - O readback provou que a configuração I2C da PHY **chega** (valores lidos
    iguais aos escritos) e que a PHY está ligada (`conf0=0x2e`).
  - O PLL não trava em 65 MHz nem em 172,78 MHz (500 ms de espera).
  - EDID lê tudo zero e o DDC (`/dev/i2c-1`) dá EAGAIN; o vendor usa
    `hdmi_skip_bootedid=1`, então EDID pode não existir nesta caixa.
  - Aplicados agora: tabelas exatas do stock (0005) + select I2C/JTAG (0006)
    + reset pulse (0011). **Falta testar.**
- Se ainda falhar: próximo passo documentado em `docs/hdmi-stock-re.md` §6 —
  `configure_phy` específico de H616 que não escreve 0x13/0x05 e usa
  `MSM_CTRL=0x8006` em 594 MHz.

## 10. Segurança

- Não rode `scripts/emmc-install.sh`; não crie
  `/boot/emmc-install/allow-emmc-install`.
- Não escreva em `mmcblk2`, `mmcblk2boot0/1`.
- Confirme `findmnt -no SOURCE /` = `/dev/mmcblk0p1` antes de qualquer ajuste.
- Sempre `sync` + `umount` antes de tirar o SD do PC.

## 11. Registro — 2026-11-20 (última gravação no SD)

**Build instalado no SD:** `6.18.64` hash
`6.18.64-Sfd7c-D7c7d-Pf987-C42c5-Hfaa2-HK01ba-Vc222-Bdf9b-R448a`
(`linux-image`/`linux-dtb` em `artifacts/`).

Patches aplicados nesse build:

- `0003` pad-select;
- `0005` tabelas stock (97 entradas, phy301);
- `0006` `JTAG_PHY_CONFIG = 0x10`;
- `0010` debug/readback;
- `0011` pulso de reset da PHY.

**Evidência de gravação (PC):**

- `dpkg -i` no SD concluiu, `update-initramfs`/`uInitrd` gerados;
- DTB gravado com md5 `b0b9993961fbaa05bd7701fd97212522`, igual ao
  `dtb/sun50i-h313-x96q-lpddr3-final.dtb`;
- script terminou com `INSTALACAO_OK` e desmontou o SD.

Uma tentativa posterior de montar `/dev/mmcblk0p1` no PC falhou com
`can't read superblock` **porque o cartão já estava na caixa** (dmesg:
`mmc0: card 0001 removed`). Não é falha de gravação.

**Pendente/observação:** a caixa subiu com esse SD, mas a leitura do UART
voltou apenas sequências de terminal (`[!p]104...[6n`), sem prompt nem log.
Falta capturar:

```
uname -r
tail -400 /var/log/kern.log | grep -iE 'PHY (init state|power_on|lock loop|readback)|PLL|EVENT|EDID'
cat /sys/class/drm/card0-HDMI-A-1/status
```

para confirmar se o PLL travou com as tabelas stock + select I2C/JTAG.

**Regra:** não iniciar outro build até registrar/avaliar este resultado.

## 12. Resultado do build Pf987 (lido do box em 2026-11-20)

Log completo: `docs/logs/2026-11-20-pf987.md`.

- `uname -r` = `6.18.64-current-sunxi64`; root = `/dev/mmcblk0p1` (SD);
  DTB md5 = `b0b99939…`; HDMI `connected`; EDID = 0 bytes.
- **Patch 0005 aplicado**: readback da PHY mudou de
  `06=0040 09=8039 0e=022b 10=0019` para
  `06=0051 09=8009 0e=0230 10=001b`.
- **Patch 0006 aplicado** (JTAG/I2C) e **não resolveu**.
- I2C da PHY funciona: o readback devolve exatamente os valores escritos.
- PLL continua sem travar (100 × 5 ms) em 172,78 MHz:
  `stat0=00`, `conf0=2e`.
- **O pulso de reset (0011) não foi aplicado**: `reset_control_assert()`
  dispara `WARNING ... reset/core.c:483` porque o bootloader deixou o reset
  deassertado e o driver nunca chamou `deassert()` (contador 0). Os
  registradores externos da PHY seguem iguais aos do bootloader
  (`ana1=00000f80 ana2=0c0040d8 ana3=02700203 pll1=000c6023`).

**Próximo build (em PC mais potente):**

1. corrigir o reset: `deassert()` antes de `assert()` (ou
   `reset_control_reset()`), para realmente pulsar a PHY;
2. se ainda falhar, `configure_phy` específico de H616 fiel ao stock:
   não escrever 0x13/0x05, alternar SVSRET por modo e usar
   `MSM_CTRL=0x8006` em 594 MHz (`docs/hdmi-stock-re.md` §6);
3. manter `0005`/`0006` e o debug `0010`.

Não iniciar build até isso ser feito no PC mais potente.
