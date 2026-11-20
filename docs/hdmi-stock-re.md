# Engenharia reversa do HDMI do Android stock (H20 Pro / H616)

Firmware analisado: `H20 PRO 5G_20240409.zip` (imagem Allwinner `IMAGEWTY`,
Android 10, kernel Linux 4.9 arm64).

O objetivo foi extrair do driver HDMI **stock** o que o mainline não tem:
modelo exato do PHY, tabela de PLL/terminação por clock de pixel e a sequência
de power-on. O ponto de partida no mainline era o erro real da caixa:

```
sun8i-dw-hdmi 6000000.hdmi: PHY PLL failed to lock
```

**Resumo em duas linhas:**

1. O stock seleciona a interface I2C do PHY (`JTAG_PHY_CONFIG`, registrador
   `0x3034` = `0x10`) **antes de cada configuração**. O mainline não escreve
   isso; se o PHY estiver em JTAG, os writes de I2C são descartados em
   silêncio. Patch `0006`.
2. O patch H616 do Armbian usa 5 pontos de tabela; o stock usa 97. Em
   particular, 1024x768@60 (65 MHz) usa `CURR=0x08`, não `0x13`, e 4K60 usa
   `CPCE=0x1a7c`, não `0x1a40`. Patch `0005`.

## 1. Como a imagem foi aberta

A imagem é um container `IMAGEWTY` (imgRePacker). A tabela de 40 partições
começa em `0x400`, com entradas de `0x400` bytes:

| campo | offset | tamanho |
|---|---|---|
| `filename_length` | +0x00 | u32 |
| `header_size` | +0x04 | u32 (0x400) |
| `maintype` | +0x08 | 8 |
| `subtype` | +0x10 | 16 |
| `unknown` | +0x20 | u32 |
| `filename` | +0x24 | 256 |
| `stored_length` | +0x124 | u32 |
| `original_length` | +0x12c | u32 |
| `offset` | +0x134 | u32 |

Partições relevantes:

| partição | offset | tamanho | conteúdo |
|---|---|---|---|
| `boot.fex` | `0x00aeb400` | 32 MiB | boot.img Android (kernel + ramdisk + DTB) |
| `super.fex` | `0x02aeb800` | 1.085 GiB | sparse -> system/vendor/product |
| `sunxi.fex` | `0x00024000` | 141 KiB | DTB |
| `sys_partition.fex` | `0x00022800` | 5 KiB | tabela de partições |

O `boot.fex` é um boot image v2: kernel `Image` ARM64 **não comprimido**
(18.804.744 bytes), ramdisk de 771.329 bytes e DTB de 138.057 bytes.
O kernel tem `kallsyms` completo; foi reconstruído como ELF com
`vmlinux-to-elf` (92.506 símbolos) e desmontado com
`aarch64-linux-gnu-objdump`.

## 2. Qual driver o stock usa

O HDMI **não** é o `sun8i_dw_hdmi` do mainline. É o BSP Allwinner:

```
drivers/video/fbdev/sunxi/disp2/hdmi2/hdmi_tx.c
drivers/video/fbdev/sunxi/disp2/hdmi2/hdmi_core/api/phy.c
drivers/video/fbdev/sunxi/disp2/hdmi2/hdmi_core/api/api.c
```

É um driver Synopsys DWC HDMI 2.0 TX completo, built-in no kernel. A fonte
correspondente está em `orangepi-xunlong/linux-orangepi`, branch
`orange-pi-4.9-sun50iw9`, commit `0cd0547` (2022-05-17). O binário contém as
mesmas strings/valores da fonte:

```
HDMI 2.0 driver init start!
HDMI MHL TSMC 28HPM 1.8V build - E301
```

### Modelo do PHY

`hdmi_tx.c` fixa `int phy_model = 301;` (não lê da DT). Portanto esta caixa
usa a tabela **`phy301[]`**, não a `phy303[]`. A `phy303` é a que aparece em
alguns patches do BSP e tem valores diferentes (por exemplo 594 MHz).

O PHY é o DWC HDMI 2.0 TX PHY acessado pelo **I2C master interno** do
controlador, com endereço escravo **0x69**:

