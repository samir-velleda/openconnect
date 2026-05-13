#!/usr/bin/env python3
"""
OpenConnect Supervisor v10.0.6
===========================
Agente de supervisão e auto-atualização do OpenConnect Gateway.

Funcionalidades:
  - Monitoramento contínuo do gateway
  - Auto-update seguro do código via Git
  - Backup automático antes de atualizar
  - Health checks periódicos
  - Reinício automático em caso de falha
  - Notificações de status

Autor: OpenConnect Team
Versão: 4.0.0
"""

import os
import sys
import time
import json
import yaml
import hashlib
import signal
import logging
import subprocess
import shutil
import tempfile
import threading
import traceback
from datetime import datetime, timedelta
from pathlib import Path
from typing import Optional, Dict, List, Tuple
from dataclasses import dataclass, field, asdict
from urllib.parse import urlparse

import requests
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# ============================================================================
# CONFIGURAÇÃO DE LOGGING
# ============================================================================

def setup_logging(level: str = "INFO", log_file: str = "/var/log/openconnect-gateway/supervisor.log"):
    logger = logging.getLogger("OpenConnectSupervisor")
    logger.setLevel(getattr(logging, level.upper(), logging.INFO))
    logger.handlers = []

    formatter = logging.Formatter(
        "%(asctime)s | %(levelname)-8s | %(name)s | %(message)s"
    )

    console = logging.StreamHandler(sys.stdout)
    console.setFormatter(formatter)
    logger.addHandler(console)

    try:
        from logging.handlers import RotatingFileHandler
        os.makedirs(os.path.dirname(log_file), exist_ok=True)
        fh = RotatingFileHandler(log_file, maxBytes=50*1024*1024, backupCount=5)
        fh.setFormatter(formatter)
        logger.addHandler(fh)
    except Exception:
        pass

    return logger


# ============================================================================
# UTILITÁRIOS
# ============================================================================

class FileHash:
    """Calcula hash de arquivos para detectar mudanças."""

    @staticmethod
    def sha256_file(path: str) -> str:
        h = hashlib.sha256()
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(8192), b""):
                h.update(chunk)
        return h.hexdigest()

    @staticmethod
    def sha256_content(content: str) -> str:
        return hashlib.sha256(content.encode()).hexdigest()


class BackupManager:
    """Gerencia backups do gateway."""

    def __init__(self, backup_dir: str = "/opt/openconnect-gateway/.backup", max_backups: int = 5):
        self.backup_dir = backup_dir
        self.max_backups = max_backups
        self.logger = logging.getLogger("OpenConnectSupervisor.Backup")
        os.makedirs(backup_dir, exist_ok=True)

    def create_backup(self, source_dir: str, label: str = "auto") -> str:
        """Cria backup com timestamp."""
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        backup_name = f"backup_{label}_{timestamp}"
        backup_path = os.path.join(self.backup_dir, backup_name)

        try:
            shutil.copytree(source_dir, backup_path, ignore=shutil.ignore_patterns(
                "venv", "__pycache__", "*.pyc", ".git", ".backup"
            ))
            self.logger.info(f"Backup criado: {backup_path}")
            self._cleanup_old_backups()
            return backup_path
        except Exception as e:
            self.logger.error(f"Falha ao criar backup: {e}")
            raise

    def restore_backup(self, backup_path: str, target_dir: str) -> bool:
        """Restaura backup."""
        try:
            if os.path.exists(target_dir):
                shutil.rmtree(target_dir)
            shutil.copytree(backup_path, target_dir)
            self.logger.info(f"Backup restaurado: {backup_path} -> {target_dir}")
            return True
        except Exception as e:
            self.logger.error(f"Falha ao restaurar backup: {e}")
            return False

    def list_backups(self) -> List[str]:
        """Lista backups disponíveis (mais recentes primeiro)."""
        backups = []
        if os.path.exists(self.backup_dir):
            for name in sorted(os.listdir(self.backup_dir), reverse=True):
                path = os.path.join(self.backup_dir, name)
                if os.path.isdir(path):
                    backups.append(path)
        return backups

    def _cleanup_old_backups(self):
        """Remove backups antigos."""
        backups = self.list_backups()
        if len(backups) > self.max_backups:
            for old in backups[self.max_backups:]:
                try:
                    shutil.rmtree(old)
                    self.logger.info(f"Backup antigo removido: {old}")
                except Exception as e:
                    self.logger.warning(f"Erro ao remover backup antigo: {e}")


