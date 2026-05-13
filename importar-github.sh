#!/bin/bash
# =============================================================================
# OpenConnect Gateway v4.0 - IMPORTAR PARA GITHUB
# =============================================================================
# Execute este script para subir o repositório para o GitHub
# =============================================================================

set -e

USERNAME="samir-velleda"
REPO="openconnect"
REPO_URL="https://github.com/${USERNAME}/${REPO}"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   📦 IMPORTANDO OPENCONNECT GATEWAY PARA GITHUB             ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Repositório: ${REPO_URL}"
echo ""

# 1. Verificar se está no diretório correto
if [ ! -f "install.sh" ]; then
    echo "❌ ERRO: Execute este script DENTRO da pasta openconnect-gateway-v4/"
    echo "   cd /mnt/agents/output/openconnect-gateway-v4/"
    echo "   bash importar-github.sh"
    exit 1
fi

# 2. Verificar git
if ! command -v git &> /dev/null; then
    echo "📥 Instalando Git..."
    sudo apt-get update -qq && sudo apt-get install -y -qq git
fi

# 3. Configurar git
echo "⚙️  Configurando Git..."
git config user.email "samirvelleda2020@gmail.com" 2>/dev/null || true
git config user.name "Samir Velleda" 2>/dev/null || true

# 4. Inicializar repositório
echo "📁 Inicializando repositório..."
git init

# 5. Adicionar todos os arquivos
echo "📂 Adicionando arquivos..."
git add .

# 6. Commit inicial
echo "💾 Criando commit..."
git commit -m "OpenConnect Gateway v4.0 - Release inicial

Features:
- Gateway principal com multi-threading e retry automático
- Supervisor com auto-update via GitHub
- Instalador one-liner para Linux
- Health check e tunnel check scripts
- Suporte Ubuntu/Debian/CentOS/Arch/Rocky"

# 7. Renomear branch para main
git branch -M main

# 8. Adicionar remote do GitHub
echo "🔗 Conectando ao GitHub..."
git remote add origin "${REPO_URL}.git" 2>/dev/null || git remote set-url origin "${REPO_URL}.git"

# 9. Configurar permissões de execução no Git
echo "🔐 Configurando permissões..."
git update-index --chmod=+x install.sh
git update-index --chmod=+x openconnect-gateway.py
git update-index --chmod=+x supervisor.py
git update-index --chmod=+x validate.sh
git update-index --chmod=+x importar-github.sh
git update-index --chmod=+x scripts/health_check.sh
git update-index --chmod=+x scripts/tunnel_check.sh

# 10. Commit das permissões
git commit -m "fix: executable permissions" --no-verify || true

# 11. Push para GitHub
echo "🚀 Enviando para GitHub..."
git push -u origin main

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   ✅ SUCESSO! REPOSITÓRIO NO AR                             ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  🌐 URL: ${REPO_URL}"
echo ""
echo "  📋 Próximo passo: Teste o one-liner em uma VM Linux:"
echo ""
echo "  curl -fsSL https://raw.githubusercontent.com/${USERNAME}/${REPO}/main/install.sh | bash"
echo ""
