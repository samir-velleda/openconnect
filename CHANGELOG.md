## [10.0.0] - 2026-05-13

### Corrigido
- Versão 10.0.0 - Release final estável
- supervisor.py: import threading corrigido definitivamente
- install.sh: instala gateway + supervisor + cron + R2 automaticamente
- Todas as versões 4.0.x substituídas por 5.0.0

# Changelog

Todas as mudanças notáveis deste projeto serão documentadas aqui.

## [4.0.9] - 2026-05-13

### Corrigido
- install.sh DEFINITIVO: instala gateway + supervisor + cron + R2 + tudo automaticamente
- Supervisor agora é baixado, habilitado e iniciado corretamente via systemd
- Cron de sync configurado automaticamente quando CONFIG_TOKEN/CONFIG_URL fornecidos
- R2 Cloudflare ativado por padrão com credenciais embutidas
- README.md corrigido: URLs .com.com → .com, repo link correto
- config.yaml template corrigido: URLs sem duplicação .com
- One-liner do README aponta para samir-velleda/openconnect

## [4.0.8] - 2026-05-13

### Corrigido
- Supervisor agora é instalado e iniciado corretamente via systemd
- Arquivo `openconnect-supervisor.service` baixado e habilitado no install.sh
- Serviço do supervisor inicia automaticamente após instalação

## [4.0.7] - 2026-05-13

### Adicionado
- Credenciais R2 Cloudflare configuradas como padrão no instalador
- R2 ativado automaticamente em todas as instalações
- Bucket: openmart — Cloudflare R2

## [4.0.6] - 2026-05-13

### Adicionado
- Suporte a credenciais R2 via variáveis de ambiente: R2_ENDPOINT, R2_BUCKET, R2_ACCESS_KEY, R2_SECRET_KEY
- Quando R2_ACCESS_KEY e R2_SECRET_KEY são fornecidos, R2 é ativado automaticamente no config.yaml
- Mesmas credenciais R2 para todas as lojas (multi-tenant por bucket/prefixo)

## [4.0.5] - 2026-05-13

### Adicionado
- Gravação de clips de vídeo via go2rtc (`/api/clip.mp4`)
- Upload automático de clips para Cloudflare R2 (S3-compatible)
- Suporte a boto3/botocore para integração R2
- Configuração `clip_duration` por câmera via `custom_params`
- Limpeza automática de arquivos locais após upload R2

## [4.0.4] - 2026-05-13

### Corrigido
- Variáveis CONFIG_TOKEN e CONFIG_URL agora usam sintaxe `${VAR:-}` compatível com `set -u`
- Instalação funciona corretamente via `curl ... | sudo bash` sem precisar de `sudo -E`

## [4.0.3] - 2026-05-13

### Adicionado
- Suporte a `CONFIG_TOKEN` e `CONFIG_URL` via variáveis de ambiente
- Script `sync-config.sh` para sincronização automática do config.yaml
- Configuração automática de cron a cada 15 minutos quando token é fornecido
- Integração nativa com edge function `openconnect-v4-config` do Supabase

## [4.0.2] - 2026-05-13

### Corrigido
- Suporte a instalação não-interativa via `curl | bash` (pipe)
- Valores padrão automáticos quando stdin não é TTY
- Variáveis de ambiente `ORCH_URL`, `GO2RTC_URL`, `STORE_ID`, `THREADS`, `INTERVAL`, `WEBHOOK_SECRET` aceitas para personalização
- Elimina erro `unbound variable` em modo pipe

## [4.0.1] - 2026-05-13

### Corrigido
- Instalador agora detecta e instala automaticamente `python3-venv` quando não está presente
- Suporte para Python 3.13+ em sistemas Debian/Ubuntu sem ensurepip
- Instala `python3-pip` e `python3-dev` como dependências obrigatórias do venv

## [4.0.0] - 2026-05-13

### Adicionado
- Gateway principal com multi-threading e ThreadPoolExecutor
- Agente Supervisor com auto-update via Git
- Sistema de backup automático antes de updates
- Health check integrado com métricas JSON
- Configuração hot-reload (sem reiniciar serviço)
- Retry automático com backoff exponencial
- Pool de conexões HTTP persistente
- Graceful shutdown (SIGTERM/SIGINT)
- Scripts de diagnóstico (health_check.sh, tunnel_check.sh)
- Suporte a Ubuntu, Debian, CentOS, Rocky, Arch Linux
- Instalador one-liner automatizado
- Serviços systemd com sandbox de segurança
- HMAC-SHA256 signature em payloads
- Rate limiting configurável

### Segurança
- Serviço roda como usuário dedicado (openconnect)
- ProtectSystem=strict no systemd
- NoNewPrivileges=true
- Backup automático antes de qualquer alteração
- Validação de sintaxe Python antes de aplicar updates

## [3.0.0] - 2026-05-12
- Versão anterior com arquitetura básica
