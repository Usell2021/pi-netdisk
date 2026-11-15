# pi-netdisk

Raspberry Pi 4 как USB‑флешка для iPhone, у которой нет собственной памяти.
iPhone видит обычный внешний диск, но каждый блок читается и пишется по Wi‑Fi
в файл‑образ на Linux‑ПК. На Pi данные не хранятся: ни на SD‑карте, ни в свопе.

```
┌────────┐   USB‑C    ┌──────────────┐  Wi‑Fi, NBD + TLS  ┌──────────────────────────┐
│ iPhone │ ─────────▶ │ Raspberry Pi │ ─────────────────▶ │ ПК: disk.img (exFAT)     │
│ «Файлы»│ mass       │ USB gadget   │                    │ ~/iPhone, когда Pi нет   │
│ «Фото» │ storage    │ без хранения │                    │                          │
└────────┘            └──────────────┘                    └──────────────────────────┘
```

## Как это работает

- **Pi.** USB‑C работает в режиме устройства (`dwc2`, `libcomposite`). Носитель
  у mass‑storage гаджета — это `/dev/nbd0`, подключённый к ПК через `nbd-client` по TLS.
  - Если ПК недоступен, iPhone видит пустой кардридер. Когда ПК становится
    доступен, диск появляется сам.
  - Своп только zram, без сброса на SD. Кэш грязных страниц не больше 8 МБ
    и около 1 с, после чего данные уходят на ПК.
- **ПК.** `nbd-server` слушает только `127.0.0.1` и принимает только TLS.
  Перед ним стоит `iphone-disk-gate`, который не даёт ПК и iPhone открыть диск
  одновременно:
  - Pi не подключён: образ смонтирован в `~/iPhone`, файлы кладутся как в обычную папку;
  - Pi подключился: `sync` + `umount`, после чего соединение проксируется в
    `nbd-server`. Если в `~/iPhone` открыт файл, Pi получает отказ и повторяет
    попытку, а iPhone видит «нет носителя»;
  - Pi пропал (питание от iPhone, поэтому без FIN): TCP keepalive замечает это
    за ~20 с, затем `fsck.exfat` и монтирование обратно.
- Образ разрежённый (sparse) с MBR и одним разделом exFAT. Место на ПК
  занимается по факту записи.

## Требования

| | |
|---|---|
| Pi | Raspberry Pi 4, Raspberry Pi OS trixie, Wi‑Fi в одной сети с ПК |
| ПК | Arch Linux (на других дистрибутивах нужно заменить `pacman` в `install-pc.sh`) |
| Телефон | iPhone с USB‑C (питания хватает на Pi 4 без нагрузки на CPU) или Android с OTG |

## Установка

**1. Pi**

```sh
scp -r pi <pi>:~/pi-netdisk
ssh -t <pi> sudo ~/pi-netdisk/install-pi.sh
```

Скрипт ставит `nbd-client`, включает `dtoverlay=dwc2,dr_mode=peripheral`, убирает
сброс zram на SD, уменьшает кэш записи, отключает энергосбережение Wi‑Fi
и включает службу `iphone-disk`. После установки нужно перезагрузить Pi.

**2. ПК**

```sh
sudo ./pc/install-pc.sh <pi-ssh-host>
```

Скрипт создаёт `/var/lib/iphone-disk/disk.img` (по умолчанию 32 ГБ, `SIZE=64G`
меняет размер), собственный CA, серверный и клиентский сертификаты, конфиг
`nbd-server` и две systemd‑службы. Клиентские ключи и адрес ПК он сам отправляет
на Pi.

**3. Проверка**

```sh
ssh <pi> journalctl -u iphone-disk -f      # medium inserted (34359738368 bytes ...)
journalctl -u iphone-disk-gate -f          # client connected / gone / mounted
```

Порт `10809/tcp` на ПК должен быть доступен с Pi.

### VPN / прокси с TUN (Clash, FlClash, sing-box…)

Адрес ПК определяется через `ip route get 1.1.1.1`. Если включён TUN, туда может
попасть его адрес (например `198.18.0.1`). Тогда исправьте адрес на Pi вручную:

```sh
ssh -t <pi> 'sudo sed -i "s/^PC_HOST=.*/PC_HOST=192.168.x.y/" /etc/iphone-disk/pi.conf && sudo systemctl restart iphone-disk'
```

### Ethernet вместо Wi‑Fi

Всё работает и по кабелю, причём быстрее: упор будет в USB 2.0 гаджета и TLS
на CPU Pi, ориентировочно 20–35 МБ/с против единиц МБ/с по Wi‑Fi. Главное,
чтобы `PC_HOST` на Pi указывал на адрес ПК в той сети, через которую идёт связь.

- **Pi и ПК в одном роутере по кабелю:** ничего менять не надо. Желательно
  закрепить IP ПК в DHCP роутера.
- **Прямой кабель Pi ↔ ноут:** в NetworkManager на ноуте для проводного
  подключения выберите «Shared to other computers»
  (`nmcli con modify <eth-conn> ipv4.method shared`). Ноут раздаст Pi адрес
  и сам будет на `10.42.0.1`. На Pi пропишите `PC_HOST=10.42.0.1` и сделайте
  `systemctl restart iphone-disk`. После этого по Wi‑Fi Pi на этот ПК не пойдёт,
  пока `PC_HOST` не вернуть обратно.