# ============================================================================
# AUTO-UPDATE
# ============================================================================

class AutoUpdater:
    """Sistema de auto-update via Git raw files."""

    TRACKED_FILES = [
        "openconnect-gateway.py",
        "supervisor.py",
        "requirements.txt",
        "scripts/health_check.sh",
        "scripts/tunnel_check.sh",
    ]

    def __init__(self, config: dict, install_dir: str, logger: logging.Logger):
        self.config = config.get("supervisor", {})
        self.install_dir = install_dir
        self.logger = logger
        self.raw_url = self.config.get("raw_url", "").rstrip("/")
        self.backup_mgr = BackupManager(
            backup_dir=os.path.join(install_dir, ".backup"),
            max_backups=self.config.get("max_backups", 5)
        )
        self.version_file = os.path.join(install_dir, ".version")
        self._local_hashes: Dict[str, str] = {}

    def _get_remote_hash(self, file_path: str) -> Optional[str]:
        """Busca hash remoto via HEAD request ou comparação de conteúdo."""
        url = f"{self.raw_url}/{file_path}"
        local_path = os.path.join(self.install_dir, file_path)

        try:
            response = requests.get(url, timeout=30, verify=False)
            if response.status_code == 200:
                remote_hash = FileHash.sha256_content(response.text)
                return remote_hash
        except Exception as e:
            self.logger.warning(f"Não foi possível verificar {file_path} no remoto: {e}")
        return None

    def _get_local_hash(self, file_path: str) -> str:
        """Calcula hash local do arquivo."""
        local_path = os.path.join(self.install_dir, file_path)
        if os.path.exists(local_path):
            return FileHash.sha256_file(local_path)
        return ""

    def check_for_updates(self) -> List[str]:
        """Verifica quais arquivos precisam de atualização."""
        if not self.raw_url:
            return []

        updates_needed = []
        for file_path in self.TRACKED_FILES:
            local_hash = self._get_local_hash(file_path)
            remote_hash = self._get_remote_hash(file_path)

            if remote_hash and remote_hash != local_hash:
                updates_needed.append(file_path)
                self.logger.info(f"Atualização detectada: {file_path}")

        return updates_needed

    def apply_update(self, files_to_update: List[str]) -> bool:
        """Aplica atualização de forma segura."""
        if not files_to_update:
            return True

        self.logger.info(f"Iniciando atualização de {len(files_to_update)} arquivo(s)")

        # 1. Criar backup
        try:
            backup_path = self.backup_mgr.create_backup(self.install_dir, label="pre_update")
        except Exception as e:
            self.logger.error(f"Não foi possível criar backup. Abortando update: {e}")
            return False

        # 2. Baixar arquivos para diretório temporário
        temp_dir = tempfile.mkdtemp(prefix="oc_update_")
        updated_files = []

        try:
            for file_path in files_to_update:
                url = f"{self.raw_url}/{file_path}"
                dest = os.path.join(temp_dir, file_path)
                os.makedirs(os.path.dirname(dest), exist_ok=True)

                response = requests.get(url, timeout=60, verify=False)
                if response.status_code != 200:
                    raise RuntimeError(f"Falha ao baixar {url}: {response.status_code}")

                with open(dest, "w") as f:
                    f.write(response.text)
                updated_files.append(dest)
                self.logger.info(f"Baixado: {file_path}")

            # 3. Validar sintaxe Python
            for dest in updated_files:
                if dest.endswith(".py"):
                    result = subprocess.run(
                        [sys.executable, "-m", "py_compile", dest],
                        capture_output=True,
                        text=True
                    )
                    if result.returncode != 0:
                        raise RuntimeError(f"Sintaxe inválida em {dest}: {result.stderr}")
                    self.logger.info(f"Sintaxe OK: {os.path.basename(dest)}")

            # 4. Aplicar arquivos (copiar para instalação)
            for file_path in files_to_update:
                src = os.path.join(temp_dir, file_path)
                dst = os.path.join(self.install_dir, file_path)
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                shutil.copy2(src, dst)
                if file_path.endswith(".sh"):
                    os.chmod(dst, 0o755)
                self.logger.info(f"Aplicado: {file_path}")

            # 5. Atualizar versão
            new_version = datetime.now().strftime("%Y.%m.%d-%H%M")
            with open(self.version_file, "w") as f:
                f.write(new_version)

            self.logger.info(f"✅ Atualização aplicada com sucesso. Versão: {new_version}")
            return True

        except Exception as e:
            self.logger.error(f"❌ Falha na atualização: {e}")
            self.logger.info("Restaurando backup...")
            if self.backup_mgr.restore_backup(backup_path, self.install_dir):
                self.logger.info("Backup restaurado. Sistema revertido.")
            else:
                self.logger.error("FALHA CRÍTICA: Não foi possível restaurar backup!")
            return False

        finally:
            # Limpar temp
            try:
                shutil.rmtree(temp_dir)
            except Exception:
                pass


