#!/usr/bin/env bash
# =============================================================================
# lib_ia.sh v3.1 - Biblioteca de funções compartilhadas (CORRIGIDO)
# =============================================================================

# Impedir execução direta
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Este script deve ser sourceado, não executado diretamente."
    echo "Use: source $0"
    exit 1
fi

# ============================================================================
# CONFIGURAÇÕES
# ============================================================================

export BASE_DIR="${BASE_DIR:-/home/carlos/Projetos/AI}"
export CONTAINER="${CONTAINER:-ollama-service}"
export API_URL="${API_URL:-http://localhost:11434}"
export FAILURE_LOG="${FAILURE_LOG:-${BASE_DIR}/.failures.jsonl}"

# ============================================================================
# CORES
# ============================================================================

export GREEN='\033[0;32m'
export CYAN='\033[0;36m'
export YELLOW='\033[1;33m'
export RED='\033[0;31m'
export BLUE='\033[0;34m'
export BOLD='\033[1m'
export NC='\033[0m'

# ============================================================================
# FUNÇÕES DE LOGGING
# ============================================================================

log() { echo -e "${CYAN}[INFO]${NC} $(date '+%H:%M:%S') - $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $(date '+%H:%M:%S') - $1" >&2; }
error() { echo -e "${RED}[ERRO]${NC} $(date '+%H:%M:%S') - $1" >&2; }

# ============================================================================
# VERIFICAÇÃO DE CONTAINER (SEM AÇÃO, APENAS REPORTAR)
# ============================================================================

verify_container_status() {
    # Retorna "running", "stopped", ou "not_found" SEM agir
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER}$"; then
        echo "running"
    elif docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER}$"; then
        echo "stopped"
    else
        echo "not_found"
    fi
}

# ============================================================================
# FUNÇÕES DE RAM
# ============================================================================

get_ram_available() { free -g 2>/dev/null | awk '/^Mem:/{print $7}' || echo "0"; }
get_ram_total() { free -g 2>/dev/null | awk '/^Mem:/{print $2}' || echo "0"; }
get_ram_used() { free -g 2>/dev/null | awk '/^Mem:/{print $3}' || echo "0"; }

get_ram_percent() {
    local total used
    total=$(get_ram_total)
    used=$(get_ram_used)
    [[ $total -eq 0 ]] && echo "0" || echo $((used * 100 / total))
}

# ============================================================================
# FUNÇÕES DE MODELOS
# ============================================================================

is_model_loaded() {
    local model="$1"
    [[ -z "$model" ]] && return 1
    
    # Verifica se o container está online (SEM religar)
    if [[ "$(verify_container_status)" != "running" ]]; then
        return 1
    fi
    
    docker exec "${CONTAINER}" ollama ps 2>/dev/null | tail -n +2 | grep -q "^${model}"
    return $?
}

get_loaded_models() {
    # Retorna lista de modelos carregados (um por linha)
    if [[ "$(verify_container_status)" != "running" ]]; then
        echo ""
        return 0
    fi
    docker exec "${CONTAINER}" ollama ps 2>/dev/null | tail -n +2 | awk '{print $1}' || echo ""
}

get_model_expiry() {
    local model="$1"
    if [[ "$(verify_container_status)" != "running" ]]; then
        echo "unknown"
        return 0
    fi
    docker exec "${CONTAINER}" ollama ps 2>/dev/null | grep "^${model}" | awk '{print $NF}' || echo "unknown"
}

# ============================================================================
# DESCARREGAR MODELOS (VERSÃO MELHORADA)
# ============================================================================

