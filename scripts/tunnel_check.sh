#!/bin/bash
# =============================================================================
# OpenConnect Gateway - Tunnel Checker
# =============================================================================
# Verifica status dos túneis Cloudflare e go2rtc
# =============================================================================

set -euo pipefail

CONFIG="/etc/openconnect-gateway/config.yaml"
TIMEOUT=10

RED='\e[31m'
GREEN='\e[32m'
YELLOW='\e[33m'
BLUE='\e[36m'
NC='\e[0m'

echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  OpenConnect Gateway - Tunnel Status${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo ""

# Função para extrair valor do YAML
yaml_get() {
    local key=$1
    local file=$2
    python3 -c "import yaml; print(yaml.safe_load(open('$file')).get('$key', ''))" 2>/dev/null || echo ""
}

# Verificar se config existe
if [ ! -f "$CONFIG" ]; then
    echo -e "${RED}❌${NC} Configuração não encontrada: $CONFIG"
    exit 1
fi

# Extrair URLs
ORCH_URL=$(yaml_get "orchestrator.url" "$CONFIG")
GO2RTC_URL=$(yaml_get "go2rtc.base_url" "$CONFIG")

check_url() {
    local name=$1
    local url=$2
    local expected=${3:-200}

    if [ -z "$url" ]; then
        echo -e "${YELLOW}⚠️ ${NC} $name: URL não configurada"
        return 1
    fi

    START=$(date +%s.%N)
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout $TIMEOUT --max-time $TIMEOUT "$url" 2>/dev/null || echo "000")
    END=$(date +%s.%N)
    DURATION=$(python3 -c "print(f'{(float('$END') - float('$START'))*1000:.0f}')" 2>/dev/null || echo "?")

    if [ "$HTTP_CODE" = "$expected" ] || [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "202" ]; then
        echo -e "${GREEN}✅${NC} $name: HTTP $HTTP_CODE (${DURATION}ms) - $url"
        return 0
    else
        echo -e "${RED}❌${NC} $name: HTTP $HTTP_CODE (${DURATION}ms) - $url"
        return 1
    fi
}

# Verificar Orchestrator
check_url "Orchestrator" "$ORCH_URL" "200"

# Verificar go2rtc
check_url "go2rtc" "$GO2RTC_URL" "200"

# Verificar túneis Cloudflare (se existirem)
echo ""
echo -e "${BLUE}Verificando túneis Cloudflare...${NC}"

if command -v cloudflared &> /dev/null; then
    TUNNEL_LIST=$(cloudflared tunnel list 2>/dev/null || true)
    if [ -n "$TUNNEL_LIST" ]; then
        echo "$TUNNEL_LIST"
    else
        echo -e "${YELLOW}⚠️ ${NC} Nenhum túnel Cloudflare encontrado ou cloudflared não configurado"
    fi
else
    echo -e "${YELLOW}⚠️ ${NC} cloudflared não instalado"
fi

# Verificar conectividade de rede
echo ""
echo -e "${BLUE}Verificando conectividade de rede...${NC}"

if ping -c 1 -W 3 8.8.8.8 &> /dev/null; then
    echo -e "${GREEN}✅${NC} Internet: Conectado"
else
    echo -e "${RED}❌${NC} Internet: Sem conectividade"
fi

# DNS resolution
if nslookup google.com &> /dev/null; then
    echo -e "${GREEN}✅${NC} DNS: Resolução funcionando"
else
    echo -e "${RED}❌${NC} DNS: Problemas de resolução"
fi

echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
