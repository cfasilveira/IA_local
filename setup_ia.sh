#!/usr/bin/env bash
# =============================================================================
# setup_ia.sh v6.1 - Warmup Robusto + Setup Idempotente + Métricas Modulares
# =============================================================================
# CORREÇÕES v6.1:
#   - Fix: referência órfã $METRICS → $METRICS_JSONL (linha 524 do v6.0)
#   - Add: validação de existência do metrics_core.sh
#   - Add: fallback se o módulo de métricas não estiver disponível
# =============================================================================
set -uo pipefail

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
BOLD='\033[1m'

BASE_DIR="/home/carlos/Projetos/AI"
LOG="${BASE_DIR}/setup_$(date +%Y%m%d_%H%M%S).log"
METRICS_JSONL="${BASE_DIR}/metrics.jsonl"

# Logs com GPS (função + linha)
log()      { local msg; msg="[INFO] $(date '+%H:%M:%S') [${FUNCNAME[1]:-main}:${BASH_LINENO[0]}] - $1"; echo -e "${CYAN}${msg}${NC}"; echo "$msg" >> "$LOG"; }
warn()     { local msg; msg="[WARN] $(date '+%H:%M:%S') [${FUNCNAME[1]:-main}:${BASH_LINENO[0]}] - $1"; echo -e "${YELLOW}${msg}${NC}"; echo "$msg" >> "$LOG"; }
critical() { local msg; msg="[CRÍTICO] $(date '+%H:%M:%S') [${FUNCNAME[1]:-main}:${BASH_LINENO[0]}] - $1"; echo -e "${RED}${BOLD}${msg}${NC}" >&2; echo "$msg" >> "$LOG"; }

err() {
    local msg; msg="[ERRO] $(date '+%H:%M:%S') [${FUNCNAME[1]:-main}:${BASH_LINENO[0]}] - $1"
    echo -e "${RED}${msg}${NC}" >&2; echo "$msg" >> "$LOG"
    exit 1
}

# ============================================================================
# FAIL GRACEFULLY (SRE Mode) — cirúrgico: só remove o que ESTE run criou.
# Falhas de pré-criação (porta, RAM, args, Docker off) não tocam em nada;
# stack pré-existente saudável é preservada.
# ============================================================================
CREATED_CONTAINERS=()  # nomes criados por esta execução (create_containers)
cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 && ${#CREATED_CONTAINERS[@]} -gt 0 ]]; then
        warn "🧹 Falha após criação (${exit_code}). Removendo só o que este run criou: ${CREATED_CONTAINERS[*]}..."
        docker rm -f "${CREATED_CONTAINERS[@]}" >/dev/null 2>&1 || true
    elif [[ $exit_code -ne 0 ]]; then
        warn "🧹 Falha antes de criar containers (${exit_code}). Nada a limpar — stack existente preservada."
    fi
}
trap cleanup EXIT INT TERM

# Carregar módulo de métricas (persistência centralizada) — fonte única
METRICS_CORE="${BASE_DIR}/metrics_core.sh"
if [[ -f "$METRICS_CORE" ]]; then
    # shellcheck source=metrics_core.sh
    source "$METRICS_CORE"
    METRICS_ENABLED=1
else
    METRICS_ENABLED=0
fi

# Log Rotation (mantém 5 últimos)
ls -t ${BASE_DIR}/setup_*.log 2>/dev/null | tail -n +6 | xargs -r rm -- >/dev/null 2>&1

# ============================================================================
# PARSER DE ARGUMENTOS
# ============================================================================
SKIP_TUNING=0; MODEL_CHOICE=""; NO_WARMUP=0; FORCE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-tuning) SKIP_TUNING=1; shift ;;
        --model)
            if [[ $# -lt 2 || "$2" == --* ]]; then
                echo -e "${RED}❌ --model requer um argumento.${NC}" >&2; exit 1
            fi
            MODEL_CHOICE="$2"; shift 2 ;;
        --no-warmup) NO_WARMUP=1; shift ;;
        --force) FORCE=1; shift ;;
        *) echo -e "${RED}❌ Flag desconhecida: $1${NC}" >&2; exit 1 ;;
    esac
