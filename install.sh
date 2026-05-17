#!/bin/bash
# =============================================================================
# OPENCONECT TITAN GATEWAY v2.0 — INSTALADOR OFICIAL
# Uso: curl -sL ... | sudo bash -s -- --gateway-id <uuid> --token <uuid>
# =============================================================================
set -e

# --- Parse argumentos ---
GATEWAY_ID=""
CONFIG_TOKEN=""
SUPABASE_URL="https://tsvigycstpfdhgriqbfe.supabase.co"
SUPABASE_ANON_KEY="sb_publishable_clGrlyN8z7VkUOOLvBtdiQ_zLoIi6kM"

while [[ $# -gt 0 ]]; do
    case $1 in
        --gateway-id) GATEWAY_ID="$2"; shift 2 ;;
        --token) CONFIG_TOKEN="$2"; shift 2 ;;
        --supabase-url) SUPABASE_URL="$2"; shift 2 ;;
        --supabase-anon-key) SUPABASE_ANON_KEY="$2"; shift 2 ;;
        *) echo "Uso: $0 --gateway-id <uuid> --token <uuid>"; exit 1 ;;
    esac
done

if [ -z "$GATEWAY_ID" ] || [ -z "$CONFIG_TOKEN" ]; then
    echo "❌ ERRO: --gateway-id e --token são obrigatórios"
    exit 1
fi

# --- Config fixa ---
RUNPOD_IP="69.30.85.241"
RUNPOD_PORT="22188"
GO2RTC_VER="1.9.13"
HEARTBEAT_INTERVAL=30
VERSION="2.0.0"

# --- Paths ---
INSTALL_DIR="/opt/openconnect-gateway"
ENV_FILE="/etc/openconnect/gateway.env"
GO2RTC_DIR="/opt/go2rtc"
LOG_DIR="/var/log/openconnect-gateway"

echo "========================================"
echo "  OPENCONECT TITAN GATEWAY v${VERSION}"
echo "  Gateway ID: ${GATEWAY_ID}"
echo "========================================"
echo ""

# [1] Dependências
echo "[1/9] Instalando dependências..."
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq ffmpeg curl wget systemd jq python3 python3-pip 2>/dev/null || true
pip3 install fastapi uvicorn boto3 requests pyyaml -q 2>/dev/null || true

# [2] Criar diretórios e env file
echo "[2/9] Criando diretórios e gateway.env..."
mkdir -p ${INSTALL_DIR} ${LOG_DIR} ${GO2RTC_DIR} /etc/openconnect

cat > ${ENV_FILE} <<EOF
GATEWAY_ID=${GATEWAY_ID}
CONFIG_TOKEN=${CONFIG_TOKEN}
RUNPOD_IP=${RUNPOD_IP}
RUNPOD_PORT=${RUNPOD_PORT}
HEARTBEAT_INTERVAL=${HEARTBEAT_INTERVAL}
SUPABASE_URL=${SUPABASE_URL}
SUPABASE_ANON_KEY=${SUPABASE_ANON_KEY}
VERSION=${VERSION}
EOF
chmod 600 ${ENV_FILE}

# [3] go2rtc
echo "[3/9] Instalando go2rtc v${GO2RTC_VER}..."
if [ ! -f /usr/local/bin/go2rtc ]; then
    wget -q "https://github.com/AlexxIT/go2rtc/releases/download/v${GO2RTC_VER}/go2rtc_linux_amd64" -O /usr/local/bin/go2rtc
    chmod +x /usr/local/bin/go2rtc
fi

cat > ${GO2RTC_DIR}/go2rtc.yaml <<'EOF'
api:
  listen: ":1984"
rtsp:
  listen: ":8554"
log:
  level: info
  format: text
streams: {}
EOF

# [4] Systemd go2rtc
cat > /etc/systemd/system/go2rtc.service <<'EOF'
[Unit]
Description=go2rtc streaming server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/go2rtc -config /opt/go2rtc/go2rtc.yaml
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

# [5] API Python do Gateway — com ajustes do parecer
echo "[5/9] Criando API do gateway..."
cat > ${INSTALL_DIR}/gateway_api.py <<'PYEOF'
#!/usr/bin/env python3
"""
OpenConnect Titan Gateway API v2.0
Ajustes do parecer Lovable:
- Heartbeat chama RPC real no Supabase
- substream é boolean (True=sub, False=main)
- enabled removido do payload (sempre True por contrato)
"""

