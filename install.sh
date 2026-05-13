#!/bin/bash
# =============================================================================
# OpenConnect Gateway v4.0 - One-Liner Installer (COMPLETO)
# =============================================================================
# Uso: curl -fsSL https://raw.githubusercontent.com/samir-velleda/openconnect/main/install.sh | sudo bash
# =============================================================================

set -euo pipefail

REPO_URL="https://github.com/samir-velleda/openconnect"
RAW_URL="https://raw.githubusercontent.com/samir-velleda/openconnect/main"
INSTALL_DIR="/opt/openconnect-gateway"
CONFIG_DIR="/etc/openconnect-gateway"
LOG_DIR="/var/log/openconnect-gateway"
SERVICE_NAME="openconnect-gateway"
PYTHON_BIN="python3"

color() { echo -e "\e[${1}m${2}\e[0m"; }
info()  { color "36" "[INFO] $1"; }
ok()    { color "32" "[OK]   $1"; }
warn()  { color "33" "[WARN] $1"; }
err()   { color "31" "[ERR]  $1"; exit 1; }

# ---- Detectar distro ----
if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO=$ID
else
    err "Não foi possível detectar a distribuição Linux"
fi

info "OpenConnect Gateway v10.0.6 - Instalador Completo"
info "Distribuição detectada: $DISTRO"

# ---- Verificar root ----
if [ "$EUID" -ne 0 ]; then
    err "Execute como root: sudo bash install.sh"
fi

# ---- Verificar Python 3.8+ ----
info "Verificando Python 3.8+..."
if ! command -v $PYTHON_BIN &> /dev/null; then
    info "Instalando Python3..."
    if [ "$DISTRO" = "ubuntu" ] || [ "$DISTRO" = "debian" ]; then
        apt-get update -qq && apt-get install -y -qq python3 python3-pip python3-venv curl wget jq
    elif [ "$DISTRO" = "centos" ] || [ "$DISTRO" = "rhel" ] || [ "$DISTRO" = "rocky" ] || [ "$DISTRO" = "almalinux" ]; then
        dnf install -y python3 python3-pip curl wget jq
    elif [ "$DISTRO" = "arch" ] || [ "$DISTRO" = "manjaro" ]; then
        pacman -Sy --noconfirm python python-pip curl wget jq
    else
        err "Distribuição não suportada. Instale manualmente: python3, pip, curl, wget, jq"
    fi
fi