done

log "🚀 Iniciando setup_ia.sh v6.1 em ${BASE_DIR}..."

if [[ $METRICS_ENABLED -eq 0 ]]; then
    warn "⚠️ Módulo de métricas não encontrado em $METRICS_CORE"
    warn "   Warmup funcionará, mas métricas não serão persistidas"
fi

# ============================================================================
# TIMEOUTS ADAPTATIVOS POR TAMANHO DE MODELO
# ============================================================================
get_warmup_timeout() {
    local size_gb="$1"
    # awk (sempre presente) em vez de bc (opcional)
    if [[ "$(awk -v s="$size_gb" 'BEGIN { print (s <= 8) }')" == "1" ]]; then
        echo 120
    elif [[ "$(awk -v s="$size_gb" 'BEGIN { print (s <= 12) }')" == "1" ]]; then
        echo 180
    else
        echo 300
    fi
}

# ============================================================================
# VALIDAÇÃO DE SISTEMA (IDEMPOTENTE)
# ============================================================================
validate_system() {
    log "Validando sistema e isolamento de rede..."
    [[ -d "$BASE_DIR" ]] || err "Diretório ${BASE_DIR} não existe."
    docker info >/dev/null 2>&1 || err "Docker inacessível. O daemon está rodando?"

    local ram_total
    ram_total=$(free -g | awk '/^Mem:/{print $2}')
    [[ "$ram_total" -ge 28 ]] || err "RAM total insuficiente: ${ram_total}GB (Mínimo 28GB)"

    # IDEMPOTÊNCIA: containers nossos pelo NOME primeiro.
    # (Com portas publicadas, quem escuta no host é o docker-proxy — o PID
    #  do `ss` nunca aparece no `docker top`, então a heurística de PID
    #  abaixo classifica nossa própria stack como "externa".)
    # Se o dono esperado está rodando, a porta é nossa: só avisar, pois
    # create_containers() recria de forma idempotente. Não remover aqui —
    # se a validação falhar adiante (RAM etc.), a stack segue intacta.
    local own_running=""
    own_running=$(docker ps --format '{{.Names}}' 2>/dev/null || true)

    for port in 11434 8080; do
        if ! ss -tlnp 2>/dev/null | grep -qE ":${port}\b"; then
            continue
        fi
        local expected=""
        [[ "$port" == "11434" ]] && expected="ollama-service"
        [[ "$port" == "8080" ]] && expected="open-webui-gui"
        if [[ -n "$expected" ]] && echo "$own_running" | grep -q "^${expected}$"; then
            warn "Porta ${port} ocupada pelo nosso '${expected}' (rodando). Será recriada em create_containers..."
            continue
        fi
        {
            local pid_using
            pid_using=$(sudo ss -tlnp 2>/dev/null | grep -E ":${port}\b" | grep -oP 'pid=\K[0-9]+' | head -1)

            local container_using=""
            if [[ -n "$pid_using" ]]; then
                container_using=$(docker ps --format '{{.ID}} {{.Names}}' 2>/dev/null | while read -r cid cname; do
                    if docker top "$cid" 2>/dev/null | grep -q "$pid_using"; then
                        echo "$cname"; break
                    fi
                done)
            fi

            if [[ "$container_using" == "ollama-service" || "$container_using" == "open-webui-gui" ]]; then
                warn "Porta ${port} ocupada pelo container '${container_using}'. Removendo para recriar..."
                docker rm -f "$container_using" >/dev/null 2>&1 || true
                sleep 2
            else
                err "Porta ${port} já está em uso por processo externo (PID=${pid_using:-?}). Libere-a antes de continuar."
            fi
        }
    done

    mkdir -p "${BASE_DIR}/ollama-models" "${BASE_DIR}/AI-data/open-webui"
}

