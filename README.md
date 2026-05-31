# Vless Extra

**VLESS + Reality + Vision** на Xray-core (чистый TCP, без домена и сертификата) + опциональный выход через **Cloudflare WARP**. Клиент — **Clash Verge Rev / mihomo**, плюс `vless://`-ссылка с QR и готовый **Xray JSON** для xray-core/v2rayN.
## Что нужно

- Чистый VPS **за пределами РФ** (Ubuntu/Debian), root.
- Публичный IPv4. Домен не нужен.
- Свободные **TCP 443** (VLESS) и **TCP 80** (страница с конфигами).

## Установка

```
wget -O install.sh https://raw.githubusercontent.com/Vlatqa/VlXray/master/install.sh
chmod +x install.sh
bash install.sh
```

Скрипт ставит Xray, включает BBR, регистрирует бесплатный WARP через `wgcf`, генерит ключи Reality/UUID/shortId, поднимает страницу с конфигами на порту 80 и печатает `vless://`-ссылку, URL страницы и URL `.yml`/`.json`.

## Настройки (шапка скрипта)

```bash
REALITY_DEST="www.microsoft.com"   # чужой сайт для маскировки
REALITY_SNI="www.microsoft.com"    # SNI (= домен из сертификата dest)
XRAY_PORT=443
PROXY_NAME="VlessExtra"
```

**Требования к `dest`:** TLS 1.3 + HTTP/2, не за Cloudflare/CDN, доступен с VPS, не заблокирован в РФ, `SNI` совпадает с доменом сертификата. Проверка с сервера: `curl -sI --http2 https://www.microsoft.com | head -n1` должно дать `HTTP/2`. Альтернативы: `www.amd.com`, `dl.google.com`.

После правки шапки — `bash install.sh update` (ключи/UUID сохраняются).

## Режимы WARP

В шапке скрипта блок — раскомментируй **один** вариант (`WARP_MODE`):

| Режим | Что делает |
| --- | --- |
| `all` | весь трафик через WARP (IP Cloudflare) |
| `domains` | через WARP **только** домены/категории из `WARP_GEO`, остальное прямым IP сервера |
| `all-except` | через WARP **всё, КРОМЕ** `WARP_GEO` (эти — прямым IP сервера) |
| `off` | WARP выключен, весь трафик прямым IP сервера |

Список для режимов `domains`/`all-except` задаётся массивом `WARP_GEO` в синтаксисе Xray-роутинга (`geosite:` / `domain:`):

```bash
WARP_GEO=(
  "geosite:google"
  "geosite:category-ai-!cn"
  "domain:voidboost.cc"
)
```

Текущая конфигурация: `all-except` — весь трафик уходит через WARP (чистый IP Cloudflare), а Google, AI-сервисы и `voidboost.cc` идут напрямую с IP сервера.

Меняешь режим/список → `bash install.sh update`. Если WARP не поднялся при установке — любой режим автоматически работает как `off`, прокси не ломается.

> ⚠️ geosite-категория должна существовать в установленном `geosite.dat` (Просмотреть содержимое geosite.dat, geoip.dat с категориями можно по ссылке https://jomertix.github.io/geofileviewer/), иначе Xray не стартанёт. Если в `journalctl -u xray -e` увидишь `failed to load geosite` — замени категорию на явные домены (`"domain:..."`).

## Что получается на выходе

| URL | Для чего                                   |
| --- |--------------------------------------------|
| `http://<ip>/` | Заглушка (если зайти браузером по IP) |
| `http://<ip>/<random>.html` | Страница c конфигами |
| `http://<ip>/<random>.yml` | Конфиг для **Clash.Meta / mihomo** |
| `http://<ip>/<random>.json` | **Xray JSON** для xray-core, v2rayN и др. |

## Обновление конфигов

```
bash install.sh update
```

Читает state из `/usr/local/etc/xray/.vlessextra.env` и пересобирает все конфиги с теми же ключами/UUID/WARP-аккаунтом. Шапка (dest, SNI, порт, имя, режим WARP, список) имеет приоритет — правишь шапку и применяешь update. Полная смена ключей/UUID — установка заново (без `update`).

## Роутинг и DNS на клиенте

**Правила (`.yml`):**

- `qBittorrent.exe` → **DIRECT** (торрент мимо VPN: не грузим канал VPS, не ловим DMCA). Работает в режиме TUN; другой торрент-клиент — допиши строку `PROCESS-NAME,...,DIRECT`.
- приватные сети → **DIRECT**;
- `GEOSITE,category-ru` и `GEOIP,ru` → **DIRECT** (российское — напрямую, с реального IP);
- остальное → **PROXY**.

**DNS — чтобы direct-трафик трогать по минимуму:**

```yaml
dns:
  enhanced-mode: fake-ip
  fake-ip-filter:
    - "+.lan"
    - "+.local"
    - "+.internal"
    - "geosite:category-ru"
    - "geoip:ru"
  nameserver:
    - system
```

Логика: при fake-ip проксируемые домены резолвятся **на сервере** (Xray со sniffing видит домен) — клиенту иностранный DNS не нужен, ТСПУ его не видит. RU-домены и RU-IP вынесены в `fake-ip-filter`, поэтому резолвятся по-настоящему через **системный DNS** провайдера и идут напрямую, в реальные адреса — без fake-ip-прослойки. Это нужно, чтобы российские сервисы (Озон и т.п.) видели обычного российского юзера, а не подменные IP.

**Xray JSON (`.json`)** повторяет ту же логику для xray-core: socks `127.0.0.1:10808` + http `10809`, аутбаунд VLESS-Reality, и роутинг — bittorrent / приватные / `geosite:category-ru` / `geoip:ru` → `direct`, остальное → `proxy`. Торрент здесь ловится **по протоколу** (`protocol: bittorrent`), а не по имени процесса — надёжнее.

## Проверка после установки

```
systemctl is-active xray nginx
journalctl -u xray -e --no-pager | tail -20
ss -tlnp | grep ':443'
```

Проверка раздельного выхода (для текущего режима `all-except`): на клиенте `2ip.ru` / `ip.gs` покажет **IP Cloudflare** (через WARP), а Google/AI/voidboost и RU-сайты — соответственно прямой IP сервера / твой российский IP.

## Полезные команды

```
cat /usr/local/etc/xray/.vlessextra.env                 # IP, UUID, ключи, WARP
curl -sI --http2 https://www.microsoft.com | head -n1   # годен ли dest для Reality
curl -s4 ifconfig.co                                    # IPv4 сервера
xray x25519                                             # перевыпустить ключи Reality вручную
```

## Удалить

```
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge
apt-get purge -y nginx
rm -rf /var/www/vless /usr/local/etc/xray /etc/wgcf \
       /etc/sysctl.d/999-vlessextra.conf /etc/security/limits.d/99-vlessextra.conf
systemctl daemon-reload
```