import os, json, time, subprocess, threading, logging, hashlib, copy
from datetime import datetime
from typing import List, Optional, Dict
from fastapi import FastAPI, HTTPException, Header, Depends
from pydantic import BaseModel
import requests, yaml

# --- Carregar env ---
ENV_FILE = "/etc/openconnect/gateway.env"
if os.path.exists(ENV_FILE):
    with open(ENV_FILE) as f:
        for line in f:
            if '=' in line and not line.startswith('#'):
                k, v = line.strip().split('=', 1)
                os.environ.setdefault(k, v)

GATEWAY_ID    = os.getenv("GATEWAY_ID", "")
CONFIG_TOKEN  = os.getenv("CONFIG_TOKEN", "")
RUNPOD_IP     = os.getenv("RUNPOD_IP", "69.30.85.241")
RUNPOD_PORT   = os.getenv("RUNPOD_PORT", "22188")
HEARTBEAT_INT = int(os.getenv("HEARTBEAT_INTERVAL", "30"))
SUPABASE_URL  = os.getenv("SUPABASE_URL", "")
SUPABASE_KEY  = os.getenv("SUPABASE_ANON_KEY", "")
VERSION       = os.getenv("VERSION", "2.0.0")
GO2RTC_YAML   = "/opt/go2rtc/go2rtc.yaml"
PUSH_LOG      = "/tmp/push_openconnect.log"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s|%(levelname)s|%(message)s"
)
logger = logging.getLogger("gateway-api")

app = FastAPI(title="OpenConnect Titan Gateway API", version=VERSION)

# --- Estado ---
active_pushes: Dict[str, subprocess.Popen] = {}
current_config_hash: str = ""
config_version: int = 0

# --- Modelos (ajustados do parecer) ---
class CameraConfig(BaseModel):
    camera_id: str
    name: str
    stream_url: str
    snapshot_url: Optional[str] = ""
    role: Optional[str] = "streaming"
    substream: Optional[bool] = False   # True=sub, False=main (boolean!)
    ia_snapshot_interval_ms: Optional[int] = 2000
    device_id: Optional[str] = ""
    # NOTA: enabled removido — toda câmera no array é ativa por contrato

class GatewayConfigPayload(BaseModel):
    gateway_id: str
    store_id: str
    company_id: str
    cameras: List[CameraConfig]

# --- Auth ---
def verify_token(authorization: Optional[str] = Header(None, alias="Authorization")):
    if not authorization:
        raise HTTPException(status_code=401, detail="Missing Authorization header")
    parts = authorization.split()
    if len(parts) != 2 or parts[0].lower() != "bearer":
        raise HTTPException(status_code=401, detail="Invalid Authorization format")
    if parts[1] != CONFIG_TOKEN:
        raise HTTPException(status_code=401, detail="Invalid token")
    return parts[1]

# --- Helpers ---
def reload_go2rtc():
    try:
        requests.post("http://127.0.0.1:1984/api/restart", timeout=5)
        logger.info("go2rtc recarregado via API")
    except Exception as e:
        logger.warning(f"API reload falhou: {e}")
        os.system("systemctl restart go2rtc.service")
        time.sleep(3)

def write_go2rtc_yaml(cameras: List[CameraConfig]):
    config = {
        "api": {"listen": ":1984"},
        "rtsp": {"listen": ":8554"},
        "log": {"level": "info", "format": "text"},
        "streams": {}
    }
    for cam in cameras:
        if cam.stream_url:
            # Se substream=True, adiciona sufixo _sub no ID interno se necessário
            # Mas o go2rtc usa a URL direta — o mapeamento é do lado do frontend
            config["streams"][cam.camera_id] = cam.stream_url
    with open(GO2RTC_YAML, "w") as f:
        yaml.dump(config, f, default_flow_style=False, allow_unicode=True)
    reload_go2rtc()

def start_push(camera_id: str):
    global active_pushes
    if camera_id in active_pushes:
        active_pushes[camera_id].poll()
        if active_pushes[camera_id].returncode is None:
            return
    rtsp = f"rtsp://127.0.0.1:8554/{camera_id}"
    rtmp = f"rtmp://{RUNPOD_IP}:{RUNPOD_PORT}/live/{camera_id}"
    proc = subprocess.Popen(
        ["ffmpeg", "-hide_banner", "-loglevel", "warning",
         "-rtsp_transport", "tcp", "-i", rtsp,
         "-c", "copy", "-f", "flv", rtmp],
        stdout=open(PUSH_LOG, "a"),
        stderr=subprocess.STDOUT,
        stdin=subprocess.DEVNULL
    )
    active_pushes[camera_id] = proc
    logger.info(f"Push iniciado: {camera_id} -> {rtmp} (PID {proc.pid})")