# ============================================================================
# MODELOS
# ============================================================================
declare -A MODEL_SPECS=(
    ["mistral-otimizado"]="Mistral Nemo Otimizado|mistral-nemo-otimizado:latest|7.1|10|12|⭐ CRIADO A PARTIR DO BASE|mistral-nemo:latest"
    ["mistral-base"]="Mistral Nemo Base|mistral-nemo:latest|7.1|8|10|📦 MODELO BASE|-"
    ["qwen-coder"]="Qwen Coder 14B|qwen2.5-coder:14b-instruct-q8_0|15|16|20|🔧 MODELO COMPLEMENTAR|qwen-dev-pro:latest"
    ["qwen-base"]="Qwen Dev Pro Base|qwen-dev-pro:latest|15|16|20|📦 MODELO BASE|-"
    ["none"]="Nenhum|none|0|0|0|-|-"
)

# Fonte unica: se lib_ia.sh estiver presente, os numeros (tag/size/min/rec)
# vêm do registro canonico; nomes/descrições permanecem locais (fallback
# embutido acima garante standalone).
if [[ -f "${BASE_DIR}/lib_ia.sh" ]]; then
    # shellcheck source=lib_ia.sh
    source "${BASE_DIR}/lib_ia.sh"
    if declare -f ia_model_tag >/dev/null 2>&1; then
        for _k in mistral-otimizado mistral-base qwen-coder qwen-base; do
            IFS='|' read -r _name _tag _w _min _rec _desc _base <<< "${MODEL_SPECS[$_k]}"
            _tag="$(ia_model_tag "$_k")"
            _w="$(ia_model_size "$_k")"
            _min="$(ia_model_min_ram "$_k")"
            _rec="$(ia_model_rec_ram "$_k")"
            MODEL_SPECS[$_k]="${_name}|${_tag}|${_w}|${_min}|${_rec}|${_desc}|${_base}"
        done
        unset _k _name _tag _w _min _rec _desc _base
    fi
fi

resolve_model_key() {
    local input="$1"
    case "$input" in
        "mistral-otimizado"|"mistral-nemo-otimizado"|"mistral-nemo-otimizado:latest"|"1") echo "mistral-otimizado" ;;
        "mistral-base"|"mistral-nemo"|"mistral-nemo:latest"|"2") echo "mistral-base" ;;
        "qwen-coder"|"qwen2.5-coder:14b-instruct-q8_0"|"3") echo "qwen-coder" ;;
        "qwen-base"|"qwen-dev-pro"|"qwen-dev-pro:latest"|"4") echo "qwen-base" ;;
        "none"|"5"|"") echo "none" ;;
        *) echo ""; return 1 ;;
    esac
}

get_ram_requirements() {
    local model_key="$1"; local field="$2"
    local data=""
    if [[ -v MODEL_SPECS[$model_key] ]]; then
        data="${MODEL_SPECS[$model_key]}"
    else
        data="none|0|0|0|0|-|-"
    fi

    IFS='|' read -r name model weight min rec desc base <<< "$data"
    case "$field" in
        name) echo "$name";; model) echo "$model";; weight) echo "$weight";;
        min) echo "$min";; recommended) echo "$rec";; desc) echo "$desc";; base) echo "$base";;
    esac
}

# ============================================================================
# DIAGNÓSTICO DE RECURSOS
# ============================================================================
diagnose_resource_hogs() {
    warn "⚠️ Em CPU-Native, processos em background roubam Largura de Banda e Cache L3."
    echo -e "${YELLOW}🔍 Top 3 processos consumindo recursos:${NC}"
    ps -eo pid,comm,%mem,%cpu --sort=-%mem | head -n 4 | awk 'NR>1 {printf "  ➔ PID %-6s | %-15s | RAM: %5s%% | CPU: %5s%%\n", $1, $2, $3, $4}'
    echo ""
    warn "💡 Feche navegadores, IDEs ou compiladores. Para matar: kill -9 <PID>"
}

