#!/bin/bash
# Vless Extra — VLESS + XHTTP + Reality (self-steal) + VLESS Encryption + Vision на Xray-core

GRN='\033[1;32m'
RED='\033[1;31m'
YEL='\033[1;33m'
NC='\033[0m'

[[ $EUID -eq 0 ]] || { echo -e "${RED}❌ нужен root${NC}"; exit 1; }

XRAY_CFG=/usr/local/etc/xray/config.json
STATE_FILE=/usr/local/etc/xray/.vlessextra.env
WEB_PATH=/var/www/vless
ACME_PATH=/var/www/acme
CERT_HOOK=/etc/letsencrypt/renewal-hooks/deploy/vlessextra-nginx.sh

# ─────────────────────────── НАСТРОЙКИ ───────────────────────────
DOMAIN=""               # ваш домен; A-запись должна указывать на IP этого сервера (обязательно)
EMAIL=""                # почта для Let's Encrypt (уведомления об истечении); можно оставить пустой
XRAY_PORT=443
NGINX_TLS_PORT=8443     # nginx с сайтом-маскировкой, слушает ТОЛЬКО 127.0.0.1 (Reality target)
XMUX_MAX_CONN=1         # xmux maxConnections для клиента (JSON и ссылка)
PROXY_NAME="VlessExtra"

# DNS для клиентского JSON. Только IP, без доменного имени:
# в TUN-режиме домен DNS-сервера уходит в петлю (система → TUN → Xray → тот же DNS).
CLIENT_DNS_SERVER="https+local://94.140.14.14/dns-query"

# DNS (DoH). Используется:
#  - на сервере: резолв всех доменов, которые идут через прокси;
#  - в клиентском JSON: резолв того, что идёт напрямую (direct).
# "+local" обязателен: запрос к DoH идёт напрямую, а не через роутинг Xray.
DNS_SERVER="https+local://dns.adguard-dns.com/dns-query"

# Что клиент (JSON) пускает НАПРЯМУЮ, мимо прокси.
# Синтаксис Xray-роутинга:
#   домены: "geosite:...", "domain:...", "full:...", "keyword:...", "regexp:..."
#   IP:     "geoip:...", "1.2.3.4", "10.0.0.0/8"
# Торрент (bittorrent) и приватные сети идут напрямую всегда.
CLIENT_DIRECT=(
  "geosite:category-ru"
#  "geoip:ru"
)

# Как клиент сопоставляет домены с IP-правилами (geoip: и IP/CIDR из CLIENT_DIRECT):
#   "AsIs"         — домены не резолвятся ради роутинга; IP-правила срабатывают
#                    только для соединений, которые сразу идут по IP.
#   "IPIfNonMatch" — домен, не попавший в доменные правила, резолвится через
#                    DNS_SERVER (с клиента) и проверяется по IP-правилам.
CLIENT_ROUTING_STRATEGY="AsIs"
# ─────────────────────────────────────────────────────────────────

check_settings() {
    [ -n "$DOMAIN" ] || { echo -e "${RED}❌ заполни DOMAIN в шапке скрипта${NC}"; exit 1; }
    [[ "$XMUX_MAX_CONN" =~ ^[0-9]+$ ]] || { echo -e "${RED}❌ XMUX_MAX_CONN должен быть числом${NC}"; exit 1; }
    [[ "$NGINX_TLS_PORT" =~ ^[0-9]+$ ]] || { echo -e "${RED}❌ NGINX_TLS_PORT должен быть числом${NC}"; exit 1; }
}

save_state() {
    mkdir -p "$(dirname "$STATE_FILE")"
    cat > "$STATE_FILE" <<EOF
SERVER_IP="$SERVER_IP"
UUID="$UUID"
PRIV="$PRIV"
PUB="$PUB"
SHORTID="$SHORTID"
ENC_PRIV="$ENC_PRIV"
ENC_PASS="$ENC_PASS"
XHTTP_PATH="$XHTTP_PATH"
path_page="$path_page"
path_json="$path_json"
EOF
    chmod 600 "$STATE_FILE"
}

load_state() {
    [ -f "$STATE_FILE" ] || { echo -e "${RED}❌ state-файл $STATE_FILE не найден. Сначала установка.${NC}"; exit 1; }
    # shellcheck disable=SC1090
    source "$STATE_FILE"
}

