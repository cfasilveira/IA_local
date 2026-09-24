#!/bin/bash
# Coleta dados do setup IA em um único arquivo TXT para análise

OUTPUT="auditoria-arquivos.txt"

{
  echo "=== SCRIPTS DO PROJETO ==="
  tail -n +1 ~/Projetos/AI/setup_ia.sh 2>/dev/null
  tail -n +1 ~/Projetos/AI/shutdown_ia.sh 2>/dev/null
  tail -n +1 ~/Projetos/AI/status_ia.sh 2>/dev/null
  tail -n +1 ~/Projetos/AI/docker-compose.yml 2>/dev/null

  echo -e "\n=== CONFIG OLLAMA (container) ==="
  docker exec ollama-service cat /root/.ollama/config.json 2>/dev/null

  echo -e "\n=== MODELOS INSTALADOS ==="
  docker exec ollama-service ollama list 2>/dev/null

  echo -e "\n=== MODELOS EM EXECUÇÃO ==="
  docker exec ollama-service ollama ps 2>/dev/null

  echo -e "\n=== ENV OLLAMA ==="
  docker inspect ollama-service --format '{{json .Config.Env}}' 2>/dev/null

  echo -e "\n=== ENV OPEN-WEBUI ==="
  docker inspect open-webui-gui --format '{{json .Config.Env}}' 2>/dev/null

  echo -e "\n=== VOLUMES MONTADOS ==="
  docker inspect ollama-service open-webui-gui --format '{{json .Mounts}}' 2>/dev/null

  echo -e "\n=== HARDWARE ==="
  lscpu 2>/dev/null
  free -h 2>/dev/null
  df -h / /home /workspace 2>/dev/null

  echo -e "\n=== DOCKER STATS ==="
  docker stats --no-stream 2>/dev/null

  echo -e "\n=== GPU ==="
  lspci | grep -i vga 2>/dev/null

} > "$OUTPUT"

