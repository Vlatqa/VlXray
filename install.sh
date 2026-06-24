#!/bin/bash
# Vless Extra — VLESS + Reality + Vision (TCP) на Xray-core + WARP

GRN='\033[1;32m'
RED='\033[1;31m'
YEL='\033[1;33m'
NC='\033[0m'

[[ $EUID -eq 0 ]] || { echo -e "${RED}❌ нужен root${NC}"; exit 1; }

XRAY_CFG=/usr/local/etc/xray/config.json
STATE_FILE=/usr/local/etc/xray/.vlessextra.env
WEB_PATH=/var/www/vless

REALITY_DEST="www.microsoft.com"
REALITY_SNI="www.microsoft.com"
XRAY_PORT=443
PROXY_NAME="VlessExtra"

# Категории/домены для WARP (синтаксис Xray: geosite:/domain:).
WARP_GEO=(
###Черные списки:
#################
#  "geosite:category-ip-geo-detect"
#  "geosite:telegram"
#  "geoip:telegram"
#  "geosite:reddit"

###Белые списки:
################
    "geosite:telegram"
    "geoip:telegram"
    "geosite:alphabet"
#    "geosite:category-ai-!cn"
    "domain:metal-tracker.com"
    "domain:voidboost.cc"
    "domain:sambray.org"
    "domain:alicdn.com"
    "domain:ixbt.com"
)

# ─────────── РЕЖИМ WARP: раскомментируй ОДИН вариант ───────────
# 1) всё через WARP:
#WARP_MODE="all"
# 2) через WARP только домены/категории из WARP_GEO:
#WARP_MODE="domains"
# 3) через WARP всё, КРОМЕ доменов/категорий из WARP_GEO:
#WARP_MODE="all-except"
# 4) WARP выключен, весь трафик прямым IP сервера:
WARP_MODE="off"
# ───────────────────────────────────────────────────────────────

save_state() {
    mkdir -p "$(dirname "$STATE_FILE")"
    cat > "$STATE_FILE" <<EOF
SERVER_IP="$SERVER_IP"
UUID="$UUID"
PRIV="$PRIV"
PUB="$PUB"
SHORTID="$SHORTID"
REALITY_DEST="$REALITY_DEST"
REALITY_SNI="$REALITY_SNI"
XRAY_PORT="$XRAY_PORT"
PROXY_NAME="$PROXY_NAME"
path_page="$path_page"
path_yml="$path_yml"
path_json="$path_json"
WARP_PRIV="$WARP_PRIV"
WARP_V6="$WARP_V6"
EOF
    chmod 600 "$STATE_FILE"
}

load_state() {
    [ -f "$STATE_FILE" ] || { echo -e "${RED}❌ state-файл $STATE_FILE не найден. Сначала установка.${NC}"; exit 1; }
    # shellcheck disable=SC1090
    source "$STATE_FILE"
}

detect_nginx_conf() {
    if [ -f /etc/nginx/sites-available/default ]; then
        CONFIG_PATH="/etc/nginx/sites-available/default"
    else
        CONFIG_PATH="/etc/nginx/conf.d/default.conf"
    fi
}