```
mainline / DW-HDMI 8-bit map     BSP (byte address)
PHY_I2CM_SLAVE_ADDR   0x3020     0xC080
PHY_I2CM_ADDRESS      0x3021     0xC084
PHY_I2CM_DATAO_1      0x3022     0xC088
PHY_I2CM_DATAO_0      0x3023     0xC08C
PHY_I2CM_DATAI_1      0x3024     0xC090
PHY_I2CM_DATAI_0      0x3025     0xC094
PHY_I2CM_OPERATION    0x3026     0xC098
JTAG_PHY_CONFIG       0x3034     0xC0D0   (0x10 = I2C)
IH_I2CMPHY_STAT0      0x0108     0x0420
```

O `hdmitx_write(offset, val)` do BSP escreve no byte `base + (offset >> 2)`,
por isso os offsets `0xC0xx` acima correspondem aos registradores de palavra
`0x30xx` do DW-HDMI.

## 3. Sequência de configuração do PHY (phy301)

De `phy301_configure()`:

1. `mc_phy_reset(1)` (PHYRSTZ).
2. `PHY_CONF0` (0x3000): `TXPWRON=0`, `PDDQ=1`, `SVSRET=0`.
3. `SVSRET=1`.
4. `mc_phy_reset(0)`.
5. `phy_reconfigure_interface()`:
   - escreve **`JTAG_PHY_CONFIG`** (`0x3034`) = **`0x10`** (`I2C_JTAGZ`),
     selecionando a interface I2C do PHY;
   - escreve `PHY_I2CM_SLAVE_ADDR` = `0x69`.
   **O mainline não escreve esse registrador em lugar nenhum.** Se o PHY
   acordar em modo JTAG, todos os writes de I2C do PHY são aceitos pelo
   controlador mas não chegam ao PHY; o `dw_hdmi_phy_i2c_write()` do mainline
   não verifica o resultado, então o único sintoma é
   `PHY PLL failed to lock`.
6. Escreve, via I2C do PHY:

```
0x06  CPCE          = tabela
0x10  CURRCTRL      = tabela
0x15  GMPCTRL       = 3          (forçado no sun50iw9)
0x19  TXTERM        = tabela
0x09  CKSYMTXCTRL   = tabela
0x0E  VLEVCTRL      = tabela
```

7. Somente em 594 MHz: `0x17 MSM_CTRL = 0x8006`.
8. `PDDQ=0`, `TXPWRON=1`.
9. Poll de `PHY_STAT0` (0x3004) bit 0 (`TX_PHY_LOCK`), 100 tentativas de 5 ms.

O `resistor_calibration` do stock escreve `0x6010004 = 0x80c00000`
(upper 16 bits), exatamente como o `sun50i_hdmi_phy_init_h6` do mainline.

## 4. Tabela por clock de pixel

A tabela `phy301[]` do binário tem **243 entradas** (clock, pixel repetition,
color depth, opmode, CPCE, CURR, GMP, TXTERM, VLEV, CKSYMTXCTRL). Para o
mainline só interessam as entradas com `PIXEL_REPETITION_OFF`, que dão
**97 clocks de pixel** distintos, em 8/10/12 bpp.

Valores de referência (bpp 8, repetição 0):

| pixel clock | CPCE | CURR | TERM | VLEV | CKSYM |
|---|---|---|---|---|---|
| 25.175 MHz | 0x00b3 | 0x0000 | 0x0004 | 0x0232 | 0x8009 |
| 27.000 MHz | 0x00b3 | 0x0012 | 0x0007 | 0x02b0 | 0x8009 |
| 65.000 MHz (1024x768@60) | 0x0072 | **0x0008** | 0x0004 | **0x0232** | **0x8009** |
| 74.250 MHz | 0x0072 | 0x0013 | 0x0004 | 0x0290 | 0x8019 |
| 148.500 MHz (1080p60) | 0x0051 | 0x0019 | 0x0004 | 0x0290 | 0x8019 |
| 297.000 MHz (4K30) | 0x0040 | 0x0019 | 0x0004 | 0x022b | 0x8039 |
| 594.000 MHz (4K60) | **0x1a7c** | 0x0010 | 0x0000 | 0x008a | 0x8029 |

Clocks acima de 340 MHz (TMDS) usam as entradas `HDMI_20`; abaixo, `HDMI_14`.

### O que o patch atual do Armbian erra

