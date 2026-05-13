# OpenConnect Gateway v4.0 - Makefile
# Uso: make help

.PHONY: help install test lint clean validate

help:
	@echo "OpenConnect Gateway v4.0 - Comandos disponíveis:"
	@echo "  make validate  - Validar sintaxe dos arquivos Python"
	@echo "  make test      - Executar testes básicos"
	@echo "  make lint      - Verificar estilo de código"
	@echo "  make clean     - Limpar arquivos temporários"
	@echo "  make install   - Instalar localmente (dev)"

validate:
	@echo "Validando sintaxe Python..."
	@python3 -m py_compile openconnect-gateway.py
	@echo "✅ openconnect-gateway.py OK"
	@python3 -m py_compile supervisor.py
	@echo "✅ supervisor.py OK"
	@echo "Todas as validações passaram!"

test:
	@echo "Executando testes..."
	@bash scripts/health_check.sh || true
	@bash scripts/tunnel_check.sh || true

lint:
	@echo "Verificando estilo..."
	@which flake8 >/dev/null 2>&1 && flake8 *.py || echo "flake8 não instalado. Instale: pip install flake8"

clean:
	@echo "Limpando..."
	@find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
	@find . -type f -name "*.pyc" -delete 2>/dev/null || true
	@find . -type f -name "*.pyo" -delete 2>/dev/null || true
	@find . -type f -name "*~" -delete 2>/dev/null || true
	@echo "Limpo!"

install:
	@echo "Instalando dependências de desenvolvimento..."
	@pip install -r requirements.txt
	@echo "Instalação completa!"
