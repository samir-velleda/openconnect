# OpenConnect v4.0 — Fluxo Completo: IP da Câmera → go2rtc → Streaming

## Visão Geral

```
Usuário cadastra câmera no Frontend
    │
    ▼
┌─────────────────────────────────────────┐
│  FRONTEND LOVABLE                       │
│  • Form: IP, usuário, senha, marca      │
│  • Monta URL RTSP baseado na marca      │
│  • Envia para edge function             │
└─────────────────────────────────────────┘
    │
    ▼ POST /functions/v1/openconnect-v4-camera-setup
┌─────────────────────────────────────────┐
│  EDGE FUNCTION (Supabase)               │
│  • Recebe dados da câmera               │
│  • Monta URL RTSP final                 │
│  • Chama API do go2rtc central          │
│  • go2rtc adiciona stream e retorna ID │
│  • Salva ID no banco (openconnect_v4_cameras)│
└─────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────┐
│  go2rtc CENTRAL                         │
│  • Recebe: src=ID & url=rtsp://...      │
│  • Adiciona stream ao go2rtc.yaml       │
│  • Disponibiliza:                       │
│    - /api/frame.jpeg?src=ID  (snapshot)│
│    - /api/webrtc?src=ID      (streaming)│
│    - /api/clip.mp4?src=ID    (clips)    │
└─────────────────────────────────────────┘
    │
    ├──► Gateway v4 (snapshot → GPU)      │
    │
    └──► Frontend (player WebRTC ao vivo) │
```

---

## 1. URLs RTSP por Marca/Modelo

A edge function monta a URL RTSP automaticamente baseado na marca:

| Marca | URL RTSP Padrão | Exemplo |
|-------|-----------------|---------|
| **Hikvision** | `rtsp://{user}:{pass}@{ip}:554/Streaming/Channels/101` | `rtsp://admin:abc123@192.168.1.101:554/Streaming/Channels/101` |
| **Intelbras** | `rtsp://{user}:{pass}@{ip}:554/cam/realmonitor?channel=1&subtype=0` | `rtsp://admin:abc123@192.168.1.101:554/cam/realmonitor?channel=1&subtype=0` |
| **Dahua** | `rtsp://{user}:{pass}@{ip}:554/cam/realmonitor?channel=1&subtype=0` | `rtsp://admin:abc123@192.168.1.101:554/cam/realmonitor?channel=1&subtype=0` |
| **TP-Link** | `rtsp://{user}:{pass}@{ip}:554/stream1` | `rtsp://admin:abc123@192.168.1.101:554/stream1` |
| **Genérico** | `rtsp://{user}:{pass}@{ip}:554/live/ch00_0` | `rtsp://admin:abc123@192.168.1.101:554/live/ch00_0` |

**subtype=0** = alta qualidade (main stream)  
**subtype=1** = baixa qualidade (sub stream)

---

## 2. API do go2rtc para Adicionar Streams

### Endpoint: POST /api/config

O go2rtc aceita atualização de config via API (requer autenticação ou estar em localhost):

```bash
curl -X POST "https://go2rtc.carrinhovirtual.com/api/config" \
  -H "Content-Type: application/json" \
  -d '{
    "streams": {
      "1013101": "rtsp://admin:pass@192.168.1.101:554/Streaming/Channels/101"
    }
  }'
```

**Resposta:**
```json
{
  "success": true,
  "streams": {
    "1013101": "rtsp://admin:pass@192.168.1.101:554/Streaming/Channels/101"
  }
}
```

### Ou via reload do go2rtc.yaml

A edge function pode também editar o arquivo `go2rtc.yaml` no servidor central via SSH/API e enviar SIGHUP para recarregar.

---

## 3. Endpoints do go2rtc para Consumo

Após adicionar a câmera, o go2rtc disponibiliza:

### Snapshot (Gateway v4 usa)
```
GET https://go2rtc.carrinhovirtual.com/api/frame.jpeg?src=1013101
```

