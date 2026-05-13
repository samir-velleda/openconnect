#!/usr/bin/env python3
"""
OpenConnect Tunnel Manager v1.0
==============================
Gerencia túneis Cloudflare para equipamentos FaceID/Hikvision/Intelbras.

Lê configuração de túneis do config.yaml e configura cloudflared automaticamente.
"""

import os
import sys
import yaml
import subprocess
import logging
from pathlib import Path

logger = logging.getLogger("OpenConnectTunnelManager")

class TunnelManager:
    def __init__(self, config_path: str = "/etc/openconnect-gateway/config.yaml"):
        self.config_path = config_path
        self.config = self._load_config()
        self.tunnel_cfg = self.config.get("cloudflare_tunnels", {})
        self.enabled = self.tunnel_cfg.get("enabled", False)

    def _load_config(self) -> dict:
        try:
            with open(self.config_path, "r") as f:
                return yaml.safe_load(f) or {}
        except Exception as e:
            logger.error(f"Erro ao carregar config: {e}")
            return {}

    def _check_cloudflared(self) -> bool:
        """Verifica se cloudflared está instalado."""
        try:
            result = subprocess.run(["which", "cloudflared"], capture_output=True, text=True)
            return result.returncode == 0
        except Exception:
            return False

    def _install_cloudflared(self):
        """Instala cloudflared se não estiver presente."""
        logger.info("Instalando cloudflared...")
        try:
            subprocess.run([
                "wget", "-q",
                "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb",
                "-O", "/tmp/cloudflared.deb"
            ], check=True)
            subprocess.run(["dpkg", "-i", "/tmp/cloudflared.deb"], check=False)
            subprocess.run(["apt-get", "install", "-f", "-y"], check=False)
            logger.info("cloudflared instalado")
        except Exception as e:
            logger.error(f"Falha ao instalar cloudflared: {e}")

    def _generate_config(self) -> str:
        """Gera arquivo de configuração do cloudflared."""
        tunnels = self.tunnel_cfg.get("tunnels", [])
        if not tunnels:
            return ""

        lines = ["tunnel: AUTO", "credentials-file: /etc/openconnect-gateway/.cloudflared-creds.json", ""]
        lines.append("ingress:")

        for tunnel in tunnels:
            hostname = tunnel.get("hostname", "")
            service = tunnel.get("service", "")
            if hostname and service:
                lines.append(f"  - hostname: {hostname}")
                lines.append(f"    service: {service}")

        lines.append("  - service: http_status:404")
        return "\n".join(lines)

    def _write_config(self, content: str):
        """Escreve config do cloudflared."""
        config_path = "/etc/openconnect-gateway/cloudflared-config.yml"
        try:
            with open(config_path, "w") as f:
                f.write(content)
            logger.info(f"Config cloudflared salva em {config_path}")
        except Exception as e:
            logger.error(f"Erro ao salvar config: {e}")

    def _restart_cloudflared(self):
        """Reinicia serviço cloudflared."""
        try:
            # Verificar se está rodando como systemd
            result = subprocess.run(
                ["systemctl", "is-active", "cloudflared"],
                capture_output=True, text=True
            )
            if result.returncode == 0:
                subprocess.run(["systemctl", "restart", "cloudflared"], check=True)
                logger.info("cloudflared reiniciado via systemd")
            else:
                # Matar processo antigo e iniciar novo
                subprocess.run(["pkill", "-f", "cloudflared tunnel"], check=False)
                subprocess.run([
                    "nohup", "cloudflared", "tunnel", "--config",
                    "/etc/openconnect-gateway/cloudflared-config.yml", "run"
                ], stdout=open("/dev/null", "w"), stderr=open("/dev/null", "w"))
                logger.info("cloudflared iniciado em background")
        except Exception as e:
            logger.error(f"Erro ao reiniciar cloudflared: {e}")

    def apply(self):
        """Aplica configuração de túneis."""
        if not self.enabled:
            logger.info("Túneis Cloudflare desabilitados")
            return

        if not self._check_cloudflared():
            self._install_cloudflared()

        config_content = self._generate_config()
        if config_content:
            self._write_config(config_content)
            self._restart_cloudflared()
        else:
            logger.warning("Nenhum túnel configurado")

def main():
    import logging
    logging.basicConfig(level=logging.INFO, format="%(asctime)s | %(levelname)s | %(name)s | %(message)s")

    manager = TunnelManager()
    manager.apply()

if __name__ == "__main__":
    main()
