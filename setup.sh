#!/bin/bash
# =============================================================================
# OpenConnect Gateway v10 - Setup Interativo de Credenciais
# =============================================================================
# Execute ANTES da instalação para gerar o comando com suas credenciais
# =============================================================================

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   OpenConnect Gateway v10 - Configuração de Credenciais      ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Este script vai gerar o comando de instalação com suas credenciais."
echo ""

# Perguntar credenciais R2
read -p "R2 Endpoint (ex: https://abc123.r2.cloudflarestorage.com): " R2_ENDPOINT
read -p "R2 Bucket (ex: openmart): " R2_BUCKET
read -p "R2 Access Key: " R2_ACCESS_KEY
read -p "R2 Secret Key: " R2_SECRET_KEY

# Perguntar Supabase
read -p "Config Token (do frontend): " CONFIG_TOKEN
read -p "Config URL (do frontend): " CONFIG_URL

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  COMANDO DE INSTALAÇÃO GERADO:"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "R2_ENDPOINT="${R2_ENDPOINT}" \"
echo "R2_BUCKET="${R2_BUCKET}" \"
echo "R2_ACCESS_KEY="${R2_ACCESS_KEY}" \"
echo "R2_SECRET_KEY="${R2_SECRET_KEY}" \"
echo "CONFIG_TOKEN="${CONFIG_TOKEN}" \"
echo "CONFIG_URL="${CONFIG_URL}" \"
echo "curl -fsSL https://raw.githubusercontent.com/samir-velleda/openconnect/main/install.sh | sudo bash"
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  COPIE O COMANDO ACIMA E EXECUTE NA LOJA"
echo "═══════════════════════════════════════════════════════════════"
echo ""
