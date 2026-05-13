# OpenConnect Gateway v10.0

[![Version](https://img.shields.io/badge/version-10.0.0-blue.svg)](https://github.com/samir-velleda/openconnect)
[![Python](https://img.shields.io/badge/python-3.8%2B-green.svg)](https://python.org)
[![License](https://img.shields.io/badge/license-MIT-yellow.svg)](LICENSE)

> Gateway de processamento de imagens para sistemas de reconhecimento facial em larga escala. 
> Desenvolvido para alta disponibilidade, auto-atualização e operação simplificada.

---

## 🚀 Instalação com Credenciais

### Opção 1: Com variáveis de ambiente (recomendado para produção)

```bash
R2_ENDPOINT="https://SEU_ACCOUNT_ID.r2.cloudflarestorage.com" \
R2_BUCKET="SEU_BUCKET" \
R2_ACCESS_KEY="SUA_ACCESS_KEY" \
R2_SECRET_KEY="SUA_SECRET_KEY" \
CONFIG_TOKEN="SEU_TOKEN" \
CONFIG_URL="https://SEU_PROJETO.supabase.co/functions/v1/openconnect-v4-config?gateway_id=SEU_ID" \
curl -fsSL https://raw.githubusercontent.com/samir-velleda/openconnect/main/install.sh | sudo bash
```

### Opção 2: Script interativo (para primeira instalação)

```bash
curl -fsSL https://raw.githubusercontent.com/samir-velleda/openconnect/main/setup.sh | bash
```

O script vai perguntar suas credenciais e gerar o comando completo.

### Opção 3: Instalação básica (sem R2)

```bash
CONFIG_TOKEN="SEU_TOKEN" \
CONFIG_URL="SEU_CONFIG_URL" \
curl -fsSL https://raw.githubusercontent.com/samir-velleda/openconnect/main/install.sh | sudo bash
```

> ⚠️ **Importante:** Nunca commite credenciais no Git. Use variáveis de ambiente.

## 🚀 Instalação Rápida (One-Liner)

Abra um terminal Linux como **root** e execute:

```bash
curl -fsSL https://raw.githubusercontent.com/samir-velleda/openconnect/main/install.sh | bash
```

O instalador irá:
1. Detectar sua distribuição Linux
2. Instalar dependências (Python, pip, curl, jq)
3. Baixar todos os arquivos do repositório
4. Criar ambiente virtual Python
5. Configurar serviços systemd
6. Iniciar o gateway automaticamente

---

## 📋 Requisitos

- **SO**: Ubuntu 20.04+, Debian 11+, CentOS 8+, Rocky Linux 8+, Arch Linux
- **Python**: 3.8 ou superior
- **Memória**: 512MB RAM mínimo (2GB recomendado para 30+ câmeras)
- **Rede**: Conexão estável com o Orchestrator e go2rtc
- **Permissões**: Acesso root ou sudo

---

## 🏗️ Arquitetura

```
┌─────────────────────────────────────────────────────────────┐
│                    LOJA (Gateway Linux)                      │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐       │
│  │   Câmeras    │  │   Câmeras    │  │   Câmeras    │       │
│  │  (go2rtc)    │  │  (go2rtc)    │  │  (go2rtc)    │       │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘       │
│         │                 │                 │                │
│  ┌──────▼─────────────────▼─────────────────▼───────┐        │
│  │      OpenConnect Gateway (Multi-Threading)       │        │
│  │  • Snapshots → Orchestrator (GPU/RunPod)         │        │
│  │  • Streaming → Dashboard                         │        │
│  │  • Clips → R2 (Cloudflare)                       │        │
│  └──────┬───────────────────────────────────────────┘        │
│         │                                                    │
│  ┌──────▼────────────┐                                       │
│  │   Supervisor      │  ← Auto-update, monitoramento,        │
│  │   (Auto-Update)   │    health check, restart automático    │
│  └───────────────────┘                                       │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                  RUNPOD / CLOUD (GPU)                          │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐       │
│  │ Orchestrator │  │   Facial     │  │  Block List  │       │
│  │   (8082)     │  │   (8087)     │  │   (8084)     │       │
│  └──────────────┘  └──────────────┘  └──────────────┘       │
└─────────────────────────────────────────────────────────────┘
```

---

## ⚙️ Configuração

Edite `/etc/openconnect-gateway/config.yaml`:

```yaml
orchestrator:
  url: "https://orch.carrinhovirtual.com/process"
  timeout: 30
  retry_attempts: 3

go2rtc:
  base_url: "https://go2rtc.carrinhovirtual.com"
  api_frame: "/api/frame.jpeg"

store:
  id: "grupomateus"

processing:
  threads: 5              # Threads paralelas
  interval_seconds: 60    # Intervalo entre ciclos
  enable_snapshots: true
  enable_streaming: true

supervisor:
  enabled: true
  auto_update: true       # Atualização automática do Git
  check_interval: 300     # Verificar a cada 5 minutos
  repo_url: "https://github.com/samir-velleda/openconnect"

cameras:
  - id: "1013101"
    name: "Entrada Principal"
    functions: ["snapshot", "stream"]
    priority: 1
```

**Recarregue sem reiniciar:**
```bash
sudo systemctl reload openconnect-gateway
```

---

## 🔧 Comandos Úteis

| Comando | Descrição |
|---------|-----------|
| `sudo systemctl status openconnect-gateway` | Status do gateway |
| `sudo systemctl restart openconnect-gateway` | Reiniciar gateway |
| `sudo systemctl status openconnect-supervisor` | Status do supervisor |
| `sudo journalctl -u openconnect-gateway -f` | Logs em tempo real |
| `sudo /opt/openconnect-gateway/scripts/health_check.sh` | Health check completo |
| `sudo /opt/openconnect-gateway/scripts/tunnel_check.sh` | Verificar túneis |

---

## 🔄 Auto-Update (Supervisor)

O **Supervisor** monitora o repositório Git a cada 5 minutos (configurável):

1. **Detecta** mudanças nos arquivos rastreados
2. **Cria backup** automático antes de atualizar
3. **Valida sintaxe** Python antes de aplicar
4. **Aplica update** de forma atômica
5. **Reinicia** o gateway com novo código
6. **Restaura backup** em caso de falha

**Arquivos rastreados:**
- `openconnect-gateway.py` (Gateway principal)
- `supervisor.py` (Auto-update)
- `requirements.txt` (Dependências)
- `scripts/health_check.sh`
- `scripts/tunnel_check.sh`

---

## 📊 Métricas

O gateway salva métricas em `/var/log/openconnect-gateway/metrics.json`:

```json
{
  "status": "healthy",
  "version": "4.0.0",
  "uptime_seconds": 86400,
  "cameras_configured": 30,
  "metrics": {
    "total_cycles": 1440,
    "total_requests": 43200,
    "successful_requests": 43150,
    "failed_requests": 50,
    "avg_response_time_ms": 245.3
  }
}
```

---

## 🛡️ Segurança

- **Webhook HMAC**: Assinatura HMAC-SHA256 em todos os payloads
- **SSL/TLS**: Verificação configurável por endpoint
- **Rate Limiting**: Controle de requisições por minuto
- **Sandbox systemd**: `ProtectSystem=strict`, `NoNewPrivileges`
- **Usuário dedicado**: Serviço roda como `openconnect` (não root)

---

## 🐛 Troubleshooting

### Gateway não inicia
```bash
sudo journalctl -u openconnect-gateway -n 50 --no-pager
sudo /opt/openconnect-gateway/scripts/health_check.sh
```

### Erro de conexão com Orchestrator
```bash
sudo /opt/openconnect-gateway/scripts/tunnel_check.sh
curl -v https://orch.carrinhovirtual.com/process
```

### Supervisor não atualiza
```bash
sudo journalctl -u openconnect-supervisor -f
# Verificar URL do raw no config.yaml
```

### Restaurar backup
```bash
# Listar backups
ls -la /opt/openconnect-gateway/.backup/
# Restaurar manualmente
sudo cp -r /opt/openconnect-gateway/.backup/backup_auto_20260513_120000/* /opt/openconnect-gateway/
sudo systemctl restart openconnect-gateway
```

---

## 📁 Estrutura do Repositório

```
openconnect-gateway/
├── install.sh                    # One-liner installer
├── openconnect-gateway.py        # Gateway principal
├── supervisor.py                 # Agente de auto-update
├── config.yaml                   # Template de configuração
├── requirements.txt              # Dependências Python
├── README.md                     # Este arquivo
├── systemd/
│   ├── openconnect-gateway.service
│   └── openconnect-supervisor.service
└── scripts/
    ├── health_check.sh           # Diagnóstico completo
    └── tunnel_check.sh           # Verificação de túneis
```

---

## 🤝 Contribuição

1. Fork o repositório
2. Crie uma branch: `git checkout -b feature/nova-funcionalidade`
3. Commit: `git commit -am 'Adiciona nova funcionalidade'`
4. Push: `git push origin feature/nova-funcionalidade`
5. Abra um Pull Request

---

## 📜 Licença

MIT License - veja [LICENSE](LICENSE) para detalhes.

---

## 📞 Suporte

- **Issues**: [GitHub Issues](https://github.com/samir-velleda/openconnect/issues)
- **Documentação**: [Wiki](https://github.com/samir-velleda/openconnect/wiki)
- **Email**: suporte@carrinhovirtual.com

---

**OpenConnect Gateway v10.0** — *Processamento inteligente de imagens em larga escala.*