O patch `0004-drm-sun4i-h616-hdmi-phy.patch` usa apenas 5 pontos
(27/74.25/148.5/297/594 MHz), com semântica de "primeiro clock >= pedido".
Comparando com a tabela stock:

- **93 dos 97** clocks mode-0 (8 bpp) caem em valores diferentes.
- Em **65 MHz** (modo de fallback 1024x768@60, o que aparece no log quando
  não há EDID) o mainline escolhe a entrada de 74.25 MHz:
  `CURR=0x13`, `VLEV=0x290`, `CKSYM=0x8019`;
  o stock usa `CURR=0x08`, `VLEV=0x232`, `CKSYM=0x8009`.
  `PLLCURRCTRL` é a corrente da charge pump do PLL; valor errado é candidato
  direto a **"PHY PLL failed to lock"**.
- Em **25.175 MHz** (640x480) o mainline usa `CURR=0x12`; o stock usa `0x0000`.
- Em **594 MHz** o `CPCE` do patch é `0x1a40`, que é o valor da **phy303**;
  a phy301 desta caixa usa **`0x1a7c`**.

O patch `0005` anexo substitui as três tabelas H616 pelas 97 entradas exatas
extraídas do binário stock.

## 5. TCON / pad select

O stock seleciona a saída do TCON para os pads de HDMI com
`tcon_gctl.bits.pad_sel = 1` (`tcon_pan_sel()`), exatamente o bit 1 do
`SUN4I_TCON_GCTL_REG` que o patch `0003` já liga. Não há nada além disso.

Os clocks do vendor e do mainline batem:

```
hdmi_parents   = pll_video0, pll_video0x4, pll_video2, pll_video2x4
tcon_tv_parents= pll_video0, pll_video0x4, pll_video1, pll_video1x4
```

O `assigned-clock-parents = <&pll_video2>` que aparece no DTS decompilado do
vendor não é confiável (a tabela do driver de clock nem lista `pll_video2`
para `tcon_tv`); não é a causa do problema.

## 6. Diferenças menores que ficaram documentadas

O `dw_hdmi_phy_init` genérico do mainline também escreve:

```
0x13 PLLPHBYCTRL = 0
0x17 MSM_CTRL    = 0x06
0x05 CKCALCTRL   = 0x80 (override)
```

O stock **não** escreve esses três (exceto `0x17 = 0x8006` em 594 MHz).
Se o lock ainda falhar depois dos patches 0005/0006, o próximo passo é um
`configure_phy` específico de H616 que reproduza o stock:
não escrever 0x13/0x05, usar `MSM_CTRL=0x8006` em 594 MHz e fazer o toggle
`SVSRET 0 -> 1` por modo.

### Ordem de prioridade

1. **0006** (`JTAG_PHY_CONFIG = 0x10`): sem ele, os writes de PHY podem não
   chegar ao PHY. É a causa mais provável do `PHY PLL failed to lock`.
2. **0005** (tabela exata): corrige os 93/97 clocks que hoje usam valores de
   outra frequência. Sem isso, mesmo com I2C funcionando, 1024x768@60
   (65 MHz) usa corrente de charge pump errada.

## 7. Como testar

Copiar os dois patches para o build (nesta ordem):

```sh
cp patches/0005-drm-sun4i-h616-hdmi-phy-stock-tables.patch \
   patches/0006-drm-bridge-dw-hdmi-select-phy-i2c.patch \
   ../armbian-build/userpatches/kernel/sunxi-6.18/
```

Recompilar/instalar e, na caixa:

```sh
dmesg | grep -i -E 'hdmi|phy|tcon'
cat /sys/class/drm/card*-HDMI-A-1/status
cat /sys/class/drm/card*-HDMI-A-1/modes
```

Para forçar o modo que falhava no log (sem EDID), adicionar ao cmdline:

```
video=HDMI-A-1:1024x768@60
```

e conferir se `PHY PLL failed to lock` desaparece.

## 8. Reprodução

Ferramentas usadas (fora do repositório, em `/tmp/opencode`):

- `imagewty-tool` (parser IMAGEWTY) ou o parser Python de 40 entradas;
- `unpack_bootimg` (boot.fex);
- `simg2img` + `lpunpack` (super.fex);
- `vmlinux-to-elf` (símbolos do `Image`);
- clone sparse do BSP `orange-pi-4.9-sun50iw9` para conferir a fonte.
