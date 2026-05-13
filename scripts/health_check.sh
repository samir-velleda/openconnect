#!/bin/bash
# =============================================================================
# OpenConnect Gateway - Health Check
# =============================================================================
# Uso: sudo /opt/openconnect-gateway/scripts/health_check.sh
# =============================================================================

set -euo pipefail

SERVICE_NAME="openconnect-gateway"
LOG_DIR="/var/log/openconnect-gateway"
CONFIG="/etc/openconnect-gateway/config.yaml"

RED='\e[31m'
GREEN='\e[32m'
YELLOW='\e[33m'
BLUE='\e[36m'
NC='\e[0m'

print_status() {
    local status=$1
    local message=$2
    if [ "$status" = "OK" ]; then
        echo -e "${GREEN}✅${NC} $message"
    elif [ "$status" = "WARN" ]; then
        echo -e "${YELLOW}⚠️ ${NC} $message"
    else
        echo -e "${RED}❌${NC} $message"
    fi
}

echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  OpenConnect Gateway - Health Check${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo ""

# 1. Verificar serviço systemd
if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    print_status "OK" "Serviço $SERVICE_NAME está ativo"
else
    print_status "FAIL" "Serviço $SERVICE_NAME está INATIVO"
fi

# 2. Verificar supervisor
if systemctl is-active --quiet "${SERVICE_NAME}-supervisor" 2>/dev/null; then
    print_status "OK" "Supervisor está ativo"
else
    print_status "WARN" "Supervisor está inativo"
fi

# 3. Verificar processos
GATEWAY_PID=$(pgrep -f "openconnect-gateway.py" || true)
if [ -n "$GATEWAY_PID" ]; then
    print_status "OK" "Gateway rodando (PID: $GATEWAY_PID)"
else
    print_status "FAIL" "Gateway NÃO está rodando"
fi

# 4. Verificar portas (se houver)
# Adicione portas específicas se necessário

# 5. Verificar logs recentes
if [ -f "$LOG_DIR/gateway.log" ]; then
    LAST_ERROR=$(grep -i "error\|fail\|exception" "$LOG_DIR/gateway.log" 2>/dev/null | tail -5 || true)
    if [ -z "$LAST_ERROR" ]; then
        print_status "OK" "Nenhum erro recente nos logs"
    else
        print_status "WARN" "Erros recentes detectados nos logs"
        echo "$LAST_ERROR" | sed 's/^/    /'
    fi
else
    print_status "WARN" "Arquivo de log não encontrado"
fi

# 6. Verificar configuração
if [ -f "$CONFIG" ]; then
    print_status "OK" "Configuração encontrada"
    CAMERAS=$(grep -c "^  - id:" "$CONFIG" 2>/dev/null || echo "0")
    echo -e "    ${BLUE}→${NC} $CAMERAS câmeras configuradas"
else
    print_status "FAIL" "Arquivo de configuração não encontrado"
fi

# 7. Verificar disco
DISK_USAGE=$(df -h /opt /var/log 2>/dev/null | awk 'NR>1 {print $5}' | sed 's/%//' | sort -nr | head -1)
if [ -n "$DISK_USAGE" ] && [ "$DISK_USAGE" -lt 80 ]; then
    print_status "OK" "Uso de disco: ${DISK_USAGE}%"
else
    print_status "WARN" "Uso de disco alto: ${DISK_USAGE}%"
fi

# 8. Verificar memória
MEM_AVAILABLE=$(free | grep Mem | awk '{print $7/$2 * 100.0}' | cut -d. -f1)
if [ -n "$MEM_AVAILABLE" ] && [ "$MEM_AVAILABLE" -gt 10 ]; then
    print_status "OK" "Memória disponível: ${MEM_AVAILABLE}%"
else
    print_status "WARN" "Memória baixa: ${MEM_AVAILABLE}% disponível"
fi

# 9. Métricas do gateway
if [ -f "$LOG_DIR/metrics.json" ]; then
    print_status "OK" "Arquivo de métricas encontrado"
    UPTIME=$(python3 -c "import json; d=json.load(open('$LOG_DIR/metrics.json')); print(d.get('uptime_seconds', 0))" 2>/dev/null || echo "?")
    TOTAL_REQ=$(python3 -c "import json; d=json.load(open('$LOG_DIR/metrics.json')); print(d.get('metrics', {}).get('total_requests', 0))" 2>/dev/null || echo "?")
    echo -e "    ${BLUE}→${NC} Uptime: ${UPTIME}s | Total requests: ${TOTAL_REQ}"
else
    print_status "WARN" "Métricas não disponíveis"
fi

echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