# ============================================================================
# VERIFICAÇÃO DE RAM
# ============================================================================
check_ram_with_margin() {
    local model_key="$1"
    local available
    available=$(free -g | awk '/^Mem:/{print $7}')
    local min_ram rec_ram model_name
    min_ram=$(get_ram_requirements "$model_key" "min")
    rec_ram=$(get_ram_requirements "$model_key" "recommended")
    model_name=$(get_ram_requirements "$model_key" "name")

    echo -e "\n${CYAN}📊 RAM Analysis: ${model_name}${NC}"
    echo -e "${BLUE}┌────────────────┬─────────┐${NC}"
    printf "${BLUE}│${NC} %-14s ${BLUE}│${NC} %-7s ${BLUE}│${NC}\n" "Disponível" "${available}GB"
    printf "${BLUE}│${NC} %-14s ${BLUE}│${NC} %-7s ${BLUE}│${NC}\n" "Mínimo" "${min_ram}GB"
    printf "${BLUE}│${NC} %-14s ${BLUE}│${NC} %-7s ${BLUE}│${NC}\n" "Recomendado" "${rec_ram}GB"
    echo -e "${BLUE}└────────────────┴─────────┘${NC}"

    if [[ "$available" -lt "$min_ram" ]]; then
        critical "❌ BLOQUEADO: RAM insuficiente"
        diagnose_resource_hogs
        [[ "$FORCE" -eq 0 ]] && err "Libere RAM ou use --force" || warn "⚠️ --force: risco aceito"
        return 1
    elif [[ "$available" -lt "$rec_ram" ]]; then
        warn "⚠️ OK com ressalvas: RAM abaixo do recomendado"
        diagnose_resource_hogs
        [[ "$FORCE" -eq 0 ]] && { read -p "👉 Continuar? [y/N]: " c; [[ "${c,,}" != "y" ]] && exit 0; }
    else
        log "✅ RAM adequada para ${model_name}"
    fi
    return 0
}

# ============================================================================
# TUNING DE HARDWARE
# ============================================================================
apply_system_tuning() {
    [[ "$SKIP_TUNING" -eq 1 ]] && { log "Tuning pulado (--skip-tuning)"; return 0; }
    log "Aplicando tuning de hardware para inferência LLM..."

    if ! sudo -n true 2>/dev/null; then
        warn "⚠️ sudo requer senha. Tuning de kernel PULADO."
        warn "   Impacto: CPU pode ficar em modo powersave (~50% menos tokens/s)"
        return 0
    fi

    if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
        echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null 2>&1 && log "✅ CPU governor: performance"
    fi
    sudo sysctl -w vm.swappiness=10 >/dev/null 2>&1 && log "✅ vm.swappiness=10"
    if [[ -f /sys/kernel/mm/transparent_hugepage/enabled ]]; then
        echo madvise | sudo tee /sys/kernel/mm/transparent_hugepage/enabled >/dev/null 2>&1 && log "✅ THP: madvise"
    fi
}

# ============================================================================
# IMAGENS DOCKER
# ============================================================================
ensure_images() {
    log "Verificando imagens Docker..."
    for img in "ollama/ollama:latest" "ghcr.io/open-webui/open-webui:main"; do
        if ! docker image inspect "$img" >/dev/null 2>&1; then
            log "Baixando imagem $img (pode demorar)..."
            if ! timeout 300 docker pull "$img"; then
                err "Falha ao baixar $img. Verifique sua conexão."
            fi
        fi
    done
}