rand_name() {
    openssl rand -hex 10
}

urlencode() {
    local LC_ALL=C s="$1" out="" c i
    for (( i = 0; i < ${#s}; i++ )); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) out+="$c" ;;
            *) out+=$(printf '%%%02X' "'$c") ;;
        esac
    done
    printf '%s' "$out"
}

html_escape() {
    local s="$1" amp='&amp;' lt='&lt;' gt='&gt;' quot='&quot;'
    s="${s//&/"$amp"}"
    s="${s//</"$lt"}"
    s="${s//>/"$gt"}"
    s="${s//\"/"$quot"}"
    printf '%s' "$s"
}

# Пара ключей x25519: печатает "<private> <public/password>".
# Разбор устойчив к разным версиям вывода `xray x25519`.
x25519_pair() {
    local out priv pub
    out=$(xray x25519) || return 1
    priv=$(echo "$out" | grep -i 'private' | head -n1 | awk '{print $NF}')
    pub=$(echo  "$out" | grep -iE 'password|public' | head -n1 | awk '{print $NF}')
    [ -n "$priv" ] && [ -n "$pub" ] || return 1
    echo "$priv $pub"
}

# Строки VLESS Encryption: сервер — decryption (PrivateKey), клиент — encryption (Password).
gen_enc_strings() {
    VLESS_DEC="mlkem768x25519plus.native.600s.$ENC_PRIV"
    VLESS_ENC="mlkem768x25519plus.native.0rtt.$ENC_PASS"
}

# Проверка конфига самим Xray. $1 — файл.
xray_test() {
    xray run -test -format=json -config "$1" >/tmp/vlessextra-xray-test.log 2>&1
}

# Проверяет временный конфиг $1 (итоговое имя $2 — для сообщения). Ничего не применяет.
check_config() {
    xray_test "$1" && return 0
    echo -e "${RED}❌ Xray не принял конфиг ($2):${NC}"
    tail -n 20 /tmp/vlessextra-xray-test.log
    return 1
}

# Применяет оба конфига, только если оба прошли проверку; иначе всё остаётся как было.
commit_configs() {
    local srv_tmp="$XRAY_CFG.new" cli_tmp="$WEB_PATH/.$path_json.new"
    if check_config "$srv_tmp" "$XRAY_CFG" && check_config "$cli_tmp" "$WEB_PATH/$path_json"; then
        mv -f "$srv_tmp" "$XRAY_CFG";             chmod 644 "$XRAY_CFG"
        mv -f "$cli_tmp" "$WEB_PATH/$path_json";  chmod 644 "$WEB_PATH/$path_json"
        return 0
    fi
    rm -f "$srv_tmp" "$cli_tmp"
    echo -e "${RED}   Конфиги НЕ применены, оставлены прежние.${NC}"
    return 1
}

# Проверка, что домен указывает на этот сервер.
check_domain() {
    local v4 v6
    v4=$(getent ahostsv4 "$DOMAIN" | awk '{print $1}' | sort -u)
    if ! grep -qxF "$SERVER_IP" <<< "$v4"; then
        echo -e "${RED}❌ $DOMAIN резолвится в: ${v4:-ничего}${NC}"
        echo -e "${RED}   а IP сервера: $SERVER_IP. Пропиши A-запись и дождись обновления DNS.${NC}"
        exit 1
    fi
    if [ "$(wc -l <<< "$v4")" -gt 1 ]; then
        echo -e "${YEL}⚠️  у $DOMAIN несколько A-записей:${NC}\n$v4\n${YEL}   Оставь только $SERVER_IP.${NC}"
    fi
    v6=$(getent ahostsv6 "$DOMAIN" | awk '{print $1}' | grep -v '^::ffff:' | sort -u)
    if [ -n "$v6" ]; then
        echo -e "${YEL}⚠️  у $DOMAIN есть AAAA-запись ($v6).${NC}"
        echo -e "${YEL}   Если она не на этот сервер — удали её: Let's Encrypt проверяет и по IPv6.${NC}"
    fi
    echo -e "${GRN}✅ $DOMAIN → $SERVER_IP${NC}"
}

detect_nginx_conf() {
    if [ -f /etc/nginx/sites-available/default ]; then
        CONFIG_PATH="/etc/nginx/sites-available/default"
    else
        CONFIG_PATH="/etc/nginx/conf.d/default.conf"
    fi
}

# Синтаксис HTTP/2 зависит от версии nginx (директива "http2 on;" — с 1.25.1).
nginx_http2_opts() {
    local v
    v=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
    if [ -n "$v" ] && [ "$(printf '%s\n' 1.25.1 "$v" | sort -V | head -n1)" = "1.25.1" ]; then
        H2_LISTEN="";       H2_DIRECTIVE="    http2 on;"
    else
        H2_LISTEN=" http2"; H2_DIRECTIVE=""
    fi
}

# $1 = acme — только порт 80 (для выпуска сертификата);
# $1 = full — порт 80 + TLS-сайт на 127.0.0.1:NGINX_TLS_PORT.
gen_nginx_config() {
    detect_nginx_conf
    nginx_http2_opts
    {
    cat <<EOF
server {
    listen 80 default_server;
    server_name _;
    location ^~ /.well-known/acme-challenge/ { root $ACME_PATH; default_type text/plain; }
    location / { return 301 https://$DOMAIN\$request_uri; }
}
EOF
    if [ "$1" = "full" ]; then
    cat <<EOF

server {
    listen 127.0.0.1:$NGINX_TLS_PORT ssl$H2_LISTEN default_server;
$H2_DIRECTIVE
    server_name $DOMAIN;
    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    root $WEB_PATH;
    index index.html;
    location ~ /\. { deny all; }
}
EOF
    fi
    } > "$CONFIG_PATH"
}

apply_nginx() {
    if nginx -t >/tmp/vlessextra-nginx-test.log 2>&1; then
        systemctl reload nginx 2>/dev/null || systemctl restart nginx
    else
        echo -e "${RED}❌ nginx не принял конфиг:${NC}"
        cat /tmp/vlessextra-nginx-test.log
        return 1
    fi
}

# Выпускает сертификат, если его ещё нет, и ставит хук перезагрузки nginx при продлении.
ensure_cert() {
    if [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
        mkdir -p "$ACME_PATH"
        gen_nginx_config acme
        apply_nginx || return 1
        local mail_opt=(--register-unsafely-without-email)
        [ -n "$EMAIL" ] && mail_opt=(-m "$EMAIL")
        echo -e "${YEL}Выпуск сертификата Let's Encrypt для $DOMAIN...${NC}"
        if ! certbot certonly --webroot -w "$ACME_PATH" -d "$DOMAIN" --cert-name "$DOMAIN" \
                --non-interactive --agree-tos "${mail_opt[@]}"; then
            echo -e "${RED}❌ сертификат не выпущен. Проверь A-запись домена и что TCP 80 открыт (фаервол, панель хостера).${NC}"
            return 1
        fi
    fi
    mkdir -p "$(dirname "$CERT_HOOK")"
    printf '#!/bin/sh\nsystemctl reload nginx\n' > "$CERT_HOOK"
    chmod 755 "$CERT_HOOK"
    echo -e "${GRN}✅ Сертификат для $DOMAIN на месте (автопродление — certbot timer)${NC}"
}

gen_xray_config() {
    mkdir -p "$(dirname "$XRAY_CFG")"
    cat > "$XRAY_CFG.new" <<EOF
{
  "log": { "loglevel": "warning" },
  "dns": {
    "servers": [ "$DNS_SERVER" ],
    "queryStrategy": "UseIPv4"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": $XRAY_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$UUID", "flow": "xtls-rprx-vision" } ],
        "decryption": "$VLESS_DEC"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": { "path": "/$XHTTP_PATH", "mode": "auto" },
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "127.0.0.1:$NGINX_TLS_PORT",
          "xver": 0,
          "serverNames": ["$DOMAIN"],
          "privateKey": "$PRIV",
          "shortIds": ["$SHORTID"]
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom", "settings": { "targetStrategy": "UseIPv4" } },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "block" }
    ]
  }
}
EOF
}

# Делит CLIENT_DIRECT на правила по домену и по IP (пустые правила не создаются).
build_client_direct_rules() {
    local item dom="" ip="" rules=""
    for item in "${CLIENT_DIRECT[@]}"; do
        [ -z "$item" ] && continue
        if [[ "$item" == geoip:* || "$item" == ext-ip:* \
           || "$item" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ \
           || "$item" =~ ^[0-9a-fA-F]*:[0-9a-fA-F:.]*(/[0-9]{1,3})?$ ]]; then
            ip+="\"$item\", "
        else
            dom+="\"$item\", "
        fi
    done
    [ -n "$dom" ] && rules+=",
      { \"type\": \"field\", \"domain\": [${dom%, }], \"outboundTag\": \"direct\" }"
    [ -n "$ip" ] && rules+=",
      { \"type\": \"field\", \"ip\": [${ip%, }], \"outboundTag\": \"direct\" }"
    printf '%s' "$rules"
}

gen_client_json() {
    local tmp="$WEB_PATH/.$path_json.new"
    cat > "$tmp" <<EOF
{
  "dns": {
    "servers": [ "$CLIENT_DNS_SERVER" ],
    "queryStrategy": "UseIPv4"
  },
  "inbounds": [
    { "tag": "socks", "listen": "127.0.0.1", "port": 10808, "protocol": "socks", "settings": { "udp": true }, "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] } },
    { "tag": "http", "listen": "127.0.0.1", "port": 10809, "protocol": "http" }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "vnext": [ { "address": "$SERVER_IP", "port": $XRAY_PORT, "users": [
          { "id": "$UUID", "encryption": "$VLESS_ENC", "flow": "xtls-rprx-vision" }
        ] } ]
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "path": "/$XHTTP_PATH",
          "mode": "auto",
          "extra": { "xmux": { "maxConnections": $XMUX_MAX_CONN } }
        },
        "security": "reality",
        "realitySettings": { "serverName": "$DOMAIN", "fingerprint": "chrome", "publicKey": "$PUB", "shortId": "$SHORTID", "spiderX": "" }
      }
    },
    { "tag": "direct", "protocol": "freedom", "settings": { "targetStrategy": "UseIPv4" } },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "$CLIENT_ROUTING_STRATEGY",
    "rules": [
      { "type": "field", "protocol": ["bittorrent"], "outboundTag": "direct" },
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "direct" }$(build_client_direct_rules)
    ]
  }
}
EOF
}