unload_model() {
    local model="$1"
    local max_attempts="${2:-20}"
    local attempt=0
    
    # Verifica se o container está online
    if [[ "$(verify_container_status)" != "running" ]]; then
        log "Container ${CONTAINER} não está rodando. Nada a descarregar."
        return 0
    fi
    
    # Verifica se o modelo está carregado
    if ! is_model_loaded "$model"; then
        log "Modelo ${model} já está descarregado"
        return 0
    fi
    
    log "Descarregando ${model}..."
    
    # ========================================================================
    # ESTRATÉGIA 1: API com keep_alive=0 (método principal)
    # ========================================================================
    log "  Estratégia 1: API keep_alive=0"
    docker exec "${CONTAINER}" curl -s -X POST "${API_URL}/api/generate" \
        -d "{\"model\": \"${model}\", \"keep_alive\": 0, \"stream\": false}" >/dev/null 2>&1
    sleep 3
    
    # Verifica se já descarregou
    if ! is_model_loaded "$model"; then
        log "✅ Modelo ${model} descarregado (Estratégia 1)"
        return 0
    fi
    
    # ========================================================================
    # ESTRATÉGIA 2: Forçar descarga via chat vazio
    # ========================================================================
    log "  Estratégia 2: Chat vazio com keep_alive=0"
    docker exec "${CONTAINER}" curl -s -X POST "${API_URL}/api/chat" \
        -d "{\"model\": \"${model}\", \"messages\": [], \"keep_alive\": 0, \"stream\": false}" >/dev/null 2>&1
    sleep 3
    
    if ! is_model_loaded "$model"; then
        log "✅ Modelo ${model} descarregado (Estratégia 2)"
        return 0
    fi
    
    # ========================================================================
    # ESTRATÉGIA 3: Matar processo do modelo diretamente
    # ========================================================================
    log "  Estratégia 3: Matar processo do modelo"
    local model_pid
    model_pid=$(docker exec "${CONTAINER}" ps aux 2>/dev/null | \
        grep "ollama run ${model}" | grep -v grep | awk '{print $2}' | head -1)
    
    if [[ -n "$model_pid" ]]; then
        log "    Matando PID: ${model_pid}"
        docker exec "${CONTAINER}" kill -9 "$model_pid" 2>/dev/null || true
        sleep 3
    else
        # Tentar matar todos os processos relacionados ao modelo
        log "    Nenhum PID específico encontrado. Matando processos 'ollama run'..."
        docker exec "${CONTAINER}" pkill -f "ollama run" 2>/dev/null || true
        sleep 3
    fi
    
    if ! is_model_loaded "$model"; then
        log "✅ Modelo ${model} descarregado (Estratégia 3)"
        return 0
    fi
    
    # ========================================================================
    # ESTRATÉGIA 4: Reiniciar serviço Ollama dentro do container
    # ========================================================================
    log "  Estratégia 4: Reiniciar serviço Ollama"
    docker exec "${CONTAINER}" pkill -f "ollama serve" 2>/dev/null || true
    sleep 5
    docker exec -d "${CONTAINER}" ollama serve 2>/dev/null || true
    sleep 5
    
    if ! is_model_loaded "$model"; then
        log "✅ Modelo ${model} descarregado (Estratégia 4)"
        return 0
    fi
    
    # ========================================================================
    # ESTRATÉGIA 5: Reiniciar o container inteiro (último recurso)
    # ========================================================================
    log "  Estratégia 5: Reiniciar container (último recurso)"
    docker restart "${CONTAINER}" >/dev/null 2>&1
    sleep 10
    
    # Aguardar API voltar
    local api_attempts=0
    while ! curl -sf --max-time 2 "${API_URL}/api/tags" >/dev/null 2>&1; do
        ((api_attempts++))
        if [[ $api_attempts -gt 20 ]]; then
            error "API não voltou após reiniciar o container"
            return 1
        fi
        sleep 2
    done
    
    if ! is_model_loaded "$model"; then
        log "✅ Modelo ${model} descarregado (Estratégia 5)"
        return 0
    fi
    
    # ========================================================================
    # VERIFICAÇÃO FINAL COM RETRY
    # ========================================================================
    while is_model_loaded "$model"; do
        ((attempt++))
        if [[ $attempt -gt $max_attempts ]]; then
            error "❌ Falha ao descarregar ${model} após ${max_attempts} tentativas"
            error "   Soluções possíveis:"
            error "   1. docker stop ${CONTAINER} && docker start ${CONTAINER}"
            error "   2. docker restart ${CONTAINER}"
            error "   3. docker exec ${CONTAINER} ollama ps (para ver o estado)"
            return 1
        fi
        
        log "  Tentativa ${attempt}/${max_attempts}..."
        docker exec "${CONTAINER}" curl -s -X POST "${API_URL}/api/generate" \
            -d "{\"model\": \"${model}\", \"keep_alive\": 0}" >/dev/null 2>&1
        sleep 2
    done
    
    log "✅ Modelo ${model} descarregado com sucesso"
    return 0
}

# ============================================================================
# DESCARREGAR TODOS OS MODELOS
# ============================================================================

unload_all_models() {
    local loaded
    loaded=$(get_loaded_models)
    
    if [[ -z "$loaded" ]]; then
        log "Nenhum modelo carregado para descarregar"
        return 0
    fi
    
    log "Descarregando todos os modelos..."
    local failed=0
    
    echo "$loaded" | while read -r model; do
        if ! unload_model "$model"; then
            ((failed++))
            warn "⚠️ Falha ao descarregar ${model}"
        fi
    done
    
    # Forçar liberação de cache do sistema
    sync 2>/dev/null || true
    echo 3 2>/dev/null | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true
    
    if [[ $failed -eq 0 ]]; then
        log "✅ Todos os modelos descarregados com sucesso"
    else
        warn "⚠️ ${failed} modelo(s) falharam ao descarregar"
    fi
    
    return $failed
}

# ============================================================================
# LOG DE FALHAS (ESTRUTURADO)
# ============================================================================

log_failure() {
    local model="$1"
    local action="$2"
    local error_type="$3"
    local ram_avail="$4"
    local ram_req="$5"
    local duration="$6"
    local exit_code="$7"
    local details="$8"
    
    mkdir -p "$(dirname "$FAILURE_LOG")"
    echo "[$(date -Iseconds)] FALHA | $model | $action | $error_type | RAM: ${ram_avail}GB/${ram_req}GB | Dur: ${duration}s | Code: $exit_code | $details" \
        >> "${FAILURE_LOG}" 2>/dev/null || true
}

log_success() {
    local model="$1"
    local action="$2"
    local duration="$3"
    local ram_used="$4"
    
    echo "[$(date -Iseconds)] SUCESSO | $model | $action | RAM: ${ram_used}GB | Dur: ${duration}s" \
        >> "${FAILURE_LOG}" 2>/dev/null || true
}

# ============================================================================
# FUNÇÕES DE UTILIDADE
# ============================================================================

# Verifica se um modelo está instalado no sistema
is_model_installed() {
    local model="$1"
    
    if [[ "$(verify_container_status)" != "running" ]]; then
        return 1
    fi
    
    docker exec "${CONTAINER}" ollama list 2>/dev/null | grep -q "^${model}"
    return $?
}

# Retorna o tamanho de um modelo instalado (em GB)
get_model_size() {
    local model="$1"
    local size
    size=$(docker exec "${CONTAINER}" ollama list 2>/dev/null | grep "^${model}" | awk '{print $3}' | sed 's/GB//g' | sed 's/G//g')
    echo "${size:-0}"
}

# Retorna o status do container (running, stopped, ou not_found)
get_container_status() {
    verify_container_status
}
