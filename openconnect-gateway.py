#!/usr/bin/env python3
"""
OpenConnect Gateway v10.0.6
========================
Gateway de processamento de imagens para sistema de reconhecimento facial.
Envia snapshots para GPU (Orchestrator) e clips para R2.

Arquitetura:
  - Multi-threading com pool de workers
  - Retry automático com backoff exponencial
  - Health check integrado
  - Graceful shutdown
  - Métricas e telemetria

Autor: OpenConnect Team
Versão: 4.0.0
"""

import os
import sys
import time
import json
import yaml
import signal
import base64
import hashlib
import hmac
import logging
import threading
import queue
import subprocess
import tempfile
import traceback
from datetime import datetime, timedelta
from pathlib import Path
from typing import Dict, List, Optional, Tuple, Any
from dataclasses import dataclass, field, asdict
from concurrent.futures import ThreadPoolExecutor, as_completed
from urllib.parse import urljoin, urlparse

import requests
import urllib3
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

# Desabilitar warnings SSL (ambiente controlado)
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# ============================================================================
# CONFIGURAÇÃO DE LOGGING
# ============================================================================

def setup_logging(config: dict) -> logging.Logger:
    """Configura logging com rotação de arquivos."""
    log_cfg = config.get("logging", {})
    level = getattr(logging, log_cfg.get("level", "INFO").upper(), logging.INFO)
    log_file = log_cfg.get("file", "/var/log/openconnect-gateway/gateway.log")
    log_format = log_cfg.get(
        "format",
        "%(asctime)s | %(levelname)-8s | %(name)s | %(message)s"
    )

    logger = logging.getLogger("OpenConnectGateway")
    logger.setLevel(level)
    logger.handlers = []

    formatter = logging.Formatter(log_format)

    # Handler de console
    console = logging.StreamHandler(sys.stdout)
    console.setLevel(level)
    console.setFormatter(formatter)
    logger.addHandler(console)

    # Handler de arquivo com rotação simples
    try:
        from logging.handlers import RotatingFileHandler
        max_size = log_cfg.get("max_size_mb", 100) * 1024 * 1024
        backup_count = log_cfg.get("backup_count", 10)
        os.makedirs(os.path.dirname(log_file), exist_ok=True)
        file_handler = RotatingFileHandler(
            log_file, maxBytes=max_size, backupCount=backup_count
        )
        file_handler.setLevel(level)
        file_handler.setFormatter(formatter)
        logger.addHandler(file_handler)
    except Exception as e:
        logger.warning(f"Não foi possível configurar log em arquivo: {e}")

    return logger


# ============================================================================
# ESTRUTURAS DE DADOS
# ============================================================================

@dataclass
class CameraConfig:
    """Configuração de uma câmera."""
    id: str
    name: str = ""
    functions: List[str] = field(default_factory=lambda: ["snapshot"])
    priority: int = 1
    enabled: bool = True
    custom_params: Dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict:
        return asdict(self)


@dataclass
class ProcessingResult:
    """Resultado do processamento de uma câmera."""
    camera_id: str
    success: bool
    function: str
    timestamp: str
    duration_ms: float
    status_code: Optional[int] = None
    error: Optional[str] = None
    payload_size: int = 0
    response_preview: str = ""


@dataclass
class GatewayMetrics:
    """Métricas do gateway."""
    start_time: datetime = field(default_factory=datetime.now)
    total_cycles: int = 0
    total_requests: int = 0
    successful_requests: int = 0
    failed_requests: int = 0
    avg_response_time_ms: float = 0.0
    last_cycle_time: Optional[datetime] = None
    cameras_processed: int = 0
    errors_by_camera: Dict[str, int] = field(default_factory=dict)
    last_error: Optional[str] = None
    uptime_seconds: float = 0.0

    def to_dict(self) -> dict:
        data = asdict(self)
        data["start_time"] = self.start_time.isoformat()
        data["last_cycle_time"] = self.last_cycle_time.isoformat() if self.last_cycle_time else None
        data["uptime_seconds"] = (datetime.now() - self.start_time).total_seconds()
        return data