gen_xray_config() {
    mkdir -p "$(dirname "$XRAY_CFG")"
    local mode="${WARP_MODE:-off}" addr warp_ob dom_json outbounds
    local routing='"routing": { "rules": [] }'
    local freedom='{ "protocol": "freedom", "tag": "direct", "settings": { "domainStrategy": "UseIPv4" } }'
    [ -z "$WARP_PRIV" ] && mode="off"

    if [ "$mode" != "off" ]; then
        warp_ob="{ \"protocol\": \"wireguard\", \"tag\": \"warp\", \"settings\": { \"secretKey\": \"$WARP_PRIV\", \"address\": [\"172.16.0.2/32\"], \"peers\": [ { \"publicKey\": \"bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=\", \"endpoint\": \"162.159.192.1:2408\", \"allowedIPs\": [\"0.0.0.0/0\"] } ], \"mtu\": 1280 } }"
        dom_json=$(printf '"%s",' "${WARP_GEO[@]}" | sed 's/,$//')
    fi

    case "$mode" in
        all)
            outbounds="    $warp_ob,
    $freedom,
    { \"protocol\": \"blackhole\", \"tag\": \"block\" }"
            ;;
        all-except)
            outbounds="    $warp_ob,
    $freedom,
    { \"protocol\": \"blackhole\", \"tag\": \"block\" }"
            routing="\"routing\": { \"domainStrategy\": \"AsIs\", \"rules\": [ { \"type\": \"field\", \"domain\": [$dom_json], \"outboundTag\": \"direct\" } ] }"
            ;;
        domains)
            outbounds="    $freedom,
    $warp_ob,
    { \"protocol\": \"blackhole\", \"tag\": \"block\" }"
            routing="\"routing\": { \"domainStrategy\": \"AsIs\", \"rules\": [ { \"type\": \"field\", \"domain\": [$dom_json], \"outboundTag\": \"warp\" } ] }"
            ;;
        *)
            outbounds="    $freedom,
    { \"protocol\": \"blackhole\", \"tag\": \"block\" }"
            ;;
    esac

    cat > "$XRAY_CFG" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": $XRAY_PORT,
      "protocol": "vless",
      "settings": { "clients": [ { "id": "$UUID", "flow": "xtls-rprx-vision" } ], "decryption": "none" },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": { "show": false, "dest": "$REALITY_DEST:443", "xver": 0, "serverNames": ["$REALITY_SNI"], "privateKey": "$PRIV", "shortIds": ["$SHORTID"] }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    }
  ],
  "outbounds": [
$outbounds
  ],
  $routing
}
EOF
}

gen_nginx_config() {
    detect_nginx_conf
    cat > "$CONFIG_PATH" <<EOF
server {
    listen 80 default_server;
    server_name _;
    root $WEB_PATH;
    index index.html;
    location ~ /\.ht { deny all; }
}
EOF
}

gen_clash_config() {
    cat > "$WEB_PATH/$path_yml" <<EOF
mixed-port: 7890
allow-lan: false
mode: rule
log-level: warning
ipv6: false

tun:
  enable: true
  stack: gvisor
  device: Mihomo
  auto-route: true
  strict-route: false
  auto-detect-interface: true
  dns-hijack:
    - "any:53"
  mtu: 1400

dns:
  enable: true
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter:
    - "+.lan"
    - "+.local"
    - "+.internal"
    - "geosite:category-ru"
  nameserver:
    - system

proxies:
  - name: "$PROXY_NAME"
    type: vless
    server: $SERVER_IP
    port: $XRAY_PORT
    uuid: $UUID
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: $REALITY_SNI
    client-fingerprint: chrome
    reality-opts:
      public-key: $PUB
      short-id: $SHORTID

proxy-groups:
  - name: "PROXY"
    type: select
    proxies:
      - "$PROXY_NAME"
      - DIRECT

rules:
  - PROCESS-NAME,qBittorrent.exe,DIRECT
  - GEOIP,private,DIRECT,no-resolve
  - GEOSITE,category-ru,DIRECT
  - MATCH,PROXY
EOF
}

gen_client_json() {
    cat > "$WEB_PATH/$path_json" <<EOF
{
  "inbounds": [
    { "tag": "socks", "listen": "127.0.0.1", "port": 10808, "protocol": "socks", "settings": { "udp": true }, "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] } },
    { "tag": "http", "listen": "127.0.0.1", "port": 10809, "protocol": "http" }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": { "vnext": [ { "address": "$SERVER_IP", "port": $XRAY_PORT, "users": [ { "id": "$UUID", "encryption": "none", "flow": "xtls-rprx-vision" } ] } ] },
      "streamSettings": { "network": "tcp", "security": "reality", "realitySettings": { "serverName": "$REALITY_SNI", "fingerprint": "chrome", "publicKey": "$PUB", "shortId": "$SHORTID", "spiderX": "" } }
    },
    { "tag": "direct", "protocol": "freedom", "settings": { "domainStrategy": "UseIPv4" } },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "protocol": ["bittorrent"], "outboundTag": "direct" },
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "direct" },
      { "type": "field", "domain": ["geosite:category-ru"], "outboundTag": "direct" }
    ]
  }
}
EOF
}