# ============================================================================
# CONTAINERS
# ============================================================================
create_containers() {
    log "Criando containers..."
    for c in ollama-service open-webui-gui; do
        docker ps -a --format '{{.Names}}' | grep -q "^${c}$" && docker rm -f "$c" >/dev/null 2>&1 || true
    done

    docker run -d --name ollama-service --restart always \
        -v "${BASE_DIR}/ollama-models:/root/.ollama" -p 11434:11434 \
        --memory="26g" --memory-swap="26g" --memory-reservation="16g" \
        --cpus="6.0" --oom-score-adj=-500 --pids-limit=256 \
        -e OLLAMA_NUM_THREADS=6 \
        -e OLLAMA_NUM_PARALLEL=1 \
        -e OLLAMA_MAX_LOADED_MODELS=1 \
        -e OLLAMA_NUM_CTX=4096 \
        -e OLLAMA_KEEP_ALIVE=-1 \
        -e OLLAMA_DEBUG=1 \
        -e CUDA_VISIBLE_DEVICES="" \
        -e ROCR_VISIBLE_DEVICES="" \
        ollama/ollama:latest

    CREATED_CONTAINERS+=("ollama-service")

    for i in $(seq 1 20); do
        local status; status=$(docker inspect -f '{{.State.Status}}' ollama-service 2>/dev/null)
        [[ "$status" == "running" ]] && break
        if [[ "$i" -eq 20 ]]; then
            err "ollama-service não iniciou. Logs: $(docker logs ollama-service 2>&1 | tail -n 5)"
        fi
        sleep 1
    done

    docker run -d --name open-webui-gui --restart always \
        -p 8080:8080 --add-host=host.docker.internal:host-gateway \
        -v "${BASE_DIR}/AI-data/open-webui:/app/backend/data" \
        --memory="3g" --cpus="3" ghcr.io/open-webui/open-webui:main

    CREATED_CONTAINERS+=("open-webui-gui")

    log "Aguardando API Ollama..."
    for i in $(seq 1 30); do
        curl -sf http://localhost:11434/api/tags >/dev/null 2>&1 && { log "✅ API online"; break; }
        [[ "$i" -eq 30 ]] && err "API Ollama não respondeu em 30s"
        sleep 1
    done
}

# ============================================================================
# SELEÇÃO DE MODELO
# ============================================================================
select_model_inline() {
    local opts=("mistral-otimizado" "mistral-base" "qwen-coder" "qwen-base" "none")
    echo -e "\n${CYAN}${BOLD}🧠 Seus 4 Modelos Disponíveis:${NC}"
    echo -e "${YELLOW}   RAM disponível: $(free -g | awk '/^Mem:/{print $7}')GB / $(free -g | awk '/^Mem:/{print $2}')GB\n${NC}"
    echo "  1. Mistral Nemo Otimizado (7.1GB)  2. Mistral Nemo Base (7.1GB)"
    echo "  3. Qwen Coder 14B (15GB)           4. Qwen Dev Pro Base (15GB)"
    echo "  5. Nenhum (só infraestrutura)"
    echo ""
    local choice=""
    while true; do
        read -p "👉 Escolha [1-5] (padrão: 1): " choice; choice=${choice:-1}
        if [[ "$choice" =~ ^[1-5]$ ]]; then
            SELECTED_MODEL_KEY="${opts[$((choice-1))]}"
            echo -e "\n${GREEN}✅ Selecionado: $(get_ram_requirements "$SELECTED_MODEL_KEY" "name")${NC}"
            return 0
        fi
        echo -e "${RED}❌ Inválido.${NC}"
    done
}

# ============================================================================
# DOWNLOAD SEGURO DE MODELOS
# ============================================================================
pull_model_safe() {
    local tag="$1"; local timeout_sec="$2"; local label="$3"
    log "  Baixando ${tag}..."
    local exit_code=0
    timeout "$timeout_sec" docker exec ollama-service ollama pull "$tag" || exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        log "  ✅ ${tag} baixado"
        return 0
    elif [[ $exit_code -eq 124 ]]; then
        err "Timeout no download: ${label}. (Dica: rm -rf ${BASE_DIR}/ollama-models/blobs/sha256-* se corromper)"
    else
        err "Falha no download: ${label}. Espaço: $(df -h "${BASE_DIR}" | awk 'NR==2{print $4}')"
    fi
}