# ============================================================================
# SUPERVISOR PRINCIPAL
# ============================================================================

class GatewaySupervisor:
    """Supervisor do gateway com monitoramento e auto-update."""

    def __init__(self, config_path: str = "/etc/openconnect-gateway/config.yaml"):
        self.config_path = config_path
        self.config = self._load_config()
        self.logger = setup_logging(
            level=self.config.get("logging", {}).get("level", "INFO"),
            log_file="/var/log/openconnect-gateway/supervisor.log"
        )

        self.running = False
        self.shutdown_event = threading.Event()
        self.gateway_pid: Optional[int] = None

        # Configurações do supervisor
        sup_cfg = self.config.get("supervisor", {})
        self.enabled = sup_cfg.get("enabled", True)
        self.check_interval = sup_cfg.get("check_interval", 300)
        self.auto_update = sup_cfg.get("auto_update", True)
        self.health_check_interval = sup_cfg.get("health_check_interval", 60)
        self.restart_on_failure = sup_cfg.get("restart_on_failure", True)
        self.max_restarts = sup_cfg.get("max_restarts", 5)
        self.restart_window = sup_cfg.get("restart_window", 3600)

        self.install_dir = "/opt/openconnect-gateway"
        self.gateway_script = os.path.join(self.install_dir, "openconnect-gateway.py")
        self.venv_python = os.path.join(self.install_dir, "venv", "bin", "python3")

        # Controle de reinícios
        self.restart_times: List[float] = []

        # Auto-updater
        self.updater = AutoUpdater(self.config, self.install_dir, self.logger)

        # Sinais
        signal.signal(signal.SIGTERM, self._signal_handler)
        signal.signal(signal.SIGINT, self._signal_handler)

        self.logger.info("=" * 60)
        self.logger.info("OpenConnect Supervisor v10.0.6 iniciando...")
        self.logger.info("=" * 60)

    def _load_config(self) -> dict:
        try:
            with open(self.config_path, "r") as f:
                return yaml.safe_load(f) or {}
        except Exception as e:
            print(f"ERRO ao carregar config: {e}")
            sys.exit(1)

    def _signal_handler(self, signum, frame):
        sig_name = "SIGTERM" if signum == signal.SIGTERM else "SIGINT"
        self.logger.info(f"Recebido {sig_name}. Encerrando supervisor...")
        self.running = False
        self.shutdown_event.set()
        self._stop_gateway()

    def _is_gateway_running(self) -> bool:
        """Verifica se o gateway está rodando."""
        if self.gateway_pid is None:
            return False
        try:
            os.kill(self.gateway_pid, 0)
            return True
        except (OSError, ProcessLookupError):
            return False

    def _start_gateway(self) -> bool:
        """Inicia o gateway como subprocesso."""
        if self._is_gateway_running():
            self.logger.info("Gateway já está rodando")
            return True

        # Verificar rate limit de reinícios
        now = time.time()
        self.restart_times = [t for t in self.restart_times if now - t < self.restart_window]
        if len(self.restart_times) >= self.max_restarts:
            self.logger.error(f"Limite de {self.max_restarts} reinícios em {self.restart_window}s atingido. Aguardando...")
            return False

        python = self.venv_python if os.path.exists(self.venv_python) else sys.executable
        env = os.environ.copy()
        env["OPENCONNECT_CONFIG"] = self.config_path

        try:
            process = subprocess.Popen(
                [python, self.gateway_script],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=env,
                cwd=self.install_dir
            )
            self.gateway_pid = process.pid
            self.restart_times.append(now)
            self.logger.info(f"Gateway iniciado (PID: {self.gateway_pid})")
            time.sleep(2)
            return self._is_gateway_running()
        except Exception as e:
            self.logger.error(f"Falha ao iniciar gateway: {e}")
            return False

    def _stop_gateway(self):
        """Para o gateway de forma graceful."""
        if self.gateway_pid and self._is_gateway_running():
            self.logger.info(f"Enviando SIGTERM para gateway (PID: {self.gateway_pid})")
            try:
                os.kill(self.gateway_pid, signal.SIGTERM)
                # Aguardar até 10s para encerrar
                for _ in range(10):
                    if not self._is_gateway_running():
                        break
                    time.sleep(1)
                if self._is_gateway_running():
                    self.logger.warning("Gateway não respondeu ao SIGTERM. Forçando SIGKILL...")
                    os.kill(self.gateway_pid, signal.SIGKILL)
            except Exception as e:
                self.logger.error(f"Erro ao parar gateway: {e}")
        self.gateway_pid = None

    def _health_check(self) -> bool:
        """Executa health check no gateway."""
        if not self._is_gateway_running():
            return False

        try:
            python = self.venv_python if os.path.exists(self.venv_python) else sys.executable
            result = subprocess.run(
                [python, self.gateway_script, "--health"],
                capture_output=True,
                text=True,
                timeout=10,
                env={**os.environ, "OPENCONNECT_CONFIG": self.config_path}
            )
            if result.returncode == 0:
                health = json.loads(result.stdout)
                if health.get("status") == "healthy":
                    return True
        except Exception as e:
            self.logger.warning(f"Health check falhou: {e}")
        return False

    def _run_update_cycle(self):
        """Verifica e aplica atualizações."""
        if not self.auto_update or not self.updater.raw_url:
            return

        try:
            updates = self.updater.check_for_updates()
            if updates:
                self.logger.info(f"Atualizações disponíveis: {updates}")
                # Parar gateway antes de atualizar
                self._stop_gateway()
                success = self.updater.apply_update(updates)
                if success:
                    # Reiniciar gateway
                    if not self._start_gateway():
                        self.logger.error("Falha ao reiniciar gateway após update")
                else:
                    # Backup já restaurado pelo updater
                    self._start_gateway()
            else:
                self.logger.debug("Nenhuma atualização disponível")
        except Exception as e:
            self.logger.error(f"Erro no ciclo de update: {e}")

    def _run_monitoring_cycle(self):
        """Ciclo de monitoramento do gateway."""
        if not self._is_gateway_running():
            self.logger.warning("Gateway não está rodando!")
            if self.restart_on_failure:
                self.logger.info("Tentando reiniciar gateway...")
                if not self._start_gateway():
                    self.logger.error("Falha ao reiniciar gateway")
            return

        # Health check periódico
        if self.health_check_interval > 0:
            if not self._health_check():
                self.logger.warning("Health check falhou! Reiniciando gateway...")
                self._stop_gateway()
                time.sleep(2)
                self._start_gateway()

    def run(self):
        """Loop principal do supervisor."""
        if not self.enabled:
            self.logger.info("Supervisor desabilitado na configuração. Encerrando.")
            return

        self.running = True

        # Iniciar gateway se não estiver rodando
        if not self._is_gateway_running():
            self._start_gateway()

        last_update_check = 0
        last_health_check = 0

        self.logger.info("Supervisor em execução. Monitorando gateway...")

        while self.running and not self.shutdown_event.is_set():
            try:
                now = time.time()

                # Ciclo de monitoramento
                self._run_monitoring_cycle()

                # Health check
                if now - last_health_check >= self.health_check_interval:
                    last_health_check = now

                # Ciclo de update
                if now - last_update_check >= self.check_interval:
                    self._run_update_cycle()
                    last_update_check = now

                # Aguardar
                if self.shutdown_event.wait(timeout=10):
                    break

            except Exception as e:
                self.logger.error(f"Erro no loop do supervisor: {e}")
                self.logger.error(traceback.format_exc())
                time.sleep(5)

        self.logger.info("Supervisor encerrado.")
        self._stop_gateway()


def main():
    config_path = os.environ.get("OPENCONNECT_CONFIG", "/etc/openconnect-gateway/config.yaml")
    supervisor = GatewaySupervisor(config_path)
    supervisor.run()


if __name__ == "__main__":
    main()
