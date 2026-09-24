#!/usr/bin/env bash
# shutdown_ia.sh v3.4 - Encerramento seguro + Gestão automática de logs
set -euo pipefail
GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

BASE_DIR="/home/carlos/Projetos/AI"
LOG="${BASE_DIR}/shutdown_$(date +%Y%m%d_%H%M%S).log"
log() { echo -e "${CYAN}[INFO]${NC} $(date '+%H:%M:%S') - $1" | tee -a "$LOG"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $(date '+%H:%M:%S') - $1" | tee -a "$LOG"; }

echo -e "${CYAN}⏹️  Encerrando Laboratório de IA em ${BASE_DIR}...${NC}"

if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^ollama-service$"; then
    MODELS=$(docker exec ollama-service ollama ps 2>/dev/null | tail -n +2 | awk '{print $1}' || true)
    if [[ -n "$MODELS" ]]; then
        echo "$MODELS" | while read -r model; do
            [[ -z "$model" ]] && continue
            log "   ↪ Forçando unload de: $model"
            docker exec ollama-service curl -s -X POST http://localhost:11434/api/generate -d "{\"model\": \"$model\", \"keep_alive\": 0}" >/dev/null 2>&1 || true
        done
        sleep 2
    else
        log "   ℹ️ Nenhum modelo carregado na RAM"
    fi
else
    warn "⚠️ Container ollama-service não encontrado"
fi

log "📦 Parando containers..."
for c in open-webui-gui ollama-service; do
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${c}$" && {
        docker stop "$c" >/dev/null 2>&1 && log "   ✅ $c parado" || warn "⚠️ Falha ao parar $c"
    }
done

log "🧹 Liberando caches..."
sudo sync 2>/dev/null && echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true

log "📂 Analisando logs..."
MAX_LOG_MB=50
RETENTION_DAYS=7
find "$BASE_DIR" -maxdepth 1 -name "*.log" -mtime +$RETENTION_DAYS -delete 2>/dev/null || true

CURRENT_KB=$(find "$BASE_DIR" -maxdepth 1 -name "*.log" -printf "%k\n" 2>/dev/null | awk '{s+=$1} END {print s+0}')
CURRENT_MB=$((CURRENT_KB / 1024))
if [[ "$CURRENT_MB" -ge "$MAX_LOG_MB" ]]; then
    ARCHIVE="logs_archive_$(date +%Y%m%d_%H%M%S).tar.gz"
    find "$BASE_DIR" -maxdepth 1 -name "*.log" -printf "%f\n" 2>/dev/null | tar -czf "${BASE_DIR}/${ARCHIVE}" -C "$BASE_DIR" -T - 2>/dev/null
    rm -f "${BASE_DIR}"/*.log
    log "   ✅ Logs comprimidos em: ${ARCHIVE}"
else
    log "   ✅ Logs OK (${CURRENT_MB}MB / ${MAX_LOG_MB}MB)"
fi

MEM_FREE=$(free -h | awk '/^Mem:/{print $7}')
SWAP_USED=$(free -h | awk '/^Swap:/{print $3}')
echo -e "\n${GREEN}╔════════════════════════════════╗${NC}"
echo -e "${GREEN}║  ✅ Shutdown concluído         ║${NC}"
echo -e "${GREEN}╚════════════════════════════════╝${NC}"
echo -e "${CYAN}Memória:${NC} Disponível ${MEM_FREE} | Swap usado ${SWAP_USED}"
echo -e "${YELLOW}Próximo:${NC} ./setup_ia.sh para reiniciar"
