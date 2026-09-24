#!/usr/bin/env bash
# status_ia.sh v2.3 - Mostra todos os 4 modelos
set -euo pipefail
CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
BOLD='\033[1m'

echo -e "${CYAN}${BOLD}📊 Status IA${NC} │ $(date '+%H:%M') │ Ryzen 5600X │ 31GB RAM"
echo -e "${BLUE}┌────────────────────────────────────────┐${NC}"

echo -e "${BLUE}│${NC} ${BOLD}🧠 Modelos em RAM${NC}"
echo -e "${BLUE}├────────────────────────────────────────┤${NC}"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^ollama-service$"; then
ACTIVE=$(docker exec ollama-service ollama ps 2>/dev/null | tail -n +2 || true)
if [[ -n "$ACTIVE" ]]; then
echo "$ACTIVE" | while IFS= read -r line; do
[[ -z "$line" ]] && continue
M_NAME=$(echo "$line" | awk '{print $1}')
M_EXP=$(echo "$line" | awk '{print $NF}')
echo -e "${BLUE}│${NC} 🟢 ${M_NAME} ${YELLOW}(exp: ${M_EXP})${NC}"
done
else
echo -e "${BLUE}│${NC} 💤 Standby${NC}"
fi
else
echo -e "${BLUE}│${NC} ${RED}⚠️ Containers parados${NC}"
fi

echo -e "${BLUE}├────────────────────────────────────────┤${NC}"
echo -e "${BLUE}│${NC} ${BOLD}📊 RAM${NC}"
echo -e "${BLUE}├────────────────┬─────────┤${NC}"
read -r MEM_AVAIL MEM_USED MEM_TOTAL < <(free -g | awk '/^Mem:/{print $7, $3, $2}')
printf "${BLUE}│${NC} %-14s ${BLUE}│${NC} %-7s ${BLUE}│${NC}\n" "Disponível" "${MEM_AVAIL}GB"
printf "${BLUE}│${NC} %-14s ${BLUE}│${NC} %-7s ${BLUE}│${NC}\n" "Usada" "${MEM_USED}GB"
printf "${BLUE}│${NC} %-14s ${BLUE}│${NC} %-7s ${BLUE}│${NC}\n" "Total" "${MEM_TOTAL}GB"
echo -e "${BLUE}└────────────────┴─────────┘${NC}"

echo -e "\n${CYAN}📦 Seus 4 Modelos Instalados:${NC}"
echo "  ⭐ mistral-nemo-otimizado:latest (7.1GB) ← CRIADO A PARTIR DO BASE"
echo "  📦 mistral-nemo:latest (7.1GB) ← MODELO BASE"
echo "  🔧 qwen2.5-coder:14b-instruct-q8_0 (15GB) ← MODELO COMPLEMENTAR"
echo "  📦 qwen-dev-pro:latest (15GB) ← MODELO BASE"

echo -e "\n${CYAN}Conclusões:${NC}"
if [[ "${MEM_AVAIL:-0}" -ge 15 ]]; then
echo -e "  ${GREEN}✅ Perfeito:${NC} RAM livre ideal para todos os modelos"
elif [[ "${MEM_AVAIL:-0}" -ge 10 ]]; then
echo -e "  ${YELLOW}⚠️ Limítrofe:${NC} OK para Mistral. Feche apps para Qwen."
else
echo -e "  ${RED}❌ RAM crítica:${NC} Libere memória antes de interagir."
fi

echo -e "\n${CYAN}Acesso:${NC} WebUI: http://localhost:8080 │ CLI: ./chat_IA.sh"
