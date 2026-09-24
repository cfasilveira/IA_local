#!/usr/bin/env bash
# ollama-tui.sh v7.1 - TUI ultra-resiliente (zero exit silencioso)
# Uso: bash ~/Projetos/AI/ollama-tui.sh │ Saída: Ctrl+C

# NÃO usar set -e ou pipefail aqui — queremos tolerância a falhas
set -u

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
REFRESH=2; CONTAINER="ollama-service"; API="http://localhost:11434"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo /tmp)"
LOG="${SCRIPT_DIR}/tui_$(date +%Y%m%d_%H%M%S).log"

log_tui() { echo "[$(date '+%H:%M:%S')] $1" >> "$LOG" 2>/dev/null || true; }
trap 'tput cnorm 2>/dev/null; clear; echo -e "${CYAN}📊 Dashboard encerrado.${NC}"; log_tui "Encerrado"; exit 0' INT TERM EXIT

# Testar se é TTY antes de usar tput
if tty -s 2>/dev/null; then
    clear 2>/dev/null || true
    tput civis 2>/dev/null || true
fi
log_tui "Iniciado"

# Barra ASCII (tolerante a erros)
bar() {
    local p="${1:-0}"
    p="${p%%.*}"  # Remove decimal
    [[ "$p" =~ ^[0-9]+$ ]] || p=0
    [[ "$p" -gt 100 ]] && p=100
    [[ "$p" -lt 0 ]] && p=0
    local f=$((p / 5)); local e=$((20 - f))
    local c="$GREEN"
    [[ "$p" -ge 85 ]] && c="$RED"
    [[ "$p" -ge 60 && "$p" -lt 85 ]] && c="$YELLOW"
    local out=""; local i
    for ((i=0; i<f; i++)); do out+="█"; done
    for ((i=0; i<e; i++)); do out+="░"; done
    printf "${c}[%s]${NC} %3s%%" "$out" "$p"
}