gen_link() {
    linkVL="vless://${UUID}@${SERVER_IP}:${XRAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${PUB}&sid=${SHORTID}&type=tcp&headerType=none#${PROXY_NAME}"
}

gen_html() {
    cat > "$WEB_PATH/$path_page" <<EOF
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0">
<meta name="robots" content="noindex,nofollow">
<title>VLESS</title>
<script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script>
<style>
  *{box-sizing:border-box}
  body{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;background:#121212;color:#e0e0e0;margin:0;padding:40px 24px;display:flex;justify-content:center;align-items:center;min-height:100vh}
  .wrap{width:100%;max-width:1400px}
  .block{border-radius:14px;padding:16px;margin-bottom:20px;border:1px solid #333}
  .block.recb{border-color:#97ff00;background:#10180a}
  .block.norecb{border-color:#444;background:#161616}
  .block .head{font-size:16px;line-height:1.55;margin:2px 4px 14px}
  .block.recb .head{color:#cfefa6}
  .block.norecb .head{color:#9a9a9a}
  .block .head .t{font-weight:700;font-size:17px;display:block;margin-bottom:4px}
  .block.recb .head b{color:#97ff00}
  .block.norecb .head b{color:#d0d0d0}
  .row{background:#1e1e1e;border:1px solid #333;border-radius:10px;padding:14px;display:flex;flex-wrap:wrap;align-items:center;gap:14px;margin-bottom:14px}
  .block .row:last-child{margin-bottom:0}
  .label{background:#2c2c2c;color:#97ff00;padding:14px 22px;border-radius:8px;font-weight:700;font-size:20px;white-space:nowrap;letter-spacing:.5px}
  .code{flex:1;min-width:200px;white-space:nowrap;overflow-x:auto;padding:16px 18px;background:#0e0e0e;border-radius:8px;color:#97ff00;font-size:18px;scrollbar-width:none}
  .code::-webkit-scrollbar{display:none}
  .btn{border:1px solid #555;border-radius:8px;cursor:pointer;font-weight:700;font-size:18px;padding:14px 24px;min-width:80px;height:54px;display:flex;align-items:center;justify-content:center;transition:all .15s;text-decoration:none}
  .copy{background:#333;color:#e0e0e0}
  .copy:hover{background:#c3e88d;color:#121212;border-color:#c3e88d}
  .qr{background:#333;color:#97ff00;border-color:#97ff00}
  .qr:hover{background:#97ff00;color:#121212}
  .modal{display:none;position:fixed;inset:0;background:rgba(0,0,0,.88);z-index:999;justify-content:center;align-items:center;backdrop-filter:blur(4px)}
  .modal-inner{background:#1e1e1e;padding:28px;border-radius:14px;border:1px solid #97ff00;text-align:center}
  #qrcode{background:#fff;padding:16px;border-radius:10px;margin-bottom:16px}
  .close{background:#c31e1e;color:#fff;border:none;padding:12px 28px;border-radius:8px;cursor:pointer;font-size:16px}
  @media(max-width:760px){body{padding:20px 12px}.label{font-size:16px;width:100%;text-align:center}.code{font-size:14px;width:100%;order:3}.btn{flex:1;order:2;font-size:16px;padding:12px 18px;height:48px}}
</style>
<script>
function copyText(id,btn){navigator.clipboard.writeText(document.getElementById(id).innerText).then(()=>{const o=btn.innerText;btn.innerText="OK";btn.style.cssText="background:#c3e88d;color:#121212;border-color:#c3e88d";setTimeout(()=>{btn.innerText=o;btn.style.cssText="";},1500);});}
function showQR(id){const t=document.getElementById(id).innerText;const m=document.getElementById("qrModal");const n=document.getElementById("qrcode");n.innerHTML="";new QRCode(n,{text:t,width:320,height:320,correctLevel:QRCode.CorrectLevel.L});m.style.display="flex";}
function closeModal(){document.getElementById("qrModal").style.display="none";}
window.onclick=function(e){if(e.target===document.getElementById("qrModal"))closeModal();};
</script>
</head>
<body>
<div class="wrap">
  <div class="block recb">
    <div class="head">
      <span class="t">✓ Рекомендуется — клиент на ядре Mihomo / Clash</span>
      Android — <b>Clash Meta</b>, iOS — <b>Clash Mi</b>, ПК — <b>Clash Verge</b>. Импортируй конфиг ниже и просто включи — роутинг уже настроен.
    </div>
    <div class="row">
      <div class="label">Clash</div>
      <div class="code" id="c2">http://$SERVER_IP/$path_yml</div>
      <button class="btn copy" onclick="copyText('c2',this)">Copy</button>
      <button class="btn qr"   onclick="showQR('c2')">QR</button>
    </div>
  </div>
  <div class="block norecb">
    <div class="head">
      <span class="t">✕ Не рекомендуется — клиент на ядре Xray / sing-box</span>
      <b>HAPP</b>, <b>v2RayTun</b>, <b>OneXray</b> и подобные. По <b>Ссылке / QR</b> роутинг настраиваешь сам; <b>JSON</b> - роутинг уже настроен.
    </div>
    <div class="row">
      <div class="label">Ссылка</div>
      <div class="code" id="c1">$linkVL</div>
      <button class="btn copy" onclick="copyText('c1',this)">Copy</button>
      <button class="btn qr"   onclick="showQR('c1')">QR</button>
    </div>
    <div class="row">
      <div class="label">JSON</div>
      <div class="code" id="c3">http://$SERVER_IP/$path_json</div>
      <a class="btn copy" href="http://$SERVER_IP/$path_json" target="_blank" rel="noopener">Open</a>
      <a class="btn qr" href="http://$SERVER_IP/$path_json" download="vlessextra.json">Download</a>
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

print_summary() {
    echo -e "
${YEL}Страница с конфигами:${NC}
${GRN}http://$SERVER_IP/$path_page${NC}

${YEL}Сервер:${NC} $SERVER_IP:$XRAY_PORT  ${YEL}SNI:${NC} $REALITY_SNI  ${YEL}WARP:${NC} ${WARP_MODE}
"
}

if [ "$1" = "update" ]; then
    echo -e "${YEL}=== Режим обновления конфигов ===${NC}"
    _DEST="$REALITY_DEST"; _SNI="$REALITY_SNI"; _PORT="$XRAY_PORT"; _NAME="$PROXY_NAME"
    load_state
    REALITY_DEST="$_DEST"; REALITY_SNI="$_SNI"; XRAY_PORT="$_PORT"; PROXY_NAME="$_NAME"
    # для старых state-файлов, где ещё нет path_json — создаём
    [ -z "$path_json" ] && path_json=$(openssl rand -base64 15 | tr -dc 'A-Za-z0-9' | head -c 20).json
    mkdir -p "$WEB_PATH"

    gen_xray_config
    gen_nginx_config
    gen_clash_config
    gen_client_json
    gen_link
    gen_html
    save_state

    if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
        ufw allow "$XRAY_PORT"/tcp >/dev/null
        ufw allow 80/tcp >/dev/null
    fi

    nginx -t && systemctl reload nginx
    systemctl restart xray
    sleep 1

    echo -e "${GRN}✅ Конфиги пересобраны (ключи и UUID сохранены)${NC}"
    echo -e "\n${YEL}=== Статус ===${NC}"
    systemctl is-active --quiet nginx && echo -e "Nginx: ${GRN}RUNNING${NC}" || echo -e "Nginx: ${RED}STOPPED${NC}"
    systemctl is-active --quiet xray  && echo -e "Xray:  ${GRN}RUNNING${NC}" || echo -e "Xray:  ${RED}STOPPED (см. journalctl -u xray -e)${NC}"
    print_summary
    exit 0
fi

echo -e "${YEL}Обновление и установка пакетов...${NC}"
apt-get update && apt-get upgrade -y
apt-get install -y curl jq openssl nginx
systemctl enable --now nginx

cat > /etc/sysctl.d/999-vlessextra.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
sysctl --system >/dev/null
echo -e "${GRN}BBR применён${NC}"

cat > /etc/security/limits.d/99-vlessextra.conf <<EOF
*               soft    nofile          65535
*               hard    nofile          65535
root            soft    nofile          65535
root            hard    nofile          65535
EOF
ulimit -n 65535

SERVER_IP=$(curl -s4 --max-time 5 https://api.ipify.org || curl -s4 --max-time 5 https://ifconfig.me)
[ -z "$SERVER_IP" ] && SERVER_IP=$(hostname -I | awk '{print $1}')
echo -e "${GRN}IP сервера: $SERVER_IP${NC}"

bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
if ! command -v xray >/dev/null; then
    echo -e "${RED}❌ Xray не установился (DNS/сеть до GitHub?). Проверь getent hosts github.com${NC}"
    exit 1
fi
echo -e "${GRN}✅ Xray установлен${NC}"

UUID=$(cat /proc/sys/kernel/random/uuid)
KEYS=$(xray x25519)
PRIV=$(echo "$KEYS" | grep -i 'private' | awk '{print $NF}')
PUB=$(echo  "$KEYS" | grep -i 'public'  | awk '{print $NF}')
SHORTID=$(openssl rand -hex 8)
path_page=$(openssl rand -base64 15 | tr -dc 'A-Za-z0-9' | head -c 20).html
path_yml=$(openssl rand -base64 15 | tr -dc 'A-Za-z0-9' | head -c 20).yml
path_json=$(openssl rand -base64 15 | tr -dc 'A-Za-z0-9' | head -c 20).json

echo -e "${YEL}Настройка WARP-выхода...${NC}"
WARP_ARCH=amd64; [ "$(uname -m)" = "aarch64" ] && WARP_ARCH=arm64
WGCF_VER=$(curl -fsSL https://api.github.com/repos/ViRb3/wgcf/releases/latest | grep -oP '"tag_name":\s*"v\K[^"]+')
if [ -n "$WGCF_VER" ]; then
    curl -fsSL -o /usr/local/bin/wgcf \
        "https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VER}/wgcf_${WGCF_VER}_linux_${WARP_ARCH}" \
        && chmod +x /usr/local/bin/wgcf
    mkdir -p /etc/wgcf && cd /etc/wgcf
    [ -f wgcf-account.toml ] || wgcf register --accept-tos
    wgcf generate 2>/dev/null
    WARP_PRIV=$(grep -i 'PrivateKey' wgcf-profile.conf 2>/dev/null | awk '{print $NF}')
    WARP_V6=$(grep -i '^Address' wgcf-profile.conf 2>/dev/null | grep ':' | awk '{print $NF}')
    cd - >/dev/null
fi
if [ -n "$WARP_PRIV" ]; then
    echo -e "${GRN}✅ WARP готов (режим: ${WARP_MODE})${NC}"
else
    echo -e "${YEL}⚠ WARP не поднялся — ставлю без него (весь трафик через прямой IP)${NC}"
fi

mkdir -p "$WEB_PATH"
gen_masking_site
gen_xray_config
systemctl enable --now xray
systemctl restart xray
sleep 1
if systemctl is-active --quiet xray; then
    echo -e "${GRN}✅ Xray настроен (VLESS+Reality на TCP $XRAY_PORT)${NC}"
else
    echo -e "${RED}❌ Xray не стартовал. Частая причина — нет geosite-категории из WARP_GEO в geosite.dat.${NC}"
    echo -e "${YEL}   journalctl -u xray -e --no-pager | tail -20${NC}"
    echo -e "${YEL}   Если в логе 'failed to load geosite' — замени категорию на явные домены (domain:ip.gs ...).${NC}"
fi

gen_nginx_config
systemctl restart nginx
echo -e "${GRN}✅ Nginx настроен (страница на TCP 80)${NC}"

gen_clash_config
gen_client_json
gen_link
gen_html

if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
    ufw allow "$XRAY_PORT"/tcp >/dev/null
    ufw allow 80/tcp >/dev/null
    echo -e "${GRN}✅ ufw: открыты $XRAY_PORT/tcp, 80/tcp${NC}"
fi

save_state
echo -e "${GRN}✅ Состояние сохранено в $STATE_FILE${NC}"

echo -e "\n${YEL}=== Статус ===${NC}"
systemctl is-active --quiet nginx && echo -e "Nginx: ${GRN}RUNNING${NC}" || echo -e "Nginx: ${RED}STOPPED${NC}"
systemctl is-active --quiet xray  && echo -e "Xray:  ${GRN}RUNNING${NC}" || echo -e "Xray:  ${RED}STOPPED${NC}"
print_summary
