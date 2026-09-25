#!/usr/bin/env bash
# =============================================================================
# ia_gatekeeper.sh v3.0 - Gatekeeper com exit codes semânticos
# =============================================================================
# FILOSOFIA:
#   - Responsabilidade única: autorizar ou negar carregamento de modelo
#   - NÃO interage com usuário (decisão fica no chamador)
#   - NÃO modifica estado do sistema (não descarrega nada)
#   - Falha rápido com informação estruturada via exit code
#
# EXIT CODES:
#   0 - Autorizado: RAM suficiente para carregar o modelo
#   1 - RAM insuficiente: recuperável, chamador pode perguntar ao usuário
#   2 - Erro fatal: container off, modelo não existe, etc.
#   3 - Bypass: modelo já está na RAM, autorização concedida
#
# USO:
#   ./ia_gatekeeper.sh authorize <modelo>   # Verifica se pode carregar
#   ./ia_gatekeeper.sh status                # Mostra estado atual
#   ./ia_gatekeeper.sh list                  # Lista modelos conhecidos
# =============================================================================
set -uo pipefail

# Cores
GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
BOLD='\033[1m'

# Configuração
BASE_DIR="/home/carlos/Projetos/AI"
LOG_FILE="${BASE_DIR}/gatekeeper.log"
API_URL="http://localhost:11434"
CONTAINER="ollama-service"

# Fonte unica de modelos (fallback: tabela local abaixo)
if [[ -f "${BASE_DIR}/lib_ia.sh" ]]; then
    # shellcheck source=lib_ia.sh
    source "${BASE_DIR}/lib_ia.sh" 2>/dev/null || true
fi

# Exit codes semânticos
EXIT_OK=0
EXIT_RAM_INSUF=1
EXIT_FATAL=2
EXIT_BYPASS=3

# Requisitos de RAM por modelo (mínimo em GB)
declare -A MODEL_RAM_REQUIREMENTS=(
    ["mistral-nemo-otimizado"]="10"
    ["mistral-nemo-otimizado:latest"]="10"
    ["mistral-nemo"]="8"
    ["mistral-nemo:latest"]="8"
    ["qwen2.5-coder:14b-instruct-q8_0"]="16"
    ["qwen-dev-pro"]="16"
    ["qwen-dev-pro:latest"]="16"
)

# =============================================================================
# LOGGING (stdout + arquivo)
# =============================================================================
log()     { local msg; msg="[$(date '+%Y-%m-%d %H:%M:%S')] [GATEKEEPER] $1"; echo -e "${CYAN}${msg}${NC}"; echo "$msg" >> "$LOG_FILE" 2>/dev/null || true; }
warn()    { local msg; msg="[$(date '+%Y-%m-%d %H:%M:%S')] [GATEKEEPER] ⚠️  $1"; echo -e "${YELLOW}${msg}${NC}"; echo "$msg" >> "$LOG_FILE" 2>/dev/null || true; }
err()     { local msg; msg="[$(date '+%Y-%m-%d %H:%M:%S')] [GATEKEEPER] ❌ $1"; echo -e "${RED}${msg}${NC}" >&2; echo "$msg" >> "$LOG_FILE" 2>/dev/null || true; }
success() { local msg; msg="[$(date '+%Y-%m-%d %H:%M:%S')] [GATEKEEPER] ✅ $1"; echo -e "${GREEN}${msg}${NC}"; echo "$msg" >> "$LOG_FILE" 2>/dev/null || true; }

# =============================================================================
# VERIFICAÇÃO: Modelo está na RAM?
# =============================================================================
is_model_in_ram() {
    local model_name="$1"
    local models_in_ram
    models_in_ram=$(curl -s --max-time 3 "${API_URL}/api/ps" 2>/dev/null | jq -r '.models[].name // empty' 2>/dev/null || echo "")
    [[ -z "$models_in_ram" ]] && return 1
    echo "$models_in_ram" | grep -q "^${model_name}" && return 0 || return 1
}