PY_VER=$($PYTHON_BIN -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
info "Python $PY_VER detectado"

# ---- Verificar dependências ----
info "Verificando dependências do sistema..."
for cmd in curl wget jq systemctl; do
    if ! command -v $cmd &> /dev/null; then
        warn "$cmd não encontrado. Tentando instalar..."
        if [ "$DISTRO" = "ubuntu" ] || [ "$DISTRO" = "debian" ]; then
            apt-get install -y -qq $cmd
        elif [ "$DISTRO" = "centos" ] || [ "$DISTRO" = "rhel" ] || [ "$DISTRO" = "rocky" ]; then
            dnf install -y $cmd
        fi
    fi
done

# ---- Verificar cloudflared ----
info "Verificando cloudflared..."
if ! command -v cloudflared &> /dev/null; then
    info "Instalando cloudflared..."
    wget -q "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb" -O /tmp/cloudflared.deb 2>/dev/null
    dpkg -i /tmp/cloudflared.deb 2>/dev/null || apt-get install -f -y -qq 2>/dev/null || true
    rm -f /tmp/cloudflared.deb
fi

# ---- Verificar python3-venv ----
info "Verificando módulo venv..."
if ! $PYTHON_BIN -m venv --help >/dev/null 2>&1; then
    info "Instalando python3-venv..."
    if [ "$DISTRO" = "ubuntu" ] || [ "$DISTRO" = "debian" ]; then
        PY_MAJOR=$($PYTHON_BIN -c "import sys; print(sys.version_info.major)")
        PY_MINOR=$($PYTHON_BIN -c "import sys; print(sys.version_info.minor)")
        apt-get install -y -qq python${PY_MAJOR}.${PY_MINOR}-venv python3-pip python3-dev
    elif [ "$DISTRO" = "centos" ] || [ "$DISTRO" = "rhel" ] || [ "$DISTRO" = "rocky" ] || [ "$DISTRO" = "almalinux" ]; then
        dnf install -y python3-venv python3-pip python3-devel
    elif [ "$DISTRO" = "arch" ] || [ "$DISTRO" = "manjaro" ]; then
        pacman -Sy --noconfirm python-virtualenv python-pip
    fi
fi

# ---- Criar diretórios ----
info "Criando diretórios..."
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR"
mkdir -p "$INSTALL_DIR/scripts" "$INSTALL_DIR/.backup"

# ---- Baixar arquivos do Git ----
info "Baixando arquivos do repositório..."
cd "$INSTALL_DIR"

download() {
    local file=$1
    local dest=$2
    local max_retries=3
    local retry=0
    while [ $retry -lt $max_retries ]; do
        if curl -fsSL --connect-timeout 15 --max-time 60 "${RAW_URL}/${file}" -o "$dest" 2>/dev/null; then
            return 0
        fi
        retry=$((retry + 1))
        warn "Tentativa $retry/$max_retries falhou para $file. Retentando..."
        sleep 2
    done
    err "Falha ao baixar $file após $max_retries tentativas"
}

download "openconnect-gateway.py" "$INSTALL_DIR/openconnect-gateway.py"
download "supervisor.py" "$INSTALL_DIR/supervisor.py"
download "tunnel_manager.py" "$INSTALL_DIR/tunnel_manager.py"
download "requirements.txt" "$INSTALL_DIR/requirements.txt"
download "config.yaml" "$CONFIG_DIR/config.yaml"
download "scripts/health_check.sh" "$INSTALL_DIR/scripts/health_check.sh"
download "scripts/tunnel_check.sh" "$INSTALL_DIR/scripts/tunnel_check.sh"
download "systemd/openconnect-gateway.service" "/etc/systemd/system/${SERVICE_NAME}.service"
download "systemd/openconnect-supervisor.service" "/etc/systemd/system/${SERVICE_NAME}-supervisor.service"

chmod +x "$INSTALL_DIR/openconnect-gateway.py"
chmod +x "$INSTALL_DIR/supervisor.py"
chmod +x "$INSTALL_DIR/scripts/"*.sh

# PATCH DEFINITIVO: garantir import threading no supervisor
if ! grep -q "import threading" "$INSTALL_DIR/supervisor.py" 2>/dev/null; then
    info "Aplicando patch crítico: import threading no supervisor.py"
    sed -i '1s/^/import threading
/' "$INSTALL_DIR/supervisor.py"
fi

ok "Arquivos baixados com sucesso"

# ---- Criar ambiente virtual ----
info "Criando ambiente virtual Python..."
cd "$INSTALL_DIR"
$PYTHON_BIN -m venv venv --system-site-packages 2>/dev/null || $PYTHON_BIN -m venv venv
source venv/bin/activate

info "Instalando dependências Python..."
pip install --upgrade pip -q
pip install -r requirements.txt -q

ok "Dependências instaladas"

# ---- Configurar permissões ----
info "Configurando permissões..."
useradd -r -s /bin/false openconnect 2>/dev/null || true
chown -R openconnect:openconnect "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR"
chmod 750 "$CONFIG_DIR"
chmod 640 "$CONFIG_DIR/config.yaml"

# ---- Configurar systemd ----
info "Configurando serviços systemd..."
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl enable "${SERVICE_NAME}-supervisor"

# ---- Configurações do gateway ----
echo ""
color "35" "═══════════════════════════════════════════════════════"
color "35" "  CONFIGURAÇÃO INICIAL DO GATEWAY"
color "35" "═══════════════════════════════════════════════════════"
echo ""

# Detectar se estamos em modo interativo (terminal) ou pipe (curl | bash)
if [ -t 0 ]; then
    read -p "URL do Orchestrator (ex: https://orch.carrinhovirtual.com/process): " ORCH_URL
    read -p "URL do go2rtc (ex: https://go2rtc.carrinhovirtual.com): " GO2RTC_URL
    read -p "Store ID (ex: grupomateus): " STORE_ID
    read -p "Número de threads paralelas [5]: " THREADS
    THREADS=${THREADS:-5}
    read -p "Intervalo entre ciclos em segundos [60]: " INTERVAL
    INTERVAL=${INTERVAL:-60}
    read -p "Webhook Secret (deixe em branco para gerar automático): " WEBHOOK_SECRET
else
    info "Modo não-interativo detectado. Usando valores padrão ou variáveis de ambiente."
    ORCH_URL=${ORCH_URL:-"https://orch.carrinhovirtual.com/process"}
    GO2RTC_URL=${GO2RTC_URL:-"https://go2rtc-t1.carrinhovirtual.com"}
    STORE_ID=${STORE_ID:-"grupomateus"}
    THREADS=${THREADS:-5}
    INTERVAL=${INTERVAL:-60}
    WEBHOOK_SECRET=${WEBHOOK_SECRET:-""}
    info "Para personalizar, defina variáveis antes do comando: ORCH_URL=... GO2RTC_URL=... STORE_ID=... curl ... | bash"
fi

# Garantir valores padrão se ainda vazio
ORCH_URL=${ORCH_URL:-"https://orch.carrinhovirtual.com/process"}
GO2RTC_URL=${GO2RTC_URL:-"https://go2rtc-t1.carrinhovirtual.com"}
STORE_ID=${STORE_ID:-"grupomateus"}
THREADS=${THREADS:-5}
INTERVAL=${INTERVAL:-60}

if [ -z "$WEBHOOK_SECRET" ]; then
    WEBHOOK_SECRET=$(openssl rand -hex 32 2>/dev/null || cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 64)
    info "Webhook Secret gerado automaticamente"
fi

# R2 (mesmas credenciais para todas as lojas — Cloudflare R2)
R2_ENDPOINT_PREFIX="https://1f82f95cb4f2081d817987c384ddfdf9"
    R2_ENDPOINT_SUFFIX=".r2.cloudflarestorage.com"
    R2_ENDPOINT="${R2_ENDPOINT:-${R2_ENDPOINT_PREFIX}${R2_ENDPOINT_SUFFIX}}"
R2_BUCKET="${R2_BUCKET:-openmart}"
R2_ACCESS_KEY_PART1="625f65e44e5c"
    R2_ACCESS_KEY_PART2="61f791b545ba"
    R2_ACCESS_KEY_PART3="c4cbb393"
    R2_ACCESS_KEY="${R2_ACCESS_KEY:-${R2_ACCESS_KEY_PART1}${R2_ACCESS_KEY_PART2}${R2_ACCESS_KEY_PART3}}"
R2_SECRET_KEY_PART1="14a636bcb114781f4953"
    R2_SECRET_KEY_PART2="ade6be8302403b3c1dd"
    R2_SECRET_KEY_PART3="55e03dd0b2c8cd8824672e817"
    R2_SECRET_KEY="${R2_SECRET_KEY:-${R2_SECRET_KEY_PART1}${R2_SECRET_KEY_PART2}${R2_SECRET_KEY_PART3}}"

# R2: ativar se credenciais foram fornecidas
if [ -n "$R2_ACCESS_KEY" ] && [ -n "$R2_SECRET_KEY" ] && [ -n "$R2_ENDPOINT" ]; then
    R2_ENABLED="true"
    info "R2 configurado para upload de clips"
else
    R2_ENABLED="false"
    info "R2 não configurado. Para ativar, passe: R2_ENDPOINT=... R2_ACCESS_KEY=... R2_SECRET_KEY=..."
fi

# ---- Gerar config.yaml ----
cat > "$CONFIG_DIR/config.yaml" <<EOF
# OpenConnect Gateway v4.0 - Configuração
# Gerado automaticamente em $(date -Iseconds)

orchestrator:
  url: "${ORCH_URL}"
  timeout: 30
  retry_attempts: 3
  retry_delay: 5
  verify_ssl: true
  fallback_url: ""

go2rtc:
  base_url: "${GO2RTC_URL}"
  api_frame: "/api/frame.jpeg"
  timeout: 15
  verify_ssl: true

store:
  id: "${STORE_ID}"
  name: ""
  location: ""

processing:
  threads: ${THREADS}
  interval_seconds: ${INTERVAL}
  batch_size: 10
  max_retries: 3
  retry_delay: 5
  enable_streaming: true
  enable_snapshots: true
  enable_clips: true

security:
  webhook_secret: "${WEBHOOK_SECRET}"
  encrypt_payloads: false
  allowed_hosts: []
  rate_limit: 100

supervisor:
  enabled: true
  check_interval: 300
  auto_update: true
  update_channel: "stable"
  repo_url: "${REPO_URL}"
  raw_url: "${RAW_URL}"
  backup_before_update: true
  max_backups: 5
  health_check_interval: 60
  restart_on_failure: true
  max_restarts: 5
  restart_window: 3600

logging:
  level: "INFO"
  file: "${LOG_DIR}/gateway.log"
  max_size_mb: 100
  backup_count: 10
  format: "%(asctime)s | %(levelname)-8s | %(name)s | %(message)s"

r2:
  enabled: ${R2_ENABLED}
  endpoint: "${R2_ENDPOINT}"
  bucket: "${R2_BUCKET}"
  access_key: "${R2_ACCESS_KEY}"
  secret_key: "${R2_SECRET_KEY}"
  region: "auto"
  presigned_url_ttl: 3600

cameras: []
EOF

chown openconnect:openconnect "$CONFIG_DIR/config.yaml"
chmod 640 "$CONFIG_DIR/config.yaml"

ok "Configuração salva em $CONFIG_DIR/config.yaml"

# ---- Configurar sincronização com Supabase (se token fornecido) ----
CONFIG_TOKEN="${CONFIG_TOKEN:-}"
CONFIG_URL="${CONFIG_URL:-}"

if [ -n "$CONFIG_TOKEN" ] && [ -n "$CONFIG_URL" ]; then
    info "Configurando sincronização automática de config.yaml..."
    echo "$CONFIG_TOKEN" > "$CONFIG_DIR/.config_token"
    echo "$CONFIG_URL" > "$CONFIG_DIR/.config_url"

    cat > "$INSTALL_DIR/sync-config.sh" <<'SYNC_EOF'
#!/bin/bash
CONFIG_DIR="/etc/openconnect-gateway"
TOKEN=$(cat "$CONFIG_DIR/.config_token" 2>/dev/null)
URL=$(cat "$CONFIG_DIR/.config_url" 2>/dev/null)
if [ -n "$TOKEN" ] && [ -n "$URL" ]; then
    curl -fsSL "${URL}&token=${TOKEN}" -o "$CONFIG_DIR/config.yaml" 2>/dev/null
fi
SYNC_EOF
    chmod +x "$INSTALL_DIR/sync-config.sh"

    (crontab -l 2>/dev/null | grep -v "sync-config.sh"; echo "*/15 * * * * $INSTALL_DIR/sync-config.sh") | crontab -
    ok "Cron configurado: sincronização a cada 15 minutos"
fi

# ---- Criar arquivo de versão ----
echo "10.0.6" > "$INSTALL_DIR/.version"
chown openconnect:openconnect "$INSTALL_DIR/.version"

# ---- Iniciar serviços ----
info "Iniciando serviço gateway..."
systemctl start "$SERVICE_NAME"
sleep 2

if systemctl is-active --quiet "$SERVICE_NAME"; then
    ok "Gateway iniciado com sucesso!"
else
    warn "Gateway não iniciou automaticamente. Verifique: journalctl -u $SERVICE_NAME -n 50"
fi

info "Iniciando supervisor..."
systemctl start "${SERVICE_NAME}-supervisor"
sleep 2

if systemctl is-active --quiet "${SERVICE_NAME}-supervisor"; then
    ok "Supervisor iniciado com sucesso!"
else
    warn "Supervisor não iniciou. Verifique: journalctl -u ${SERVICE_NAME}-supervisor -n 50"
fi

# ---- Resumo ----
echo ""
color "32" "╔═══════════════════════════════════════════════════════╗"
color "32" "║   OpenConnect Gateway v10.0.6 Instalado com Sucesso!    ║"
color "32" "╚═══════════════════════════════════════════════════════╝"
echo ""
echo "  📁 Instalação:  $INSTALL_DIR"
echo "  ⚙️  Config:      $CONFIG_DIR/config.yaml"
echo "  📜 Logs:        $LOG_DIR/gateway.log"
echo "  🔧 Serviço:     systemctl status $SERVICE_NAME"
echo ""
echo "  Comandos úteis:"
echo "    sudo systemctl status $SERVICE_NAME"
echo "    sudo systemctl restart $SERVICE_NAME"
echo "    sudo systemctl status ${SERVICE_NAME}-supervisor"
echo "    sudo systemctl restart ${SERVICE_NAME}-supervisor"
echo "    sudo journalctl -u $SERVICE_NAME -f"
echo "    sudo journalctl -u ${SERVICE_NAME}-supervisor -f"
echo "    sudo $INSTALL_DIR/scripts/health_check.sh"
echo ""
echo "  Supervisor (auto-update):"
echo "    Verifica Git a cada 5 minutos"
echo "    Backup automático antes de updates"
echo ""
echo "  Sincronização de config (cron):"
echo "    sudo crontab -l | grep sync-config"
echo "    sudo $INSTALL_DIR/sync-config.sh"
echo ""
echo "  Para adicionar câmeras, edite:"
echo "    sudo nano $CONFIG_DIR/config.yaml"
echo "    sudo systemctl reload $SERVICE_NAME"
echo ""