gen_link() {
    local extra
    extra=$(urlencode "{\"xmux\":{\"maxConnections\":$XMUX_MAX_CONN}}")
    linkVL="vless://${UUID}@${SERVER_IP}:${XRAY_PORT}?encryption=$(urlencode "$VLESS_ENC")&flow=xtls-rprx-vision&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${PUB}&sid=${SHORTID}&type=xhttp&path=$(urlencode "/$XHTTP_PATH")&mode=auto&extra=${extra}#$(urlencode "$PROXY_NAME")"
}

gen_html() {
    local link_html
    link_html=$(html_escape "$linkVL")
    cat > "$WEB_PATH/$path_page" <<EOF
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0">
<meta name="robots" content="noindex,nofollow">
<title>Configs</title>
<script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script>
<style>
  *{box-sizing:border-box}
  body{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;background:#121212;color:#e0e0e0;margin:0;padding:40px 24px;display:flex;justify-content:center;align-items:center;min-height:100vh}
  .wrap{width:100%;max-width:1400px}
  .block{border-radius:14px;padding:16px;margin-bottom:20px;border:1px solid #97ff00;background:#10180a}
  .block .head{font-size:16px;line-height:1.55;margin:2px 4px 14px;color:#cfefa6}
  .block .head .t{font-weight:700;font-size:17px;display:block;margin-bottom:4px}
  .block .head b{color:#97ff00}
  .row{background:#1e1e1e;border:1px solid #333;border-radius:10px;padding:14px;display:flex;flex-wrap:wrap;align-items:center;gap:14px;margin-bottom:14px}
  .block .row:last-child{margin-bottom:0}
  .label{background:#2c2c2c;color:#97ff00;padding:14px 22px;border-radius:8px;font-weight:700;font-size:20px;white-space:nowrap;letter-spacing:.5px}
  .code{flex:1;min-width:200px;white-space:nowrap;overflow-x:auto;padding:16px 18px;background:#0e0e0e;border-radius:8px;color:#97ff00;font-size:18px;scrollbar-width:none}
  .code::-webkit-scrollbar{display:none}
  .btn{border:1px solid #555;border-radius:8px;cursor:pointer;font-weight:700;font-size:18px;padding:14px 24px;min-width:80px;height:54px;display:flex;align-items:center;justify-content:center;transition:all .15s;text-decoration:none}
  .open{background:#333;color:#e0e0e0}
  .open:hover{background:#c3e88d;color:#121212;border-color:#c3e88d}
  .qr{background:#333;color:#97ff00;border-color:#97ff00}
  .qr:hover{background:#97ff00;color:#121212}
  .modal{display:none;position:fixed;inset:0;background:rgba(0,0,0,.88);z-index:999;justify-content:center;align-items:center;backdrop-filter:blur(4px)}
  .modal-inner{background:#1e1e1e;padding:28px;border-radius:14px;border:1px solid #97ff00;text-align:center}
  #qrcode{background:#fff;padding:16px;border-radius:10px;margin-bottom:16px}
  .close{background:#c31e1e;color:#fff;border:none;padding:12px 28px;border-radius:8px;cursor:pointer;font-size:16px}
  @media(max-width:760px){body{padding:20px 12px}.label{font-size:16px;width:100%;text-align:center}.code{font-size:14px;width:100%;order:3}.btn{flex:1;order:2;font-size:16px;padding:12px 18px;height:48px}}
</style>
<script>
function showQR(id){const t=document.getElementById(id).innerText;const m=document.getElementById("qrModal");const n=document.getElementById("qrcode");n.innerHTML="";new QRCode(n,{text:t,width:320,height:320,correctLevel:QRCode.CorrectLevel.L});m.style.display="flex";}
function closeModal(){document.getElementById("qrModal").style.display="none";}
window.onclick=function(e){if(e.target===document.getElementById("qrModal"))closeModal();};
</script>
</head>
<body>
<div class="wrap">
  <div class="block">
    <div class="head">
      <span class="t">Клиенты на ядре Xray (нужна поддержка VLESS Encryption и XHTTP)</span>
      <b>HAPP</b>, <b>v2RayTun</b>, <b>OneXray</b>, <b>v2rayN</b> и подобные. <b>JSON</b> — роутинг, DNS и xmux уже настроены. По <b>Ссылке / QR</b> роутинг настраиваешь сам; xmux передаётся в параметре <b>extra</b> (работает, если клиент его читает).
    </div>
    <div class="row">
      <div class="label">JSON</div>
      <div class="code" id="c3">https://$DOMAIN/$path_json</div>
      <a class="btn open" href="https://$DOMAIN/$path_json" target="_blank" rel="noopener">Open</a>
      <a class="btn qr" href="https://$DOMAIN/$path_json" download="vlessextra.json">Download</a>
    </div>
    <div class="row">
      <div class="label">Ссылка</div>
      <div class="code" id="c1">$link_html</div>
      <button class="btn qr" onclick="showQR('c1')">QR</button>
    </div>
  </div>
</div>
<div id="qrModal" class="modal">
  <div class="modal-inner">
    <div id="qrcode"></div>
    <button class="close" onclick="closeModal()">Close</button>
  </div>
</div>
</body>
</html>
EOF
}

gen_masking_site() {
    cat > "$WEB_PATH/index.html" <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>Welcome</title>
<style>
  *{box-sizing:border-box;margin:0;padding:0}
  body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;color:#2d3748;background:#f7fafc;line-height:1.6}
  header{background:#fff;border-bottom:1px solid #e2e8f0;padding:18px 0}
  .wrap{max-width:880px;margin:0 auto;padding:0 24px}
  nav a{color:#4a5568;text-decoration:none;margin-left:24px;font-size:15px}
  .brand{font-weight:700;font-size:20px;color:#2b6cb0}
  .hero{padding:88px 0 56px}
  .hero h1{font-size:38px;margin-bottom:16px;color:#1a202c}
  .hero p{font-size:18px;color:#4a5568;max-width:560px}
  .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:24px;padding:24px 0 80px}
  .card{background:#fff;border:1px solid #e2e8f0;border-radius:10px;padding:24px}
  .card h3{font-size:17px;margin-bottom:8px;color:#1a202c}
  .card p{font-size:14px;color:#718096}
  footer{border-top:1px solid #e2e8f0;padding:24px 0;color:#a0aec0;font-size:13px}
</style>
</head>
<body>
<header><div class="wrap" style="display:flex;justify-content:space-between;align-items:center">
  <span class="brand">Acme</span>
  <nav><a href="#">Home</a><a href="#">Docs</a><a href="#">Pricing</a><a href="#">Contact</a></nav>
</div></header>
<main class="wrap">
  <section class="hero">
    <h1>Build faster. Ship sooner.</h1>
    <p>A lightweight platform for teams who want to focus on their product instead of their infrastructure.</p>
  </section>
  <section class="grid">
    <div class="card"><h3>Reliable</h3><p>99.9% uptime backed by a global edge network.</p></div>
    <div class="card"><h3>Simple</h3><p>Get started in minutes with sane defaults out of the box.</p></div>
    <div class="card"><h3>Secure</h3><p>Modern TLS and best-practice configuration by default.</p></div>
  </section>
</main>
<footer><div class="wrap">© <span id="y"></span> Acme. All rights reserved.</div></footer>
<script>document.getElementById('y').textContent=new Date().getFullYear();</script>
</body>
</html>
EOF
}

# Убирает то, что осталось от старых версий скрипта (Clash .yml с ключами на веб-странице).
cleanup_legacy() {
    if [ -n "$path_yml" ] && [ -f "$WEB_PATH/$path_yml" ]; then
        rm -f "$WEB_PATH/$path_yml"
        echo -e "${YEL}Удалён старый Clash-конфиг $WEB_PATH/$path_yml${NC}"
    fi
    unset path_yml WARP_PRIV WARP_V6
}

open_ufw() {
    if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
        ufw allow "$XRAY_PORT"/tcp >/dev/null
        ufw allow 80/tcp >/dev/null
        echo -e "${GRN}✅ ufw: открыты $XRAY_PORT/tcp, 80/tcp${NC}"
    fi
}

print_status() {
    echo -e "\n${YEL}=== Статус ===${NC}"
    if systemctl is-active --quiet nginx; then echo -e "Nginx: ${GRN}RUNNING${NC}"; else echo -e "Nginx: ${RED}STOPPED${NC}"; fi
    if systemctl is-active --quiet xray;  then echo -e "Xray:  ${GRN}RUNNING${NC}"; else echo -e "Xray:  ${RED}STOPPED (см. journalctl -u xray -e)${NC}"; fi
}

print_summary() {
    echo -e "
${YEL}Страница с конфигами:${NC}
${GRN}https://$DOMAIN/$path_page${NC}

${YEL}Сервер:${NC} $SERVER_IP:$XRAY_PORT  ${YEL}SNI:${NC} $DOMAIN  ${YEL}path:${NC} /$XHTTP_PATH
${YEL}Reality target:${NC} 127.0.0.1:$NGINX_TLS_PORT  ${YEL}DNS:${NC} $DNS_SERVER
"
}

# ═══════════════════════════ UPDATE ═══════════════════════════
if [ "$1" = "update" ]; then
    echo -e "${YEL}=== Режим обновления конфигов ===${NC}"
    # шапка важнее state
    _DOMAIN="$DOMAIN"; _EMAIL="$EMAIL"; _PORT="$XRAY_PORT"; _NGX="$NGINX_TLS_PORT"; _XMUX="$XMUX_MAX_CONN"; _NAME="$PROXY_NAME"
    load_state
    DOMAIN="$_DOMAIN"; EMAIL="$_EMAIL"; XRAY_PORT="$_PORT"; NGINX_TLS_PORT="$_NGX"; XMUX_MAX_CONN="$_XMUX"; PROXY_NAME="$_NAME"
    check_settings
    cleanup_legacy
    command -v xray >/dev/null || { echo -e "${RED}❌ xray не найден. Сначала установка.${NC}"; exit 1; }
    command -v certbot >/dev/null || apt-get install -y certbot || { echo -e "${RED}❌ не удалось поставить certbot${NC}"; exit 1; }
    mkdir -p "$WEB_PATH"
    [ -z "$path_json" ]  && path_json="$(rand_name).json"
    [ -z "$path_page" ]  && path_page="$(rand_name).html"
    [ -z "$XHTTP_PATH" ] && XHTTP_PATH="$(rand_name)"
    if [ -z "$ENC_PRIV" ] || [ -z "$ENC_PASS" ]; then
        read -r ENC_PRIV ENC_PASS <<< "$(x25519_pair)"
        [ -n "$ENC_PASS" ] || { echo -e "${RED}❌ не удалось сгенерировать ключи VLESS Encryption${NC}"; exit 1; }
    fi
    [ -f "$WEB_PATH/index.html" ] || gen_masking_site

    check_domain
    open_ufw
    ensure_cert || exit 1

    gen_enc_strings
    gen_xray_config
    gen_client_json
    commit_configs || exit 1
    gen_nginx_config full
    apply_nginx || exit 1
    gen_link
    gen_html
    save_state

    systemctl restart xray
    sleep 1

    echo -e "${GRN}✅ Конфиги пересобраны (ключи и UUID сохранены)${NC}"
    print_status
    print_summary
    exit 0
fi

# ═══════════════════════════ INSTALL ═══════════════════════════
check_settings

echo -e "${YEL}Обновление и установка пакетов...${NC}"
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
apt-get update
apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade -y
apt-get install -y curl openssl nginx certbot || { echo -e "${RED}❌ не удалось поставить пакеты${NC}"; exit 1; }
systemctl enable --now nginx

cat > /etc/sysctl.d/999-vlessextra.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
sysctl --system >/dev/null
echo -e "${GRN}BBR применён${NC}"

SERVER_IP=""
for url in https://api.ipify.org https://ifconfig.me https://icanhazip.com; do
    SERVER_IP=$(curl -fs4 --max-time 5 "$url" | tr -d '[:space:]')
    [[ "$SERVER_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && break
    SERVER_IP=""
done
[ -z "$SERVER_IP" ] && { echo -e "${RED}❌ не удалось определить публичный IPv4 сервера${NC}"; exit 1; }
echo -e "${GRN}IP сервера: $SERVER_IP${NC}"

check_domain
open_ufw

mkdir -p "$WEB_PATH"
gen_masking_site
ensure_cert || exit 1

XRAY_INSTALLER=$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)
[ -n "$XRAY_INSTALLER" ] || { echo -e "${RED}❌ не скачался установщик Xray (DNS/сеть до GitHub?). Проверь getent hosts github.com${NC}"; exit 1; }
bash -c "$XRAY_INSTALLER" @ install
if ! command -v xray >/dev/null; then
    echo -e "${RED}❌ Xray не установился (DNS/сеть до GitHub?). Проверь getent hosts github.com${NC}"
    exit 1
fi
echo -e "${GRN}✅ Xray установлен: $(xray version | head -n1)${NC}"

UUID=$(cat /proc/sys/kernel/random/uuid)
read -r PRIV PUB <<< "$(x25519_pair)"
[ -n "$PUB" ] || { echo -e "${RED}❌ не удалось получить ключи Reality из 'xray x25519'${NC}"; xray x25519; exit 1; }
read -r ENC_PRIV ENC_PASS <<< "$(x25519_pair)"
[ -n "$ENC_PASS" ] || { echo -e "${RED}❌ не удалось получить ключи VLESS Encryption из 'xray x25519'${NC}"; exit 1; }
SHORTID=$(openssl rand -hex 8)
XHTTP_PATH="$(rand_name)"
path_page="$(rand_name).html"
path_json="$(rand_name).json"

gen_enc_strings
gen_xray_config
gen_client_json
commit_configs || exit 1

gen_nginx_config full
apply_nginx || exit 1
echo -e "${GRN}✅ Nginx: :80 (ACME + редирект), 127.0.0.1:$NGINX_TLS_PORT (сайт, TLS)${NC}"

systemctl enable xray
systemctl restart xray
sleep 1
if systemctl is-active --quiet xray; then
    echo -e "${GRN}✅ Xray настроен (VLESS+XHTTP+Reality на TCP $XRAY_PORT)${NC}"
else
    echo -e "${RED}❌ Xray не стартовал: journalctl -u xray -e --no-pager | tail -20${NC}"
fi

gen_link
gen_html

save_state
echo -e "${GRN}✅ Состояние сохранено в $STATE_FILE${NC}"

print_status
print_summary