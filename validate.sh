#!/bin/bash
# =============================================================================
# OpenConnect Gateway - Pre-Deploy Validator
# =============================================================================
# Valida o repositório antes de subir para o Git
# =============================================================================

set -euo pipefail

RED='\e[31m'
GREEN='\e[32m'
YELLOW='\e[33m'
BLUE='\e[36m'
NC='\e[0m'

ERRORS=0
WARNINGS=0

check_pass() { echo -e "${GREEN}✅${NC} $1"; }
check_fail() { echo -e "${RED}❌${NC} $1"; ERRORS=$((ERRORS+1)); }
check_warn() { echo -e "${YELLOW}⚠️ ${NC} $1"; WARNINGS=$((WARNINGS+1)); }

echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  OpenConnect Gateway - Pre-Deploy Validator${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo ""

# 1. Verificar arquivos obrigatórios
echo "📁 Verificando arquivos obrigatórios..."
REQUIRED=(
    "install.sh"
    "openconnect-gateway.py"
    "supervisor.py"
    "requirements.txt"
    "config.yaml"
    "README.md"
    "LICENSE"
    "VERSION"
    "systemd/openconnect-gateway.service"
    "systemd/openconnect-supervisor.service"
    "scripts/health_check.sh"
    "scripts/tunnel_check.sh"
)

for file in "${REQUIRED[@]}"; do
    if [ -f "$file" ]; then
        check_pass "Arquivo encontrado: $file"
    else
        check_fail "Arquivo FALTANDO: $file"
    fi
done

# 2. Verificar permissões de execução
echo ""
echo "🔐 Verificando permissões..."
EXEC_FILES=("install.sh" "openconnect-gateway.py" "supervisor.py" "scripts/health_check.sh" "scripts/tunnel_check.sh")
for file in "${EXEC_FILES[@]}"; do
    if [ -x "$file" ]; then
        check_pass "Executável: $file"
    else
        check_warn "Sem permissão de execução: $file (chmod +x $file)"
    fi
done

# 3. Validar sintaxe Python
echo ""
echo "🐍 Validando sintaxe Python..."
for pyfile in openconnect-gateway.py supervisor.py; do
    if python3 -m py_compile "$pyfile" 2>/dev/null; then
        check_pass "Sintaxe OK: $pyfile"
    else
        check_fail "Erro de sintaxe em: $pyfile"
    fi
done

# 4. Verificar placeholders
echo ""
echo "🔍 Verificando placeholders..."
PLACEHOLDERS=("openconnect" "samir-velleda" "openconnect" "carrinhovirtual.com" "grupomateus" "grupomateus")
for ph in "${PLACEHOLDERS[@]}"; do
    COUNT=$(grep -r "$ph" --include="*.sh" --include="*.py" --include="*.yaml" --include="*.md" . 2>/dev/null | wc -l)
    if [ "$COUNT" -gt 0 ]; then
        check_warn "Placeholder '$ph' encontrado em $COUNT linha(s). Substitua antes do deploy!"
        grep -rn "$ph" --include="*.sh" --include="*.py" --include="*.yaml" --include="*.md" . | head -5 | sed 's/^/    /'
    fi
done

if [ "$ERRORS" -eq 0 ] && [ "$WARNINGS" -eq 0 ]; then
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   ✅ TODAS AS VALIDAÇÕES PASSARAM!                    ║${NC}"
    echo -e "${GREEN}║   Pronto para deploy no Git.                          ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}"
    exit 0
else
    echo ""
    echo -e "${YELLOW}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║   ⚠️  VALIDAÇÃO COM PROBLEMAS                          ║${NC}"
    echo -e "${YELLOW}║   Erros: $ERRORS | Avisos: $WARNINGS                                    ║${NC}"
    echo -e "${YELLOW}╚═══════════════════════════════════════════════════════╝${NC}"
    exit 1
fi