# ============================================================================
# CLIENTE HTTP ROBUSTO
# ============================================================================

class RobustHTTPClient:
    """Cliente HTTP com retry, timeout e pooling de conexões."""

    def __init__(self, timeout: int = 30, retries: int = 3, verify_ssl: bool = True):
        self.timeout = timeout
        self.verify_ssl = verify_ssl
        self.logger = logging.getLogger("OpenConnectGateway.HTTP")

        self.session = requests.Session()

        retry_strategy = Retry(
            total=retries,
            backoff_factor=1,
            status_forcelist=[429, 500, 502, 503, 504],
            allowed_methods=["HEAD", "GET", "POST", "PUT", "DELETE", "OPTIONS", "TRACE"]
        )

        adapter = HTTPAdapter(
            max_retries=retry_strategy,
            pool_connections=20,
            pool_maxsize=50
        )

        self.session.mount("http://", adapter)
        self.session.mount("https://", adapter)

    def request(self, method: str, url: str, **kwargs) -> requests.Response:
        """Executa request com tratamento de erro."""
        kwargs.setdefault("timeout", self.timeout)
        kwargs.setdefault("verify", self.verify_ssl)

        start = time.time()
        try:
            response = self.session.request(method, url, **kwargs)
            duration = (time.time() - start) * 1000
            self.logger.debug(f"{method} {url} -> {response.status_code} ({duration:.1f}ms)")
            return response
        except requests.exceptions.Timeout:
            self.logger.error(f"Timeout em {method} {url} após {self.timeout}s")
            raise
        except requests.exceptions.ConnectionError as e:
            self.logger.error(f"Erro de conexão em {method} {url}: {e}")
            raise
        except Exception as e:
            self.logger.error(f"Erro inesperado em {method} {url}: {e}")
            raise

    def get(self, url: str, **kwargs) -> requests.Response:
        return self.request("GET", url, **kwargs)

    def post(self, url: str, **kwargs) -> requests.Response:
        return self.request("POST", url, **kwargs)

    def close(self):
        self.session.close()


# ============================================================================
# GATEWAY PRINCIPAL
# ============================================================================

