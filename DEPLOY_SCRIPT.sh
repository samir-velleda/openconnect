#!/bin/bash
# =============================================================================
# OpenConnect Gateway v4.0 - Deploy Script
# =============================================================================
# Execute este script para subir o repositório para o GitHub
# =============================================================================

set -euo pipefail

USERNAME="samir-velleda"
REPO="openconnect"
REPO_URL="https://github.com/${USERNAME}/${REPO}"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   OpenConnect Gateway v4.0 - Deploy para GitHub             ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Username: ${USERNAME}"
echo "  Repo:     ${REPO}"
echo "  URL:      ${REPO_URL}"
echo ""

# Verificar git
if ! command -v git &> /dev/null; then
    echo "❌ Git não instalado. Instale: sudo apt install git"
    exit 1
fi

# Verificar se estamos no diretório correto
if [ ! -f "install.sh" ]; then
    echo "❌ Execute este script dentro do diretório openconnect-gateway-v4/"
    exit 1
fi

# Configurar git (se necessário)
git config user.email "samirvelleda2020@gmail.com" 2>/dev/null || true
git config user.name "Samir Velleda" 2>/dev/null || true

# Inicializar repositório
echo "📦 Inicializando repositório Git..."
git init

# Adicionar arquivos
echo "📁 Adicionando arquivos..."
git add .

# Commit
echo "💾 Criando commit..."
git commit -m "OpenConnect Gateway v4.0 - Release inicial

- Gateway principal com multi-threading
- Supervisor com auto-update via Git
- Instalador one-liner
- Health check e tunnel check
- Suporte Ubuntu/Debian/CentOS/Arch"

# Renomear branch
git branch -M main

# Adicionar remote
echo "🔗 Configurando remote..."
git remote add origin "${REPO_URL}.git" 2>/dev/null || git remote set-url origin "${REPO_URL}.git"

# Push
echo "🚀 Enviando para GitHub..."
git push -u origin main

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   ✅ Deploy concluído com sucesso!                           ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Repositório: ${REPO_URL}"
echo ""
echo "  Comando one-liner para instalação:"
echo "  curl -fsSL https://raw.githubusercontent.com/${USERNAME}/${REPO}/main/install.sh | bash"
echo ""
echo "  Para testar em uma VM Linux limpa, execute o comando acima."
echo ""