### Streaming WebRTC (Frontend usa)
```
GET https://go2rtc.carrinhovirtual.com/api/webrtc?src=1013101
```
Retorna SDP para estabelecer conexão WebRTC.

### Streaming HLS (Frontend usa como fallback)
```
GET https://go2rtc.carrinhovirtual.com/api/hls?src=1013101
```
Retorna playlist m3u8.

### Clip de vídeo (Gateway v4 usa)
```
GET https://go2rtc.carrinhovirtual.com/api/clip.mp4?src=1013101&duration=60
```

---

## 4. Player WebRTC no Frontend

### Opção A: iframe direto (mais simples)
```html
<iframe 
  src="https://go2rtc.carrinhovirtual.com/webrtc.html?src=1013101" 
  width="640" 
  height="360"
  allow="autoplay; fullscreen"
/>
```

### Opção B: Video element com WebRTC (mais controle)
```javascript
// 1. Buscar SDP do go2rtc
const response = await fetch(
  `https://go2rtc.carrinhovirtual.com/api/webrtc?src=${cameraId}`
);
const { sdp } = await response.json();

// 2. Criar peer connection
const pc = new RTCPeerConnection();
const video = document.getElementById('video-player');

pc.ontrack = (event) => {
  video.srcObject = event.streams[0];
};

// 3. Set remote description e criar answer
await pc.setRemoteDescription(new RTCSessionDescription({ type: "offer", sdp }));
const answer = await pc.createAnswer();
await pc.setLocalDescription(answer);

// 4. Enviar answer para go2rtc
await fetch(`https://go2rtc.carrinhovirtual.com/api/webrtc?src=${cameraId}`, {
  method: "POST",
  body: answer.sdp,
});
```

### Opção C: HLS.js (fallback para browsers sem WebRTC)
```html
<video id="player" controls></video>
<script src="https://cdn.jsdelivr.net/npm/hls.js@latest"></script>
<script>
  const video = document.getElementById('player');
  const hls = new Hls();
  hls.loadSource(`https://go2rtc.carrinhovirtual.com/api/hls?src=${cameraId}`);
  hls.attachMedia(video);
</script>
```

---

## 5. Fluxo de Cadastro no Frontend (passo a passo)

### Passo 1: Formulário de Câmera
```
┌─────────────────────────────────────┐
│  Nova Câmera                        │
│                                     │
│  Nome: [Entrada Principal    ]      │
│  IP:   [192.168.1.101       ]      │
│  Porta:[554] (RTSP padrão)          │
│  Marca:[Intelbras ▼]                │
│  User: [admin               ]      │
│  Senha:[••••••••            ]      │
│                                     │
│  [ ] Snapshot  [✓] Stream  [ ] Clip │
│                                     │
│  [Salvar]                           │
└─────────────────────────────────────┘
```

### Passo 2: Edge function processa
```javascript
// Montar URL RTSP baseado na marca
const rtspUrls = {
  hikvision: `rtsp://${user}:${pass}@${ip}:554/Streaming/Channels/101`,
  intelbras: `rtsp://${user}:${pass}@${ip}:554/cam/realmonitor?channel=1&subtype=0`,
  dahua: `rtsp://${user}:${pass}@${ip}:554/cam/realmonitor?channel=1&subtype=0`,
  tplink: `rtsp://${user}:${pass}@${ip}:554/stream1`,
  generic: `rtsp://${user}:${pass}@${ip}:554/live/ch00_0`,
};

const rtspUrl = rtspUrls[marca];

// Chamar go2rtc para adicionar stream
const go2rtcResponse = await fetch(`${GO2RTC_URL}/api/config`, {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ streams: { [cameraId]: rtspUrl } }),
});