class OpenConnectGateway:
    """Gateway principal de processamento de imagens."""

    def __init__(self, config_path: str = "/etc/openconnect-gateway/config.yaml"):
        self.config_path = config_path
        self.config = self._load_config()
        self.logger = setup_logging(self.config)
        self.logger.info("=" * 60)
        self.logger.info("OpenConnect Gateway v10.0.6 iniciando...")
        self.logger.info("=" * 60)

        self.running = False
        self.shutdown_event = threading.Event()
        self.metrics = GatewayMetrics()
        self.lock = threading.RLock()

        # Cliente HTTP
        orch_cfg = self.config.get("orchestrator", {})
        self.http = RobustHTTPClient(
            timeout=orch_cfg.get("timeout", 30),
            retries=orch_cfg.get("retry_attempts", 3),
            verify_ssl=orch_cfg.get("verify_ssl", True)
        )

        # Configurações
        self.orch_url = orch_cfg.get("url", "").rstrip("/")
        self.fallback_url = orch_cfg.get("fallback_url", "").rstrip("/")
        self.go2rtc_base = self.config.get("go2rtc", {}).get("base_url", "").rstrip("/")
        self.go2rtc_api = self.config.get("go2rtc", {}).get("api_frame", "/api/frame.jpeg")
        self.store_id = self.config.get("store", {}).get("id", "default")
        self.webhook_secret = self.config.get("security", {}).get("webhook_secret", "")

        proc_cfg = self.config.get("processing", {})
        self.num_threads = proc_cfg.get("threads", 5)
        self.interval = proc_cfg.get("interval_seconds", 60)
        self.batch_size = proc_cfg.get("batch_size", 10)
        self.enable_snapshots = proc_cfg.get("enable_snapshots", True)
        self.enable_streaming = proc_cfg.get("enable_streaming", True)
        self.enable_clips = proc_cfg.get("enable_clips", False)

        # Câmeras
        self.cameras: List[CameraConfig] = []
        self._load_cameras()

        # Sinais
        signal.signal(signal.SIGTERM, self._signal_handler)
        signal.signal(signal.SIGINT, self._signal_handler)

        self.logger.info(f"Configuração carregada: {len(self.cameras)} câmeras, {self.num_threads} threads, {self.interval}s intervalo")

    def _load_config(self) -> dict:
        """Carrega configuração do YAML."""
        try:
            with open(self.config_path, "r") as f:
                return yaml.safe_load(f) or {}
        except FileNotFoundError:
            print(f"ERRO: Arquivo de configuração não encontrado: {self.config_path}")
            sys.exit(1)
        except yaml.YAMLError as e:
            print(f"ERRO: Configuração YAML inválida: {e}")
            sys.exit(1)

    def _load_cameras(self):
        """Carrega configurações das câmeras."""
        cam_list = self.config.get("cameras", [])
        self.cameras = []
        for cam in cam_list:
            if isinstance(cam, dict):
                self.cameras.append(CameraConfig(
                    id=str(cam.get("id", "")),
                    name=cam.get("name", ""),
                    functions=cam.get("functions", ["snapshot"]),
                    priority=cam.get("priority", 1),
                    enabled=cam.get("enabled", True),
                    custom_params=cam.get("custom_params", {})
                ))
        # Ordenar por prioridade
        self.cameras.sort(key=lambda c: c.priority)

    def _signal_handler(self, signum, frame):
        """Handler de sinais para shutdown graceful."""
        sig_name = "SIGTERM" if signum == signal.SIGTERM else "SIGINT"
        self.logger.info(f"Recebido {sig_name}. Iniciando shutdown graceful...")
        self.running = False
        self.shutdown_event.set()

    def _generate_signature(self, payload: str) -> str:
        """Gera HMAC-SHA256 do payload."""
        if not self.webhook_secret:
            return ""
        return hmac.new(
            self.webhook_secret.encode(),
            payload.encode(),
            hashlib.sha256
        ).hexdigest()

    def _fetch_snapshot(self, camera: CameraConfig) -> Optional[bytes]:
        """Busca snapshot do go2rtc."""
        if not self.go2rtc_base:
            return None

        url = f"{self.go2rtc_base}{self.go2rtc_api}"
        params = {"src": camera.id}
        params.update(camera.custom_params.get("snapshot_params", {}))

        try:
            verify = self.config.get("go2rtc", {}).get("verify_ssl", True)
            response = self.http.get(url, params=params, verify=verify, stream=True)
            if response.status_code == 200:
                return response.content
            else:
                self.logger.warning(f"Camera {camera.id}: go2rtc retornou {response.status_code}")
                return None
        except Exception as e:
            self.logger.error(f"Camera {camera.id}: Erro ao buscar snapshot: {e}")
            return None

    def _send_to_orchestrator(self, camera: CameraConfig, image_data: bytes, function: str) -> ProcessingResult:
        """Envia imagem para o orchestrator."""
        start_time = time.time()
        timestamp = datetime.now().isoformat()

        if not self.orch_url:
            return ProcessingResult(
                camera_id=camera.id,
                success=False,
                function=function,
                timestamp=timestamp,
                duration_ms=0,
                error="URL do orchestrator não configurada"
            )

        # Preparar payload
        image_b64 = base64.b64encode(image_data).decode("utf-8")
        payload = {
            "camera_id": camera.id,
            "store_id": self.store_id,
            "timestamp": timestamp,
            "function": function,
            "image": image_b64,
            "metadata": {
                "camera_name": camera.name,
                "priority": camera.priority,
                "gateway_version": "10.0.6"
            }
        }

        payload_json = json.dumps(payload, separators=(",", ":"))
        headers = {
            "Content-Type": "application/json",
            "X-Gateway-Version": "10.0.6",
            "X-Store-ID": self.store_id,
            "X-Camera-ID": camera.id
        }

        signature = self._generate_signature(payload_json)
        if signature:
            headers["X-Webhook-Signature"] = f"sha256={signature}"

        urls_to_try = [self.orch_url]
        if self.fallback_url:
            urls_to_try.append(self.fallback_url)

        last_error = None
        for url in urls_to_try:
            try:
                response = self.http.post(
                    url,
                    data=payload_json,
                    headers=headers
                )

                duration_ms = (time.time() - start_time) * 1000

                if response.status_code in (200, 201, 202):
                    preview = response.text[:200] if response.text else "OK"
                    return ProcessingResult(
                        camera_id=camera.id,
                        success=True,
                        function=function,
                        timestamp=timestamp,
                        duration_ms=duration_ms,
                        status_code=response.status_code,
                        payload_size=len(payload_json),
                        response_preview=preview
                    )
                else:
                    last_error = f"HTTP {response.status_code}: {response.text[:200]}"
                    self.logger.warning(f"Camera {camera.id}: {url} retornou {response.status_code}")

            except Exception as e:
                last_error = str(e)
                self.logger.error(f"Camera {camera.id}: Erro ao enviar para {url}: {e}")

        duration_ms = (time.time() - start_time) * 1000
        return ProcessingResult(
            camera_id=camera.id,
            success=False,
            function=function,
            timestamp=timestamp,
            duration_ms=duration_ms,
            error=last_error or "Erro desconhecido"
        )


    def _record_clip(self, camera: CameraConfig) -> Optional[str]:
        """Grava um clip de vídeo do go2rtc."""
        if not self.go2rtc_base:
            return None

        duration = camera.custom_params.get("clip_duration", 60)
        url = f"{self.go2rtc_base}/api/clip.mp4"
        params = {"src": camera.id, "duration": duration}

        try:
            temp_file = tempfile.NamedTemporaryFile(suffix=".mp4", delete=False)
            temp_path = temp_file.name
            temp_file.close()

            verify = self.config.get("go2rtc", {}).get("verify_ssl", True)
            response = self.http.get(url, params=params, verify=verify, stream=True, timeout=duration + 30)

            if response.status_code == 200:
                with open(temp_path, "wb") as f:
                    for chunk in response.iter_content(chunk_size=8192):
                        f.write(chunk)
                self.logger.info(f"Camera {camera.id}: Clip gravado ({duration}s) -> {temp_path}")
                return temp_path
            else:
                self.logger.warning(f"Camera {camera.id}: go2rtc clip retornou {response.status_code}")
                return None
        except Exception as e:
            self.logger.error(f"Camera {camera.id}: Erro ao gravar clip: {e}")
            return None

    def _upload_to_r2(self, camera: CameraConfig, file_path: str) -> bool:
        """Faz upload do clip para Cloudflare R2."""
        r2_cfg = self.config.get("r2", {})
        if not r2_cfg.get("enabled", False):
            self.logger.debug(f"Camera {camera.id}: R2 desabilitado, mantendo clip local")
            return False

        endpoint = r2_cfg.get("endpoint", "")
        bucket = r2_cfg.get("bucket", "")
        access_key = r2_cfg.get("access_key", "")
        secret_key = r2_cfg.get("secret_key", "")
        region = r2_cfg.get("region", "auto")

        if not all([endpoint, bucket, access_key, secret_key]):
            self.logger.warning(f"Camera {camera.id}: Credenciais R2 incompletas")
            return False

        try:
            import boto3
            from botocore.config import Config

            s3 = boto3.client(
                "s3",
                endpoint_url=endpoint,
                aws_access_key_id=access_key,
                aws_secret_access_key=secret_key,
                region_name=region,
                config=Config(signature_version="s3v4")
            )

            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            key = f"clips/{self.store_id}/{camera.id}/{timestamp}.mp4"

            s3.upload_file(file_path, bucket, key, ExtraArgs={"ContentType": "video/mp4"})
            self.logger.info(f"Camera {camera.id}: Clip uploadado para R2: {key}")

            # Limpar arquivo local
            os.remove(file_path)
            return True

        except ImportError:
            self.logger.error("boto3 não instalado. Instale: pip install boto3")
            return False
        except Exception as e:
            self.logger.error(f"Camera {camera.id}: Erro no upload R2: {e}")
            return False

    def _process_camera(self, camera: CameraConfig) -> List[ProcessingResult]:
        """Processa uma câmera (todas as suas funções)."""
        results = []

        if not camera.enabled:
            return results

        for function in camera.functions:
            if function == "snapshot" and self.enable_snapshots:
                image = self._fetch_snapshot(camera)
                if image:
                    result = self._send_to_orchestrator(camera, image, "snapshot")
                    results.append(result)
                else:
                    results.append(ProcessingResult(
                        camera_id=camera.id,
                        success=False,
                        function="snapshot",
                        timestamp=datetime.now().isoformat(),
                        duration_ms=0,
                        error="Falha ao capturar imagem do go2rtc"
                    ))
            elif function == "stream" and self.enable_streaming:
                # Streaming é gerenciado separadamente (WebRTC ou HLS)
                pass
            elif function == "clip" and self.enable_clips:
                clip_path = self._record_clip(camera)
                if clip_path:
                    uploaded = self._upload_to_r2(camera, clip_path)
                    results.append(ProcessingResult(
                        camera_id=camera.id,
                        success=uploaded,
                        function="clip",
                        timestamp=datetime.now().isoformat(),
                        duration_ms=0,
                        error=None if uploaded else "Falha no upload R2"
                    ))
                else:
                    results.append(ProcessingResult(
                        camera_id=camera.id,
                        success=False,
                        function="clip",
                        timestamp=datetime.now().isoformat(),
                        duration_ms=0,
                        error="Falha ao gravar clip"
                    ))

        return results

    def _update_metrics(self, results: List[ProcessingResult]):
        """Atualiza métricas com os resultados."""
        with self.lock:
            self.metrics.total_cycles += 1
            self.metrics.last_cycle_time = datetime.now()

            for r in results:
                self.metrics.total_requests += 1
                if r.success:
                    self.metrics.successful_requests += 1
                else:
                    self.metrics.failed_requests += 1
                    self.metrics.errors_by_camera[r.camera_id] = self.metrics.errors_by_camera.get(r.camera_id, 0) + 1
                    if r.error:
                        self.metrics.last_error = f"[{r.camera_id}] {r.error}"

            # Média móvel de tempo de resposta
            durations = [r.duration_ms for r in results if r.success]
            if durations:
                current_avg = sum(durations) / len(durations)
                n = self.metrics.successful_requests
                self.metrics.avg_response_time_ms = (
                    (self.metrics.avg_response_time_ms * (n - len(durations)) + sum(durations)) / n
                )

    def _log_cycle_summary(self, results: List[ProcessingResult], cycle_duration: float):
        """Log do resumo do ciclo."""
        success = sum(1 for r in results if r.success)
        failed = len(results) - success
        avg_time = sum(r.duration_ms for r in results if r.success) / max(success, 1)

        status = "✅" if failed == 0 else f"⚠️  ({failed} falhas)"
        self.logger.info(
            f"Ciclo #{self.metrics.total_cycles} completo {status} | "
            f"Sucesso: {success}/{len(results)} | "
            f"Média: {avg_time:.0f}ms | "
            f"Duração: {cycle_duration:.1f}s"
        )

        if failed > 0:
            for r in results:
                if not r.success:
                    self.logger.warning(f"  → Falha camera {r.camera_id} ({r.function}): {r.error}")

    def _run_cycle(self):
        """Executa um ciclo completo de processamento."""
        cycle_start = time.time()
        all_results: List[ProcessingResult] = []

        if not self.cameras:
            self.logger.warning("Nenhuma câmera configurada. Pulando ciclo.")
            return

        # Processar em paralelo com ThreadPoolExecutor
        with ThreadPoolExecutor(max_workers=self.num_threads) as executor:
            future_to_camera = {
                executor.submit(self._process_camera, cam): cam
                for cam in self.cameras
            }

            for future in as_completed(future_to_camera):
                camera = future_to_camera[future]
                try:
                    results = future.result(timeout=60)
                    all_results.extend(results)
                except Exception as e:
                    self.logger.error(f"Camera {camera.id}: Exceção não tratada: {e}")
                    all_results.append(ProcessingResult(
                        camera_id=camera.id,
                        success=False,
                        function="unknown",
                        timestamp=datetime.now().isoformat(),
                        duration_ms=0,
                        error=f"Exceção: {str(e)[:200]}"
                    ))

        cycle_duration = time.time() - cycle_start
        self._update_metrics(all_results)
        self._log_cycle_summary(all_results, cycle_duration)

    def _reload_config_if_changed(self):
        """Recarrega configuração se o arquivo mudou."""
        try:
            mtime = os.path.getmtime(self.config_path)
            if not hasattr(self, "_last_config_mtime"):
                self._last_config_mtime = mtime
                return

            if mtime > self._last_config_mtime:
                self.logger.info("Configuração modificada. Recarregando...")
                self.config = self._load_config()
                self._load_cameras()
                self._last_config_mtime = mtime
                self.logger.info(f"Config recarregada: {len(self.cameras)} câmeras")
        except Exception as e:
            self.logger.error(f"Erro ao recarregar config: {e}")

    def run(self):
        """Loop principal do gateway."""
        self.running = True
        self.logger.info("Gateway iniciado. Pressione Ctrl+C para parar.")

        while self.running and not self.shutdown_event.is_set():
            try:
                self._reload_config_if_changed()
                self._run_cycle()

                # Aguardar até o próximo ciclo ou shutdown
                if self.shutdown_event.wait(timeout=self.interval):
                    break
            except Exception as e:
                self.logger.error(f"Erro no loop principal: {e}")
                self.logger.error(traceback.format_exc())
                self.metrics.last_error = str(e)
                time.sleep(5)  # Evitar loop de erro rápido

        self.logger.info("Gateway encerrado.")
        self._save_metrics()

    def _save_metrics(self):
        """Salva métricas finais em JSON."""
        try:
            metrics_file = "/var/log/openconnect-gateway/metrics.json"
            os.makedirs(os.path.dirname(metrics_file), exist_ok=True)
            with open(metrics_file, "w") as f:
                json.dump(self.metrics.to_dict(), f, indent=2)
        except Exception as e:
            self.logger.error(f"Erro ao salvar métricas: {e}")

    def get_health(self) -> dict:
        """Retorna status de saúde do gateway."""
        uptime = (datetime.now() - self.metrics.start_time).total_seconds()
        return {
            "status": "healthy" if self.running else "stopped",
            "version": "4.0.0",
            "uptime_seconds": int(uptime),
            "cameras_configured": len(self.cameras),
            "cameras_enabled": sum(1 for c in self.cameras if c.enabled),
            "metrics": self.metrics.to_dict()
        }

    def reload(self):
        """Recarrega configuração sob demanda."""
        self.logger.info("Reload solicitado via SIGHUP")
        self.config = self._load_config()
        self._load_cameras()


def main():
    config_path = os.environ.get("OPENCONNECT_CONFIG", "/etc/openconnect-gateway/config.yaml")
    gateway = OpenConnectGateway(config_path)

    # Verificar se é apenas health check
    if len(sys.argv) > 1 and sys.argv[1] == "--health":
        print(json.dumps(gateway.get_health(), indent=2))
        return

    gateway.run()


if __name__ == "__main__":
    main()