### Перенос на другой ПК

На новом ПК запустите `sudo ./pc/install-pc.sh <pi-ssh-host>`. Pi получит новые
сертификаты и адрес и переключится сам. Вручную это делается так:
`iphone-disk-set-pc <bundle.tar>`.

## Удаление

Скрипты удаляют всё, что поставили установщики. Склонированный репозиторий
остаётся на месте.

**Pi:**

```sh
ssh -t <pi> sudo ~/pi-netdisk/uninstall-pi.sh [--remove-packages]
ssh -t <pi> sudo reboot
```

- Удаляется: служба, USB‑гаджет, `/etc/iphone-disk` (с TLS‑ключами), скрипты в `/usr/local/sbin`.
- Возвращаются умолчания Raspberry Pi OS:
  - `config.txt` в том виде, что был до установки;
  - `dwc2` убирается из `/etc/modules`;
  - zram writeback и swap‑файл;
  - sysctl;
  - энергосбережение Wi‑Fi.
- `--remove-packages` дополнительно удаляет `nbd-client`.

**ПК:**

```sh
sudo ./pc/uninstall-pc.sh [--delete-image] [--remove-packages] [-y]
```

- Удаляются службы, `/etc/iphone-disk` (CA и ключи), `iphone-disk-gate`,
  системный пользователь, бандл для Pi и пустая папка `~/iPhone`.
- **Образ с файлами по умолчанию сохраняется.** Он остаётся в
  `/var/lib/iphone-disk/disk.img` и переходит во владение вашему пользователю.
  Удаляется только с флагом `--delete-image`. Смонтировать его без служб:
  `sudo mount -o loop,offset=1048576 /var/lib/iphone-disk/disk.img /mnt`
- `--remove-packages` дополнительно удаляет `nbd` и `exfatprogs`.

## Как диск представляется телефону

По умолчанию диск называет себя `iphone-disk / Network Disk`, отдаёт серийник Pi,
а SCSI‑строка у него `Linux File-Stor Gadget`. Всё это можно заменить строками
обезличенного кардридера: возьмите за основу [`pi/pi.conf.example`](pi/pi.conf.example)
и допишите нужные `USB_*` в `/etc/iphone-disk/pi.conf` на Pi. Применяется после
перезагрузки Pi.

```sh
ssh -t <pi> 'sudoedit /etc/iphone-disk/pi.conf && sudo reboot'
```

Метка тома (имя диска в «Файлах») задаётся при создании образа (`LABEL=…`,
по умолчанию `Untitled`). Переименовать существующий образ, пока iPhone
не подключён:

```sh
sudo systemctl stop iphone-disk-gate
loop=$(sudo losetup -P --find --show /var/lib/iphone-disk/disk.img)
sudo exfatlabel ${loop}p1 Untitled && sudo losetup -d $loop
sudo systemctl start iphone-disk-gate
```

## Импорт в «Фото» на iPhone

«Фото» показывают «Импорт» только для структуры как на карте камеры (DCF):

```
DCIM/100APPLE/IMG_0001.HEIC
DCIM/100APPLE/IMG_0001.MOV     ← пара Live Photo: одно имя, одна папка
DCIM/101APPLE/IMG_0002.JPG
```

- Имя папки ровно 8 символов: 3 цифры (100–999) + 5 символов `[A-Z0-9_]`.
  С `100TEST` будет «No photos to import».
- Имя файла: 4 символа + 4 цифры (`IMG_0001`).
- Дата в ленте берётся из EXIF `DateTimeOriginal`.

В медиатеке такие файлы помечаются как импортированные (коллекция «Импорт»).
Альбомы, избранное и правки хранятся в базе «Фото», а не в файлах, поэтому они
не переносятся.

## Файлы

```
pi/install-pi.sh           установка на Pi
pi/uninstall-pi.sh         удаление с Pi + откат системных настроек
pi/iphone-disk-gadget.sh   демон: USB‑гаджет ⇄ nbd-client
pi/iphone-disk-set-pc.sh   принять бандл (сертификаты + адрес ПК)
pi/pi.conf.example         пример конфига Pi (адрес ПК, USB/SCSI‑строки)
pc/install-pc.sh           установка на ПК: образ, TLS, nbd-server, службы
pc/uninstall-pc.sh         удаление с ПК (образ сохраняется, если не указать --delete-image)
pc/iphone-disk-gate.py     монтирование на ПК ⇄ отдача диска Pi, без одновременного доступа
```

## Ограничения

- Скорость упирается в Wi‑Fi Pi 4 и TLS: порядка единиц МБ/с на запись.
- Pi загружается после подключения к iPhone, поэтому диск появляется через ~30–40 с.
- Если выдернуть кабель во время записи, это как выдернуть обычную флешку:
  незаписанный хвост файла потеряется. ФС на ПК проверяется `fsck.exfat`
  перед каждым монтированием.
- exFAT нельзя увеличить на месте. Чтобы сменить размер, образ нужно пересоздать.