def stop_push(camera_id: str):
    global active_pushes
    if camera_id in active_pushes:
        try:
            active_pushes[camera_id].terminate()
            time.sleep(1)
            active_pushes[camera_id].kill()
        except:
            pass
        del active_pushes[camera_id]
        logger.info(f"Push parado: {camera_id}")

def get_system_metrics():
    try:
        with open('/proc/loadavg') as f:
            load = f.read().split()[0]
        with open('/proc/meminfo') as f:
            mem = f.readlines()
        mem_total = int(mem[0].split()[1])
        mem_avail = int(mem[2].split()[1])
        mem_pct = round((mem_total - mem_avail) / mem_total * 100, 1)
        uptime = 0
        with open('/proc/uptime') as f:
            uptime = float(f.read().split()[0])
        pushes_alive = len([p for p in active_pushes.values() if p.poll() is None])
        return {
            "cpu_load": float(load),
            "mem_percent": mem_pct,
            "uptime_s": int(uptime),
            "pushes_active": pushes_alive,
            "cameras_total": len(active_pushes),
            "go2rtc_ok": False
        }
    except Exception as e:
        logger.error(f"metrics error: {e}")
        return {"cpu_load": 0, "mem_percent": 0, "uptime_s": 0, "pushes_active": 0, "cameras_total": 0, "go2rtc_ok": False}

def send_heartbeat():
    """Chama RPC update_gateway_heartbeat no Supabase a cada 30s"""
    metrics = get_system_metrics()
    try:
        r = requests.get("http://127.0.0.1:1984/api/streams", timeout=2)
        metrics["go2rtc_ok"] = r.status_code == 200
    except:
        metrics["go2rtc_ok"] = False

    # --- CHAMADA REAL AO SUPABASE RPC ---
    if SUPABASE_URL and SUPABASE_KEY:
        try:
            resp = requests.post(
                f"{SUPABASE_URL}/rest/v1/rpc/update_gateway_heartbeat",
                headers={
                    "apikey": SUPABASE_KEY,
                    "Authorization": f"Bearer {SUPABASE_KEY}",
                    "Content-Type": "application/json",
                },
                json={
                    "p_gateway_id": GATEWAY_ID,
                    "p_version": VERSION,
                    "p_metrics": metrics
                },
                timeout=5,
            )
            if resp.status_code == 200:
                logger.info(f"[HEARTBEAT] RPC OK — metrics={metrics}")
            else:
                logger.warning(f"[HEARTBEAT] RPC falhou: HTTP {resp.status_code} — {resp.text[:100]}")
        except Exception as e:
            logger.error(f"[HEARTBEAT] RPC erro: {e}")
    else:
        logger.warning("[HEARTBEAT] SUPABASE_URL ou SUPABASE_ANON_KEY não configurados — log local apenas")

    threading.Timer(HEARTBEAT_INT, send_heartbeat).start()

# Iniciar heartbeat
threading.Timer(5, send_heartbeat).start()

# --- Endpoints ---

@app.get("/health")
def health():
    return {
        "status": "ok",
        "version": VERSION,
        "gateway_id": GATEWAY_ID,
        "go2rtc": os.path.exists("/usr/local/bin/go2rtc"),
        "timestamp": datetime.utcnow().isoformat()
    }

@app.get("/cameras", dependencies=[Depends(verify_token)])
def list_cameras():
    try:
        with open(GO2RTC_YAML) as f:
            cfg = yaml.safe_load(f)
        streams = cfg.get("streams", {})
        return {
            "cameras": [
                {"id": k, "stream_url": v, "pushing": k in active_pushes}
                for k, v in streams.items()
            ]
        }
    except Exception as e:
        return {"cameras": [], "error": str(e)}

