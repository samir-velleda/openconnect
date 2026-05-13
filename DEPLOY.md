# Deploy Guide - OpenConnect Gateway v4.0

## 🚀 Deploy no GitHub/GitLab

### 1. Criar repositório

Acesse [github.com/new](https://github.com/new) ou GitLab e crie um repositório **público** ou **privado**.

**Nome sugerido:** `openconnect-gateway`

### 2. Configurar URLs no install.sh

Edite `install.sh` e substitua os placeholders:

```bash
# ANTES (placeholders):
REPO_URL="https://github.com/samir-velleda/openconnect"
RAW_URL="https://raw.githubusercontent.com/samir-velleda/openconnect/main"

# DEPOIS (grupomateus):
REPO_URL="https://github.com/samir-velleda/openconnect"
RAW_URL="https://raw.githubusercontent.com/samir-velleda/openconnect/main"
```

### 3. Configurar config.yaml (template)

Edite `config.yaml` com valores padrão da sua infraestrutura:

```yaml
orchestrator:
  url: "https://orch.carrinhovirtual.com/process"

go2rtc:
  base_url: "https://go2rtc-t1.carrinhovirtual.com"

store:
  id: "grupomateus"
```

> ⚠️ **IMPORTANTE:** Não commit credenciais reais! Use placeholders ou variáveis de ambiente.

### 4. Validar antes do deploy

```bash
cd openconnect-gateway/
bash validate.sh
```

Deve mostrar: ✅ Todas as validações passaram!

### 5. Commit e push

```bash
cd openconnect-gateway/
git init
git add .
git commit -m "OpenConnect Gateway v4.0 - Initial release"
git branch -M main
git remote add origin https://github.com/samir-velleda/openconnect-gateway.git
git push -u origin main
```

### 6. Criar release/tag (opcional mas recomendado)

```bash
git tag -a v4.0.0 -m "Release v4.0.0 - Larga escala + Auto-update"
git push origin v4.0.0
```

### 7. Testar instalação

Em uma VM Linux limpa (Ubuntu 22.04 recomendado):

```bash
curl -fsSL https://raw.githubusercontent.com/samir-velleda/openconnect-gateway/main/install.sh | bash
```

### 8. Documentar no README

Atualize o `README.md` com:
- URL real do seu repositório
- Instruções específicas da sua infraestrutura
- Contato de suporte

---

## 🔄 Workflow de Atualização

Quando precisar atualizar o código:

1. **Edite os arquivos** localmente
2. **Teste** em ambiente de staging
3. **Commit e push** para o Git:
   ```bash
   git add .
   git commit -m "Fix: corrige timeout do go2rtc"
   git push origin main
   ```
4. **O Supervisor** detecta a mudança em ~5 minutos
5. **Backup automático** é criado
6. **Update é aplicado** nos gateways em produção
7. **Gateway reinicia** com novo código

---

## 📋 Checklist Pré-Deploy

- [ ] URLs do GitHub substituídas no `install.sh`
- [ ] `config.yaml` com valores padrão da infraestrutura
- [ ] Nenhum placeholder sensível nos arquivos
- [ ] `validate.sh` passou sem erros
- [ ] Testado em VM limpa
- [ ] Serviços systemd funcionam corretamente
- [ ] Supervisor realiza auto-update corretamente
- [ ] Health check retorna status healthy
- [ ] Backup é criado antes do update
- [ ] Rollback funciona se update falhar

---

## 🛡️ Segurança no Deploy

1. **Nunca commit credenciais** (R2 keys, webhook secrets)
2. **Use `.gitignore`** para excluir arquivos sensíveis
3. **Habilite 2FA** na conta GitHub/GitLab
4. **Restrinja acessos** ao repositório (colaboradores)
5. **Use branch protection** na `main`
6. **Reveja PRs** antes de mergear

---

## 📞 Suporte

Problemas comuns:

**"Raw URL não encontrada"**
→ Verifique se o repositório é público ou se o token de acesso está correto

**"Permissão negada ao executar install.sh"**
→ O instalador deve ser executado como root: `sudo bash install.sh`

**"Supervisor não detecta updates"**
→ Verifique `raw_url` no config.yaml e se o arquivo realmente mudou no Git