prepare_models() {
    local model_key="$1"
    local model_name model_tag base_tag
    model_name=$(get_ram_requirements "$model_key" "name")
    model_tag=$(get_ram_requirements "$model_key" "model")
    base_tag=$(get_ram_requirements "$model_key" "base")

    log "Preparando: $model_name"
    case "$model_key" in
        "mistral-otimizado")
            if ! docker exec ollama-service ollama list 2>/dev/null | grep -q "mistral-nemo:latest"; then
                pull_model_safe "mistral-nemo:latest" 600 "mistral-nemo base"
            fi
            if ! docker exec ollama-service ollama list 2>/dev/null | grep -q "mistral-nemo-otimizado"; then
                log "  Criando mistral-nemo-otimizado..."
                docker exec ollama-service bash -c 'cat > /tmp/mf << "MFEOF"
FROM mistral-nemo:latest
PARAMETER num_ctx 4096
PARAMETER num_batch 256
PARAMETER temperature 0.2
PARAMETER top_p 0.9
PARAMETER top_k 40
PARAMETER repeat_penalty 1.15
SYSTEM "Assistente técnico: Docker, Go, Linux. Respostas concisas e práticas."
MFEOF'
                docker exec ollama-service ollama create mistral-nemo-otimizado -f /tmp/mf || err "Falha ao criar modelo"
            fi ;;
        "mistral-base")
            if ! docker exec ollama-service ollama list 2>/dev/null | grep -q "mistral-nemo:latest"; then
                pull_model_safe "mistral-nemo:latest" 600 "mistral-nemo"
            fi ;;
        "qwen-coder")
            if ! docker exec ollama-service ollama list 2>/dev/null | grep -q "qwen2.5-coder:14b-instruct-q8_0"; then
                pull_model_safe "qwen2.5-coder:14b-instruct-q8_0" 900 "qwen-coder 14B"
            fi ;;
        "qwen-base")
            if ! docker exec ollama-service ollama list 2>/dev/null | grep -q "qwen-dev-pro:latest"; then
                pull_model_safe "qwen-dev-pro:latest" 900 "qwen-dev-pro"
            fi ;;
        "none") log "Nenhum modelo selecionado"; return 0 ;;
    esac
    log "✅ $model_name preparado"
}