@app.post("/config", dependencies=[Depends(verify_token)])
def apply_config(payload: GatewayConfigPayload):
    global current_config_hash, config_version

    if payload.gateway_id != GATEWAY_ID:
        raise HTTPException(status_code=403, detail="gateway_id mismatch")

    # Hash para detectar mudança real
    raw = json.dumps(payload.dict(), sort_keys=True)
    new_hash = hashlib.sha256(raw.encode()).hexdigest()[:16]
    if new_hash == current_config_hash:
        return {"status": "unchanged", "config_version": config_version, "config_hash": new_hash}

    # Backup
    backup = f"{GO2RTC_YAML}.bak.{int(time.time())}"
    try:
        import shutil
        shutil.copy(GO2RTC_YAML, backup)
    except:
        pass

    # Aplicar config
    try:
        write_go2rtc_yaml(payload.cameras)

        # Parar pushes que sumiram
        current_ids = {c.camera_id for c in payload.cameras}
        for cid in list(active_pushes.keys()):
            if cid not in current_ids:
                stop_push(cid)

        # Iniciar pushes novos (apenas se role != snapshot_only)
        for cam in payload.cameras:
            if cam.role == "snapshot_only":
                logger.info(f"Câmera {cam.camera_id} em modo snapshot_only — sem push RTMP")
                continue
            start_push(cam.camera_id)

        config_version += 1
        current_config_hash = new_hash

        return {
            "status": "configured",
            "config_version": config_version,
            "config_hash": new_hash,
            "cameras_active": len(payload.cameras),
            "pushes_active": len(active_pushes)
        }

    except Exception as e:
        if os.path.exists(backup):
            shutil.copy(backup, GO2RTC_YAML)
            reload_go2rtc()
        logger.error(f"Config apply failed: {e}")
        raise HTTPException(status_code=500, detail=f"Config failed: {str(e)}")

@app.get("/status", dependencies=[Depends(verify_token)])
def gateway_status():
    metrics = get_system_metrics()
    status = {
        "gateway_id": GATEWAY_ID,
        "go2rtc_ok": metrics.pop("go2rtc_ok"),
        "pushes": {},
        "system": metrics
    }
    for cid, proc in active_pushes.items():
        proc.poll()
        status["pushes"][cid] = {
            "running": proc.returncode is None,
            "pid": proc.pid,
            "returncode": proc.returncode
        }
    return status

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8082)
PYEOF

chmod +x ${INSTALL_DIR}/gateway_api.py

# [6] Systemd API
echo "[6/9] Configurando systemd..."
cat > /etc/systemd/system/openconnect-api.service <<EOF
[Unit]
Description=OpenConnect Titan Gateway API v2.0
After=go2rtc.service network.target
Requires=go2rtc.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/gateway_api.py
Restart=always
RestartSec=5
User=root
EnvironmentFile=${ENV_FILE}

[Install]
WantedBy=multi-user.target
EOF

# [7] Iniciar serviços
echo "[7/9] Iniciando serviços..."
systemctl daemon-reload
systemctl enable go2rtc.service openconnect-api.service
systemctl start go2rtc.service
sleep 2
systemctl start openconnect-api.service
sleep 3

# [8] Validar
echo "[8/9] Validando instalação..."
HEALTH=$(curl -s http://127.0.0.1:8082/health 2>/dev/null || echo "")
if echo "$HEALTH" | grep -q "ok"; then
    echo "✅ Gateway API respondendo em http://localhost:8082"
else
    echo "⚠️  Gateway API não respondeu. Verifique: journalctl -u openconnect-api -n 20"
fi

# [9] Cloudflared hint
echo "[9/9] Lembrete de configuração..."
echo ""
echo "========================================"
echo "  INSTALAÇÃO CONCLUÍDA"
echo "========================================"
echo ""
echo "Gateway ID:  ${GATEWAY_ID}"
echo "Token:       ${CONFIG_TOKEN:0:8}... (em ${ENV_FILE})"
echo ""
echo "Próximo passo:"
echo "  Configure o Cloudflare Tunnel apontando para localhost:8082"
echo "  (não para o go2rtc em 1984 — a API do gateway é na 8082)"
echo ""
echo "Endpoints:"
echo "  GET  /health        → Sem auth"
echo "  GET  /cameras       → Bearer <token>"
echo "  POST /config        → Bearer <token>"
echo "  GET  /status        → Bearer <token>"
echo ""
echo "Heartbeat: RPC update_gateway_heartbeat a cada ${HEARTBEAT_INTERVAL}s"
echo ""
echo "Comandos úteis:"
echo "  systemctl status go2rtc openconnect-api"
echo "  curl http://localhost:8082/health"
echo "  tail -f /var/log/openconnect-gateway/*.log"
echo "========================================"