while true; do
    tty -s 2>/dev/null && clear
    START=$(date +%s 2>/dev/null || echo "0")
    log_tui "Refresh cycle"
    
    # Header (sempre funciona)
    echo -e "${CYAN}📊 OLLAMA CPU-NATIVE${NC} (Ctrl+C sair) │ Atualiza: ${REFRESH}s"
    echo ""
    
    # Boxes
    echo -e "${BLUE}╭──────────────────────────────────────╮${NC}   ${BLUE}╭──────────────────────────────────────╮${NC}"
    echo -e "${BLUE}│${NC} 🖥️ SISTEMA                           ${BLUE}│${NC}   ${BLUE}│${NC} 🐳 DOCKER: ${CONTAINER}               ${BLUE}│${NC}"
    
    # System data (com fallbacks robustos)
    RT=$(free -g 2>/dev/null | awk '/^Mem:/{print $2}' 2>/dev/null) || RT=31
    RU=$(free -g 2>/dev/null | awk '/^Mem:/{print $3}' 2>/dev/null) || RU=0
    [[ "$RT" =~ ^[0-9]+$ && "$RT" -gt 0 ]] || RT=31
    [[ "$RU" =~ ^[0-9]+$ ]] || RU=0
    RP=$(( RU * 100 / RT ))  # Bash arithmetic, sem awk
    
    LD=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null) || LD="0.0"
    SW=$(free -g 2>/dev/null | awk '/^Swap:/{print $3}' 2>/dev/null) || SW="0"
    GV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null) || GV="N/A"
    
    # ZRAM (tolerante)
    ZP=0
    if command -v zramctl &>/dev/null; then
        ZD=$(zramctl 2>/dev/null | awk 'NR>1{gsub(/G|M/,""); print $3,$2}' 2>/dev/null) || ZD=""
        if [[ -n "$ZD" ]]; then
            ZU=$(echo "$ZD" | awk '{print $1}' 2>/dev/null) || ZU=0
            ZT=$(echo "$ZD" | awk '{print $2}' 2>/dev/null) || ZT=1
            [[ "$ZT" =~ ^[0-9]+$ && "$ZT" -gt 0 ]] && ZP=$(( ZU * 100 / ZT )) || ZP=0
        fi
    fi
    
    # Status do container (fallback seguro)
    DOCKER_STATUS="N/A"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER}$"; then
        DOCKER_STATUS=$(docker ps --format '{{.Status}}' -f "name=$CONTAINER" 2>/dev/null | cut -d' ' -f1) || DOCKER_STATUS="Running"
    fi
    
    echo -e "${BLUE}│${NC} RAM: $(bar "$RP")          ${BLUE}│${NC}   ${BLUE}│${NC} Status: ${DOCKER_STATUS} ${BLUE}│${NC}"
    echo -e "${BLUE}│${NC} Load: ${LD} │ Swap: ${SW}G        ${BLUE}│${NC}   ${BLUE}│${NC}                                               ${BLUE}│${NC}"
    echo -e "${BLUE}│${NC} Gov: ${GV} │ ZRAM: $(bar "$ZP")   ${BLUE}│${NC}   ${BLUE}│${NC}                                               ${BLUE}│${NC}"
    
    # Docker stats (com fallback)
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER}$"; then
        ST=$(docker stats "$CONTAINER" --no-stream --format '{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}' 2>/dev/null) || ST="0%|0B|0%"
        CP=$(echo "$ST" | cut -d'|' -f1 | tr -d '%') || CP="0"
        MU=$(echo "$ST" | cut -d'|' -f2) || MU="0B"
        MP=$(echo "$ST" | cut -d'|' -f3 | tr -d '%') || MP="0"
        [[ "$CP" =~ ^[0-9.]+$ ]] || CP="0"
        [[ "$MP" =~ ^[0-9.]+$ ]] || MP="0"
        echo -e "${BLUE}│${NC}                                               ${BLUE}│${NC}   ${BLUE}│${NC} CPU: $(bar "${CP}")          ${BLUE}│${NC}"
        echo -e "${BLUE}│${NC}                                               ${BLUE}│${NC}   ${BLUE}│${NC} RAM: $(bar "${MP}") ${MU}     ${BLUE}│${NC}"
        echo -e "${BLUE}│${NC}                                               ${BLUE}│${NC}   ${BLUE}│${NC} Status: ${GREEN}✅ Running${NC}                  ${BLUE}│${NC}"
    else
        echo -e "${BLUE}│${NC}                                               ${BLUE}│${NC}   ${BLUE}│${NC} Status: ${RED}⚠️ Offline${NC}                   ${BLUE}│${NC}"
    fi
    
    echo -e "${BLUE}╰──────────────────────────────────────╯${NC}   ${BLUE}╰──────────────────────────────────────╯${NC}"
    echo ""
    echo -e "${BLUE}╭──────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "${BLUE}│${NC} 🧠 MODELOS ATIVOS                                                        ${BLUE}│${NC}"
    
    if docker exec "$CONTAINER" ollama ps &>/dev/null; then
        ML=$(docker exec "$CONTAINER" ollama ps 2>/dev/null | tail -n +2) || ML=""
        if [[ -n "$ML" ]]; then
            while IFS= read -r ln; do
                [[ -z "$ln" ]] && continue
                MN=$(echo "$ln" | awk '{print $1}' 2>/dev/null) || continue
                ME=$(echo "$ln" | awk '{print $NF}' 2>/dev/null) || ME="?"
                echo -e "${BLUE}│${NC} 🟢 ${MN} ${YELLOW}(exp: ${ME})${NC}"
            done <<< "$ML"
        else
            echo -e "${BLUE}│${NC} ⏳ Nenhum modelo carregado"
        fi
    else
        echo -e "${BLUE}│${NC} ❌ API/Container offline"
    fi
    echo -e "${BLUE}╰──────────────────────────────────────────────────────────────────────────────╯${NC}"
    
    # Footer (API check tolerante)
    if curl -sf "$API/api/tags" &>/dev/null; then
        CT=$(curl -sf "$API/api/tags" 2>/dev/null | jq -r '.models | length' 2>/dev/null) || CT="?"
        [[ -z "$CT" || "$CT" == "null" ]] && CT="?"
        EL=$(($(date +%s 2>/dev/null || echo "$START") - START))
        echo -e "🔌 API: ${GREEN}OK${NC} │ Modelos: $CT │ Render: ${EL}s"
        log_tui "API OK, models: $CT"
    else
        echo -e "🔌 API: ${RED}OFFLINE${NC}"
        log_tui "API OFFLINE"
    fi
    
    # RAM warning inline
    [[ "$RP" -ge 85 ]] && echo -e "${RED}⚠️ RAM CRÍTICA: ${RP}% — descarregue modelos!${NC}"
    
    sleep "$REFRESH"
done
