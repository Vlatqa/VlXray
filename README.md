# Vless Extra

**VLESS + Reality + Vision** на Xray-core (чистый TCP, без домена и сертификата). На выходе — `vless://`-ссылка с QR и готовый **Xray JSON** (подписка по URL) для клиентов на ядре Xray.

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

Скрипт ставит последний стабильный Xray-core официальным установщиком [XTLS/Xray-install](https://github.com/XTLS/Xray-install), включает BBR, генерит ключи Reality/UUID/shortId, проверяет конфиги через `xray run -test`, поднимает страницу с конфигами на порту 80 и печатает URL страницы.

## Настройки (шапка скрипта)

```bash
REALITY_DEST="www.google.com"   # чужой сайт для маскировки (target)
REALITY_SNI="www.google.com"    # SNI (= домен из сертификата dest)
XRAY_PORT=443
PROXY_NAME="VlessExtra"

DNS_SERVER="https+local://dns.adguard-dns.com/dns-query"

CLIENT_DIRECT=(
  "geosite:category-ru"
#  "geoip:ru"
)

CLIENT_ROUTING_STRATEGY="AsIs"
```

**Требования к `dest`:** TLS 1.3 + HTTP/2, не за Cloudflare/CDN, доступен с VPS, не заблокирован в РФ, `SNI` совпадает с доменом сертификата. Проверка с сервера: `curl -sI --http2 https://www.google.com | head -n1` должно дать `HTTP/2`. Альтернативы: `www.amd.com`, `dl.google.com`.

**`DNS_SERVER`** — DoH-сервер (по умолчанию AdGuard DNS с блокировкой рекламы и трекеров):
- на **сервере** через него резолвятся все домены, которые идут через прокси, — блокировка работает для всех клиентов, в том числе подключённых по ссылке;
- в **клиентском JSON** через него резолвится то, что идёт напрямую (direct), — запрос идёт с клиента напрямую, мимо прокси.

`+local` в адресе обязателен: запрос к DoH уходит напрямую, а не через роутинг Xray (иначе на сервере получится петля). Сам хост `dns.adguard-dns.com` один раз резолвится системным DNS.

**`CLIENT_DIRECT`** — что клиентский JSON пускает **напрямую**, мимо прокси. Синтаксис Xray-роутинга:
- домены: `geosite:...`, `domain:...`, `full:...`, `keyword:...`, `regexp:...`
- IP: `geoip:...`, `1.2.3.4`, `10.0.0.0/8`

Скрипт сам раскладывает элементы на правило по домену и правило по IP. Торрент и приватные сети идут напрямую всегда.

**`CLIENT_ROUTING_STRATEGY`** — нужен, только если в `CLIENT_DIRECT` есть IP-правила (`geoip:`/IP):
- `AsIs` — домены ради роутинга не резолвятся; IP-правила срабатывают только для соединений, которые сразу идут по IP;
- `IPIfNonMatch` — домен, не попавший в доменные правила, резолвится через `DNS_SERVER` (с клиента) и проверяется по IP-правилам.

> ⚠️ geosite/geoip-категория должна существовать в `geosite.dat`/`geoip.dat` (содержимое можно посмотреть на https://jomertix.github.io/geofileviewer/). Скрипт проверяет клиентский JSON через `xray run -test` с dat-файлами сервера: если категории нет, JSON **не обновится**, а скрипт покажет ошибку `code not found in geosite.dat`. На клиенте используются dat-файлы самого клиента.

После правки шапки — `bash install.sh update` (ключи/UUID/ссылки сохраняются).

## Что получается на выходе

| URL | Для чего |
| --- | --- |
| `http://<ip>/` | Заглушка (если зайти браузером по IP) |
| `http://<ip>/<random>.html` | Страница с конфигами: ссылка + QR, JSON |
| `http://<ip>/<random>.json` | **Xray JSON** (подписка) для HAPP, v2RayTun, OneXray, v2rayN и др. |

## Обновление конфигов

```
bash install.sh update
```

Читает state из `/usr/local/etc/xray/.vlessextra.env` и пересобирает конфиги с теми же ключами/UUID и теми же URL страницы и JSON — клиенту достаточно обновить подписку. Все настройки берутся из шапки. Если Xray не принял новый конфиг (сервера или клиента), он не применяется, остаётся старый. Полная смена ключей/UUID — установка заново (без `update`).

При `update` поверх старой версии скрипта (с Clash/WARP) удаляется опубликованный `.yml` Clash-конфиг.

## Роутинг и DNS

**Сервер:** весь трафик клиентов уходит напрямую с IP сервера; домены резолвятся через `DNS_SERVER`; обращения к приватным адресам (localhost, локальные сети VPS) блокируются.

**Клиентский JSON (`.json`):** socks `127.0.0.1:10808` + http `10809`, аутбаунд VLESS-Reality, правила:
- `bittorrent` → `direct` (торрент мимо VPN: не грузим канал VPS, не ловим DMCA; ловится по протоколу);
- приватные сети → `direct`;
- `CLIENT_DIRECT` (по умолчанию `geosite:category-ru`) → `direct`;
- остальное → `proxy`, домен резолвится на сервере.

**Ссылка / QR:** только подключение, роутинг настраиваешь в клиенте сам.

## Проверка после установки

```
systemctl is-active xray nginx
journalctl -u xray -e --no-pager | tail -20
ss -tlnp | grep ':443'
xray run -test -config /usr/local/etc/xray/config.json
```

## Полезные команды

```
cat /usr/local/etc/xray/.vlessextra.env                 # IP, UUID, ключи, пути
curl -sI --http2 https://www.google.com | head -n1      # годен ли dest для Reality
curl -s4 ifconfig.co                                    # IPv4 сервера
xray x25519                                             # перевыпустить ключи Reality вручную
```

## Удалить

```
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge
apt-get purge -y nginx
rm -rf /var/www/vless /usr/local/etc/xray /etc/sysctl.d/999-vlessextra.conf
systemctl daemon-reload
```

Если сервер ставился старой версией скрипта (с WARP/Clash), удали и её остатки:

```
rm -rf /etc/wgcf /usr/local/bin/wgcf /etc/security/limits.d/99-vlessextra.conf
```