# =============================================================================
# VERIFICAÇÃO: Modelo está instalado?
# =============================================================================
is_model_installed() {
    local model_name="$1"
    docker exec "$CONTAINER" ollama list 2>/dev/null | awk 'NR>1{print $1}' | grep -q "^${model_name}" && return 0 || return 1
}

# =============================================================================
# OBTENÇÃO: Requisito de RAM para o modelo
# =============================================================================
get_ram_requirement() {
    local model="$1"

    # Fonte unica: registro canonico via tag -> chave curta -> MIN_RAM
    if declare -f ia_model_key_for_tag >/dev/null 2>&1; then
        local key
        key=$(ia_model_key_for_tag "$model" 2>/dev/null) || key=""
        if [[ -n "$key" ]]; then
            ia_model_min_ram "$key"
            return 0
        fi
    fi

    # Busca exata (fallback standalone)
    if [[ -v MODEL_RAM_REQUIREMENTS[$model] ]]; then
        echo "${MODEL_RAM_REQUIREMENTS[$model]}"
        return 0
    fi
    
    # Busca por prefixo (ex: "qwen-dev-pro" encontra "qwen-dev-pro:latest")
    for key in "${!MODEL_RAM_REQUIREMENTS[@]}"; do
        if [[ "$key" == *"$model"* ]] || [[ "$model" == *"$key"* ]]; then
            echo "${MODEL_RAM_REQUIREMENTS[$key]}"
            return 0
        fi
    done
    
    # Modelo desconhecido: assumir pior caso (16 GB)
    warn "Modelo '$model' não mapeado. Assumindo requisito padrão de 16GB." >&2
    echo "16"
    return 0
}

# =============================================================================
# VERIFICAÇÃO: Container Ollama está rodando?
# =============================================================================
check_container() {
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER}$"; then
        return 1
    fi
    if ! curl -s --max-time 3 "${API_URL}/api/tags" >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

# =============================================================================
# COMANDO: authorize <modelo>
# =============================================================================
cmd_authorize() {
    local model="$1"
    
    log "Solicitação de autorização: ${model}"
    
    # -------------------------------------------------------------------------
    # VERIFICAÇÃO 1: Container e API disponíveis?
    # -------------------------------------------------------------------------
    if ! check_container; then
        err "Container '${CONTAINER}' não está rodando ou API inacessível."
        err "Execute: cd ${BASE_DIR} && ./setup_ia.sh"
        echo "EXIT_FATAL=2"
        return $EXIT_FATAL
    fi
    
    # -------------------------------------------------------------------------
    # VERIFICAÇÃO 2: Modelo existe no acervo?
    # -------------------------------------------------------------------------
    if ! is_model_installed "$model"; then
        err "Modelo '${model}' não está instalado."
        err "Modelos disponíveis:"
        docker exec "$CONTAINER" ollama list 2>/dev/null | awk 'NR>1{print "  - " $1}' >&2 || true
        echo "EXIT_FATAL=2"
        return $EXIT_FATAL
    fi
    
    # -------------------------------------------------------------------------
    # VERIFICAÇÃO 3: Bypass — modelo já está na RAM?
    # -------------------------------------------------------------------------
    if is_model_in_ram "$model"; then
        success "Bypass: modelo '${model}' já está na RAM."
        echo "EXIT_BYPASS=3"
        return $EXIT_BYPASS
    fi
    
    # -------------------------------------------------------------------------
    # VERIFICAÇÃO 4: RAM suficiente?
    # -------------------------------------------------------------------------
    local ram_available ram_required
    ram_available=$(free -g | awk '/^Mem:/{print $7}')
    ram_required=$(get_ram_requirement "$model")
    
    log "RAM disponível: ${ram_available}GB | Requisito: ${ram_required}GB"
    
    if [[ "$ram_available" -lt "$ram_required" ]]; then
        local deficit=$((ram_required - ram_available))
        err "RAM insuficiente para '${model}'."
        err "  Disponível: ${ram_available}GB"
        err "  Necessário: ${ram_required}GB"
        err "  Déficit:    ${deficit}GB"
        echo "EXIT_RAM_INSUF=1"
        return $EXIT_RAM_INSUF
    fi
    
    # -------------------------------------------------------------------------
    # TUDO OK: Autorizado
    # -------------------------------------------------------------------------
    success "RAM suficiente (${ram_available}GB >= ${ram_required}GB). Autorizado."
    echo "EXIT_OK=0"
    return $EXIT_OK
}

