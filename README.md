# Armbian H20 Pro (Allwinner H616, 1 GB) — instalação automática no eMMC

Cartão SD preparado para:

1. iniciar o Armbian pelo SD na TV Box;
2. apagar completamente o eMMC (sem deixar partições do Android);
3. gravar o Armbian no eMMC;
4. expandir a partição/filesystem para ocupar todo o eMMC;
5. criar o usuário **glenda** com senha **glenda**;
6. salvar os logs no próprio SD e desligar a caixa.

O script só roda quando o sistema foi iniciado pelo **SD** e existe o marcador
`/boot/emmc-install/enabled`. Ele nunca apaga o cartão SD; as únicas escritas
no SD são os logs e os marcadores de estado.

## Imagem usada

- Armbian Community 26.11.0-trunk.130
- Board: **X96Q TV Box** (sun50iw9 / Allwinner H313, LPDDR3, 1/2 GB, eMMC)
- Debian Trixie, kernel 6.18.63-current-sunxi64, variante **minimal**
- U-Boot 2026.10 com LPDDR3

A primeira tentativa usou a imagem do **X96 Mate** (H616 + DDR3 1333), mas o
SPL parou em `This DRAM setup is currently not supported.` e reiniciou em loop,
sem tocar no eMMC. Para uma caixa de 1 GB, a configuração LPDDR3 do X96Q é a
candidata mais provável. Se ela também não inicializar, a próxima é a do
**Tanix TX6s** (H616 + DDR3).

## O que acontece no primeiro boot pelo SD

O serviço `emmc-install.service` roda antes do `multi-user.target`:

1. confere o checksum da imagem em `/root/armbian-install.img`;
2. localiza o eMMC (dispositivo MMC que não é o SD de boot);
3. apaga `wipefs` + `blkdiscard` + início/fim do dispositivo;
4. grava a imagem com `dd` (U-Boot, kernel, DTB e rootfs);
5. confere o SHA256 do que foi gravado;
6. expande a partição 1 e o ext4 até o fim do eMMC;
7. troca o UUID do rootfs do eMMC e atualiza `armbianEnv.txt`/`fstab`;
8. remove o instalador da cópia do eMMC (para não rodar de novo);
9. grava `RESULTADO.txt` e `done` no SD, dá `sync` e desliga a caixa.

Enquanto roda, o progresso aparece no UART (115200 8N1) e no HDMI.

## Depois da instalação

1. Espere a caixa desligar sozinha.
2. **Remova o cartão SD.**
3. Ligue a caixa: ela deve iniciar pelo eMMC.
4. Login no console UART/HDMI:
   - usuário: `glenda`
   - senha: `glenda`
   - root: `glenda` (emergência)

O getty serial em `ttyS0` já vem habilitado.

## Logs no SD

O cartão SD guarda tudo em:

```
/boot/emmc-install/
├── enabled              # marcador que autoriza a instalação (não apague durante o processo)
├── done                 # criado no sucesso
├── failed               # criado em caso de falha
├── RESULTADO.txt        # resumo: dispositivo, partição, UUID, tabela, blkid
└── logs/
    ├── install-001.log
    ├── install-002.log
    └── latest.log -> install-00N.log
```

Para ler no PC, monte a partição ext4 do SD e abra `boot/emmc-install/logs/`.

### Se falhar

- A caixa **não** desliga; o UART continua mostrando o console.
- O arquivo `failed` impede novas tentativas automáticas (evita boot loop).
- Leia o log, corrija o problema e apague `failed` para tentar de novo.
- Se o eMMC ficou parcialmente gravado, a próxima execução apaga tudo outra vez.

### Para repetir a instalação

Apague `done` e `failed` no SD e ligue a caixa com o SD. A imagem será gravada
de novo. **Isso apaga o eMMC inteiro.**

## Expansão manual (se precisar)

A expansão já é feita pelo instalador. Se em algum momento precisar repetir:

No sistema instalado (online):

```bash
sudo /usr/local/sbin/expand-rootfs.sh
```

Ou, inicializando pelo SD, para arrumar o eMMC desmontado:

```bash
sudo /usr/local/sbin/expand-rootfs.sh /dev/mmcblk2p1
```

Confira o dispositivo correto com `lsblk` antes.

Comandos manuais equivalentes (eMMC desmontado, ex.: `/dev/mmcblk2`):

```bash
sudo parted -s -f /dev/mmcblk2 resizepart 1 100%
sudo partx -u /dev/mmcblk2
sudo e2fsck -f -y /dev/mmcblk2p1
sudo resize2fs /dev/mmcblk2p1
```

## Arquivos deste repositório

- `scripts/emmc-install.sh` — instalador que roda no SD.
- `scripts/emmc-install.service` — unidade systemd que dispara o instalador.
- `scripts/expand-rootfs.sh` — helper de expansão online/offline.
- `scripts/LEIA-ME-SD.txt` — cópia resumida colocada no SD.

## Avisos

- O processo **apaga o eMMC inteiro**. Não há confirmação interativa.
- O SD é a fonte da imagem; não o remova antes do poweroff.
- Depois do sucesso, remova o SD antes de ligar de novo; o BootROM do H616
  prefere o SD ao eMMC.
- A senha `glenda` é fraca; troque com `passwd` depois de validar a instalação.