// Salvar no banco
await supabase.from("openconnect_v4_cameras").insert({
  gateway_id,
  camera_external_id: cameraId,  // ID do go2rtc (ex: 1013101)
  name,
  ip_address: ip,
  brand: marca,
  rtsp_url: rtspUrl,  // URL completa (sem credenciais em produção)
  functions: ["snapshot", "stream"],
  priority: 1,
  enabled: true,
});
```

### Passo 3: Card mostra preview
```
┌─────────────────────────────────────────┐
│  1013101 — Entrada Principal            │
│  ┌─────────────────────────────────┐   │
│  │  [VIDEO WEBRTC AO VIVO]       │   │
│  │  ou iframe do go2rtc          │   │
│  └─────────────────────────────────┘   │
│  IP: 192.168.1.101 | Marca: Intelbras   │
│  [🔄 Snapshot] [📹 Clip 1min] [⚙️]     │
└─────────────────────────────────────────┘
```

---

## 6. Segurança das Credenciais

**IMPORTANTE:** Nunca armazenar senha RTSP em texto puro no banco.

### Opção A: Criptografar no banco
- Usar `pgcrypto` do PostgreSQL
- Ou criptografia AES no edge function

### Opção B: go2rtc armazena, frontend não guarda senha
- Edge function envia RTSP URL para go2rtc
- go2rtc armazena internamente
- Banco guarda apenas IP, marca, ID — SEM senha
- Para editar: usuário re-digita senha (não preenche automático)

### Opção C: Variáveis de ambiente no go2rtc (mais seguro)
- go2rtc.yaml usa variáveis: `rtsp://{RTSP_USER}:{RTSP_PASS}@{ip}...`
- Credenciais ficam no servidor, não no banco

---

## 7. Checklist de Implementação

### Backend (Edge Function)
- [ ] Criar `openconnect-v4-camera-setup` (POST)
- [ ] Montar URL RTSP por marca
- [ ] Chamar API do go2rtc central
- [ ] Salvar ID retornado no banco
- [ ] Criptografar/omitir senha no banco

### Frontend
- [ ] Form com IP, porta, marca, user, senha
- [ ] Dropdown de marcas pré-configuradas
- [ ] Preview ao vivo (iframe ou WebRTC)
- [ ] Botão "Testar conexão" (ping RTSP)
- [ ] Mostrar ID go2rtc gerado

### go2rtc Central
- [ ] Habilitar API REST (/api/config)
- [ ] Autenticação da API (token ou IP whitelist)
- [ ] Persistência do go2rtc.yaml (reload automático)

---

## 8. Exemplo Completo de Requisição

### Frontend → Edge Function
```http
POST /functions/v1/openconnect-v4-camera-setup
Content-Type: application/json
Authorization: Bearer <jwt>

{
  "gateway_id": "6fca24aa-c274-4a47-8b65-cbe228afeb88",
  "name": "Entrada Principal",
  "ip_address": "192.168.1.101",
  "port": 554,
  "brand": "intelbras",
  "username": "admin",
  "password": "abc123",
  "functions": ["snapshot", "stream"]
}
```

### Edge Function → go2rtc
```http
POST https://go2rtc.carrinhovirtual.com/api/config
Content-Type: application/json

{
  "streams": {
    "1013101": "rtsp://admin:abc123@192.168.1.101:554/cam/realmonitor?channel=1&subtype=0"
  }
}
```

### Resposta ao Frontend
```json
{
  "success": true,
  "camera": {
    "id": "uuid-do-banco",
    "camera_external_id": "1013101",
    "name": "Entrada Principal",
    "rtsp_url": "rtsp://admin:***@192.168.1.101:554/cam/realmonitor?channel=1&subtype=0",
    "streaming_url": "https://go2rtc.carrinhovirtual.com/webrtc.html?src=1013101",
    "snapshot_url": "https://go2rtc.carrinhovirtual.com/api/frame.jpeg?src=1013101"
  }
}
```

---

**Documento criado para o Lovable implementar o fluxo completo IP → go2rtc → Streaming.**