# =============================================================================
# COMANDO: status
# =============================================================================
cmd_status() {
    echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}${BOLD}  🛡️  Gatekeeper v3.0 — Status${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Container
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER}$"; then
        echo -e "${GREEN}✓${NC} Container: ${GREEN}rodando${NC}"
    else
        echo -e "${RED}✗${NC} Container: ${RED}parado${NC}"
        return 1
    fi
    
    # API
    if curl -s --max-time 3 "${API_URL}/api/tags" >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} API:       ${GREEN}respondendo${NC}"
    else
        echo -e "${RED}✗${NC} API:       ${RED}sem resposta${NC}"
        return 1
    fi
    
    # RAM
    local ram_available ram_total
    ram_available=$(free -g | awk '/^Mem:/{print $7}')
    ram_total=$(free -g | awk '/^Mem:/{print $2}')
    echo -e "${CYAN}ℹ${NC} RAM:       ${ram_available}GB livre / ${ram_total}GB total"
    
    # Modelos na RAM
    echo ""
    echo -e "${CYAN}Modelos carregados na RAM:${NC}"
    local models_json
    models_json=$(curl -s --max-time 3 "${API_URL}/api/ps" 2>/dev/null || echo '{"models":[]}')
    local model_count
    model_count=$(echo "$models_json" | jq -r '.models | length' 2>/dev/null || echo "0")
    
    if [[ "$model_count" -gt 0 ]]; then
        echo "$models_json" | jq -r '.models[] | "  • \(.name) (\(.size / 1073741824 | floor)GB)"' 2>/dev/null || true
    else
        echo -e "  ${YELLOW}(nenhum modelo carregado)${NC}"
    fi
    
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
    return 0
}

# =============================================================================
# COMANDO: list
# =============================================================================
cmd_list() {
    echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}${BOLD}  📋 Modelos Conhecidos pelo Gatekeeper${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
    echo ""
    
    for model in "${!MODEL_RAM_REQUIREMENTS[@]}"; do
        local req="${MODEL_RAM_REQUIREMENTS[$model]}"
        local in_ram="não"
        if is_model_in_ram "$model"; then
            in_ram="${GREEN}SIM${NC}"
        else
            in_ram="${RED}não${NC}"
        fi
        printf "  %-40s ${CYAN}%2sGB${NC} mínimo | Na RAM: ${in_ram}\n" "$model" "$req"
    done
    
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
    return 0
}

# =============================================================================
# MAIN — Dispatcher de comandos
# =============================================================================
main() {
    mkdir -p "$BASE_DIR"
    touch "$LOG_FILE"
    
    if [[ $# -eq 0 ]]; then
        echo -e "${RED}Uso: $0 <comando> [argumentos]${NC}" >&2
        echo ""
        echo "Comandos disponíveis:"
        echo "  authorize <modelo>   Autoriza carregamento de modelo"
        echo "  status               Mostra status do sistema"
        echo "  list                 Lista modelos conhecidos"
        echo ""
        echo "Exit codes do 'authorize':"
        echo "  0 = Autorizado"
        echo "  1 = RAM insuficiente (recuperável)"
        echo "  2 = Erro fatal (container off, modelo não existe)"
        echo "  3 = Bypass (modelo já na RAM)"
        exit $EXIT_FATAL
    fi
    
    local command="$1"
    shift
    
    case "$command" in
        authorize)
            if [[ $# -eq 0 ]]; then
                err "Comando 'authorize' requer nome do modelo."
                exit $EXIT_FATAL
            fi
            cmd_authorize "$1"
            exit $?
            ;;
        status)
            cmd_status
            exit $?
            ;;
        list)
            cmd_list
            exit $?
            ;;
        *)
            err "Comando desconhecido: '$command'"
            exit $EXIT_FATAL
            ;;
    esac
}

# =============================================================================
# INVOCAÇÃO (o bug crítico corrigido)
# =============================================================================
main "$@"