# ============================================================================
# WARMUP ROBUSTO VIA API REST
# ============================================================================
warmup_model() {
    local model_key="$1"
    [[ "$NO_WARMUP" -eq 1 || "$model_key" == "none" ]] && return 0

    local model_tag model_name model_size
    model_tag=$(get_ram_requirements "$model_key" "model")
    model_name=$(get_ram_requirements "$model_key" "name")
    model_size=$(get_ram_requirements "$model_key" "weight")

    local timeout_sec
    timeout_sec=$(get_warmup_timeout "$model_size")

    log "🔥 Warmup ${model_name} (${model_size}GB, timeout ${timeout_sec}s)..."

    local ram_before
    ram_before=$(free -g | awk '/^Mem:/{print $7}')

    local start_ns
    start_ns=$(date +%s%N)

    local response
    response=$(timeout "$timeout_sec" curl -s --max-time "$timeout_sec" \
        http://localhost:11434/api/generate \
        -H "Content-Type: application/json" \
        -d "{\"model\": \"$model_tag\", \"prompt\": \"Sistema pronto. Aguardando instruções.\", \"stream\": false, \"options\": {\"num_predict\": 30}}")

    local curl_exit=$?
    local end_ns
    end_ns=$(date +%s%N)
    local duration_ms=$(( (end_ns - start_ns) / 1000000 ))

    if [[ $curl_exit -eq 124 ]]; then
        warn "⏱️  Warmup excedeu ${timeout_sec}s (timeout)."
        warn "    O modelo pode estar carregando em background."
        warn "    Monitore com: ./status_ia.sh"
        _log_warmup_metric "$model_name" "$model_size" "timeout" "$duration_ms" "$ram_before"
        return 1
    fi

    if [[ $curl_exit -ne 0 ]]; then
        warn "❌ Warmup falhou na comunicação com API (curl exit=$curl_exit)."
        _log_warmup_metric "$model_name" "$model_size" "api_error" "$duration_ms" "$ram_before"
        return 1
    fi

    if [[ -z "$response" ]]; then
        warn "❌ Warmup retornou resposta vazia."
        _log_warmup_metric "$model_name" "$model_size" "empty_response" "$duration_ms" "$ram_before"
        return 1
    fi

    local api_error
    api_error=$(echo "$response" | jq -r '.error // empty' 2>/dev/null)
    if [[ -n "$api_error" ]]; then
        warn "❌ API reportou erro: $api_error"
        _log_warmup_metric "$model_name" "$model_size" "api_reported_error" "$duration_ms" "$ram_before"
        return 1
    fi

    local response_text
    response_text=$(echo "$response" | jq -r '.response // empty' 2>/dev/null)

    if [[ -z "$response_text" ]]; then
        warn "❌ Resposta sem campo 'response'."
        _log_warmup_metric "$model_name" "$model_size" "missing_response_field" "$duration_ms" "$ram_before"
        return 1
    fi

    local eval_count eval_duration load_duration prompt_eval_count
    eval_count=$(echo "$response" | jq -r '.eval_count // 0' 2>/dev/null)
    eval_duration=$(echo "$response" | jq -r '.eval_duration // 0' 2>/dev/null)
    load_duration=$(echo "$response" | jq -r '.load_duration // 0' 2>/dev/null)
    prompt_eval_count=$(echo "$response" | jq -r '.prompt_eval_count // 0' 2>/dev/null)

    local ram_after ram_used
    ram_after=$(free -g | awk '/^Mem:/{print $7}')
    ram_used=$((ram_before - ram_after))

    local tokens_per_sec="n/d"
    if [[ "$eval_duration" -gt 0 && "$eval_count" -gt 0 ]]; then
        tokens_per_sec=$(awk -v count="$eval_count" -v dur="$eval_duration" 'BEGIN { printf "%.2f", count / (dur / 1000000000) }')
    fi

    local load_sec
    load_sec=$(awk -v ns="$load_duration" 'BEGIN { printf "%.1f", ns / 1000000000 }')

    log "✅ Warmup OK em ${duration_ms}ms"
    log "   📊 Modelo carregado em: ${load_sec}s"
    log "   📊 Tokens gerados: ${eval_count} em ${eval_duration}ns"
    log "   📊 Velocidade: ${tokens_per_sec} tokens/s"
    log "   📊 RAM usada: ${ram_used}GB"

    _log_warmup_metric "$model_name" "$model_size" "success" "$duration_ms" "$ram_before" "$tokens_per_sec" "$ram_used" "$load_sec"
    return 0
}

# ============================================================================
# PERSISTÊNCIA DE MÉTRICAS (Wrapper: delega para o módulo centralizado)
# ============================================================================
_log_warmup_metric() {
    local model="$1" size="$2" status="$3" duration_ms="$4" ram_before="$5"
    local tps="${6:-0}" ram_used="${7:-0}" load_sec="${8:-0}"

    if [[ "${METRICS_ENABLED:-0}" -eq 1 ]] && declare -f metrics_append_warmup >/dev/null 2>&1; then
        metrics_append_warmup "$model" "$size" "$status" "$duration_ms" "$ram_before" "$tps" "$ram_used" "$load_sec"
    else
        # Fallback: log mínimo no arquivo JSONL diretamente
        mkdir -p "$(dirname "$METRICS_JSONL")"
        echo "[$(date -Iseconds)] $model | $status | ${duration_ms}ms | ${tps} tok/s" >> "${METRICS_JSONL}.fallback"
    fi
}

# ============================================================================
# RELATÓRIO FINAL
# ============================================================================
show_final_report() {
    local model_key="$1"
    local model_name model_tag base_tag
    model_name=$(get_ram_requirements "$model_key" "name")
    model_tag=$(get_ram_requirements "$model_key" "model")
    base_tag=$(get_ram_requirements "$model_key" "base")

    echo -e "\n${GREEN}${BOLD}══════════════════════════════════════════${NC}"
    echo -e "${GREEN}${BOLD}  ✅ SETUP CONCLUÍDO (v6.1 PRODUCTION)${NC}"
    echo -e "${GREEN}${BOLD}══════════════════════════════════════════${NC}"
    echo -e "${CYAN}Modelo:${NC}  ${GREEN}${model_name}${NC}"
    echo -e "${CYAN}Tag:${NC}     ${model_tag}"
    [[ -n "$base_tag" && "$base_tag" != "-" ]] && echo -e "${CYAN}Base:${NC}     ${base_tag}"
    echo -e "${CYAN}WebUI:${NC}   http://localhost:8080"
    echo -e "${CYAN}RAM:${NC}     $(free -g | awk '/^Mem:/{print $7}')GB livre / $(free -g | awk '/^Mem:/{print $2}')GB total"
    echo -e "${CYAN}Log:${NC}     ${LOG}"

    if [[ -f "$METRICS_JSONL" ]]; then
        echo -e "${CYAN}Métricas:${NC} ${METRICS_JSONL} ($(wc -l < "$METRICS_JSONL") entradas)"
    else
        echo -e "${CYAN}Métricas:${NC} (nenhuma entrada registrada)"
    fi

    if [[ "${METRICS_ENABLED:-0}" -eq 1 ]]; then
        echo -e "${CYAN}Módulo:${NC}   ${GREEN}metrics_core.sh${NC} (ativo)"
    else
        echo -e "${CYAN}Módulo:${NC}   ${YELLOW}não carregado${NC}"
    fi

    echo -e "\n${YELLOW}🛡️ Proteções Ativas:${NC}"
    echo -e "   • OOM Score: -500 (Protege IA do Kernel Killer)"
    echo -e "   • Docker Swap: Zero (Força uso de RAM/NVMe puro)"
    echo -e "   • Fail Gracefully: Trap ativo (Ctrl+C limpa containers)"
    echo -e "   • Log Rotation: Mantém apenas os 5 últimos logs"
    echo -e "   • Warmup Robusto: Validação via API REST + métricas persistidas"

    log "Setup concluído com sucesso: ${model_name}"
}

# ============================================================================
# MAIN
# ============================================================================
main() {
    validate_system
    apply_system_tuning

    if [[ -n "$MODEL_CHOICE" ]]; then
        local resolved_key
        resolved_key=$(resolve_model_key "$MODEL_CHOICE" 2>/dev/null) || {
            echo -e "${RED}❌ Modelo desconhecido: '${MODEL_CHOICE}'${NC}" >&2
            MODEL_CHOICE=""
            select_model_inline
            MODEL_CHOICE="$SELECTED_MODEL_KEY"
        }
        [[ -n "${resolved_key:-}" ]] && MODEL_CHOICE="$resolved_key"
    else
        select_model_inline
        MODEL_CHOICE="$SELECTED_MODEL_KEY"
    fi

    if [[ "$MODEL_CHOICE" != "none" ]]; then
        check_ram_with_margin "$MODEL_CHOICE"
    fi

    ensure_images
    create_containers
    prepare_models "$MODEL_CHOICE"
    warmup_model "$MODEL_CHOICE"
    show_final_report "$MODEL_CHOICE"
}

main
