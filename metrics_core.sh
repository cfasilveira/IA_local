#!/usr/bin/env bash
# =============================================================================
# metrics_core.sh v1.0 - Biblioteca central de métricas
# =============================================================================
# FILOSOFIA:
#   - Funções puras, sem efeitos colaterais
#   - Não imprime nada (apenas retorna dados)
#   - Todos os arquivos de dados são configuráveis
#
# ARQUIVOS:
#   metrics.jsonl       - Dados brutos (JSON Lines)
#   metrics.log         - Log legível (tabular)
#   .metrics_baseline.json - Baseline por modelo
#
# USO:
#   source metrics_core.sh
#   metrics_append_warmup "modelo" "size_gb" "status" "duration_ms" ...
# =============================================================================

# Impedir execução direta
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Este script deve ser sourceado, não executado diretamente."
    exit 1
fi

# ============================================================================
# CONFIGURAÇÃO
# ============================================================================

export METRICS_DIR="${METRICS_DIR:-/home/carlos/Projetos/AI}"
export METRICS_JSONL="${METRICS_JSONL:-${METRICS_DIR}/metrics.jsonl}"
export METRICS_LOG="${METRICS_LOG:-${METRICS_DIR}/metrics.log}"
export METRICS_BASELINE="${METRICS_BASELINE:-${METRICS_DIR}/.metrics_baseline.json}"

# Retenção (em dias). 0 = sem limite
export METRICS_RETENTION_DAYS="${METRICS_RETENTION_DAYS:-365}"

# ============================================================================
# ESCRITA: Registra um evento de warmup
# ============================================================================
# Uso:
#   metrics_append_warmup <model> <size_gb> <status> <duration_ms> <ram_before_gb>
#                         [tokens_per_sec] [ram_used_gb] [load_sec]
# ============================================================================
metrics_append_warmup() {
    local model="$1"
    local size_gb="$2"
    local status="$3"
    local duration_ms="$4"
    local ram_before_gb="$5"
    local tokens_per_sec="${6:-0}"
    local ram_used_gb="${7:-0}"
    local load_sec="${8:-0}"

    mkdir -p "$METRICS_DIR"

    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    local ts_iso
    ts_iso=$(date -Iseconds)

    # -------------------------------------------------------------------------
    # Camada 1: JSON Lines (dados brutos)
    # -------------------------------------------------------------------------
    if command -v jq >/dev/null 2>&1; then
        jq -n -c \
            --arg ts "$ts_iso" \
            --arg model "$model" \
            --argjson size "$size_gb" \
            --arg status "$status" \
            --argjson duration_ms "$duration_ms" \
            --argjson ram_before "$ram_before_gb" \
            --argjson tps "$tokens_per_sec" \
            --argjson ram_used "$ram_used_gb" \
            --argjson load_sec "$load_sec" \
            '{
                timestamp: $ts,
                model: $model,
                size_gb: $size,
                status: $status,
                duration_ms: $duration_ms,
                ram_before_gb: $ram_before,
                tokens_per_sec: $tps,
                ram_used_gb: $ram_used,
                load_sec: $load_sec
            }' >> "$METRICS_JSONL" 2>/dev/null || true
    fi

    # -------------------------------------------------------------------------
    # Camada 2: Log legível (tabular)
    # -------------------------------------------------------------------------
    local status_display
    case "$status" in
        success)   status_display="OK     " ;;
        timeout)   status_display="TIMEOUT" ;;
        api_error) status_display="API_ERR" ;;
        empty_response|missing_response_field) status_display="EMPTY  " ;;
        api_reported_error) status_display="API_FAIL" ;;
        *)         status_display="${status:0:7} " ;;
    esac

    local tps_display
    if [[ "$tokens_per_sec" != "0" && "$tokens_per_sec" != "n/d" ]]; then
        tps_display=$(printf "%6.2f tok/s" "$tokens_per_sec")
    else
        tps_display="         -"
    fi

    local load_display
    if [[ "$load_sec" != "0" ]]; then
        load_display=$(printf "%5.1fs" "$load_sec")
    else
        load_display="     -"
    fi

    local dur_display
    dur_display=$(printf "%8.1fs" "$(awk -v ms="$duration_ms" 'BEGIN{printf "%.1f", ms/1000}')")

    printf "%s | %-28s | %5sGB | %s | %s | %s | %s | RAM: %2sGB\n" \
        "$ts" "$model" "$size_gb" "$status_display" "$dur_display" "$load_display" "$tps_display" "$ram_used_gb" \
        >> "$METRICS_LOG"

    # -------------------------------------------------------------------------
    # Retenção: remove entradas antigas
    # -------------------------------------------------------------------------
    metrics_prune_old
}

# ============================================================================
# LIMPEZA: Remove entradas antigas conforme retenção
# ============================================================================
metrics_prune_old() {
    [[ "$METRICS_RETENTION_DAYS" -le 0 ]] && return 0

    local cutoff_ts
    cutoff_ts=$(date -d "${METRICS_RETENTION_DAYS} days ago" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "")
    [[ -z "$cutoff_ts" ]] && return 0

    # Prune metrics.log
    if [[ -f "$METRICS_LOG" ]]; then
        awk -v cutoff="$cutoff_ts" '$0 >= cutoff' "$METRICS_LOG" > "${METRICS_LOG}.tmp" 2>/dev/null || true
        [[ -s "${METRICS_LOG}.tmp" ]] && mv "${METRICS_LOG}.tmp" "$METRICS_LOG" || rm -f "${METRICS_LOG}.tmp"
    fi

    # Prune metrics.jsonl (usa jq para filtrar por timestamp)
    if [[ -f "$METRICS_JSONL" ]] && command -v jq >/dev/null 2>&1; then
        local cutoff_iso
        cutoff_iso=$(date -d "${METRICS_RETENTION_DAYS} days ago" -Iseconds 2>/dev/null || echo "")
        if [[ -n "$cutoff_iso" ]]; then
            jq -c --arg cutoff "$cutoff_iso" 'select(.timestamp >= $cutoff)' \
                "$METRICS_JSONL" > "${METRICS_JSONL}.tmp" 2>/dev/null || true
            [[ -s "${METRICS_JSONL}.tmp" ]] && mv "${METRICS_JSONL}.tmp" "$METRICS_JSONL" || rm -f "${METRICS_JSONL}.tmp"
        fi
    fi
}

# ============================================================================
# LEITURA: Estatísticas por modelo
# ============================================================================
# Uso: metrics_get_model_stats <model>
# Retorna JSON: {"execucoes": N, "sucessos": N, "falhas": N, "media_tps": X,
#                "melhor_tps": X, "pior_tps": X, "ultima_tps": X, ...}
# ============================================================================
metrics_get_model_stats() {
    local model="$1"
    [[ ! -f "$METRICS_JSONL" ]] && { echo "{}"; return 0; }
    command -v jq >/dev/null 2>&1 || { echo "{}"; return 0; }

    jq -s --arg model "$model" '
        [.[] | select(.model == $model)] as $filtered |
        if ($filtered | length) == 0 then
            {}
        else
            {
                execucoes: ($filtered | length),
                sucessos: ([$filtered[] | select(.status == "success")] | length),
                falhas: ([$filtered[] | select(.status != "success")] | length),
                media_tps: ([$filtered[] | select(.status == "success") | .tokens_per_sec] | 
                            if length > 0 then add / length else 0 end),
                melhor_tps: ([$filtered[] | select(.status == "success") | .tokens_per_sec] | 
                             if length > 0 then max else 0 end),
                pior_tps: ([$filtered[] | select(.status == "success" and .tokens_per_sec > 0) | .tokens_per_sec] | 
                           if length > 0 then min else 0 end),
                ultima_tps: ($filtered[-1].tokens_per_sec // 0),
                ultimo_status: ($filtered[-1].status // "unknown"),
                ultimo_timestamp: ($filtered[-1].timestamp // ""),
                media_load_sec: ([$filtered[] | select(.load_sec > 0) | .load_sec] | 
                                 if length > 0 then add / length else 0 end)
            }
        end
    ' "$METRICS_JSONL" 2>/dev/null || echo "{}"
}

# ============================================================================
# LEITURA: Lista todos os modelos registrados
# ============================================================================
metrics_list_models() {
    [[ ! -f "$METRICS_JSONL" ]] && return 0
    command -v jq >/dev/null 2>&1 || return 0

    jq -r -s '[.[].model] | unique | .[]' "$METRICS_JSONL" 2>/dev/null || true
}

# ============================================================================
# LEITURA: Últimas N execuções
# ============================================================================
metrics_get_last_n() {
    local n="${1:-10}"
    [[ ! -f "$METRICS_JSONL" ]] && return 0
    command -v jq >/dev/null 2>&1 || return 0

    jq -s ".[-${n}:]" "$METRICS_JSONL" 2>/dev/null || echo "[]"
}

# ============================================================================
# BASELINE: Salva snapshot atual como baseline
# ============================================================================
metrics_save_baseline() {
    [[ ! -f "$METRICS_JSONL" ]] && { echo "{}" > "$METRICS_BASELINE"; return 0; }
    command -v jq >/dev/null 2>&1 || return 0

    local models
    models=$(metrics_list_models)
    [[ -z "$models" ]] && { echo "{}" > "$METRICS_BASELINE"; return 0; }

    local baseline="{"
    local first=1

    while IFS= read -r model; do
        [[ -z "$model" ]] && continue
        local stats
        stats=$(metrics_get_model_stats "$model")

        local media_tps
        media_tps=$(echo "$stats" | jq -r '.media_tps // 0')
        local media_load
        media_load=$(echo "$stats" | jq -r '.media_load_sec // 0')

        [[ $first -eq 0 ]] && baseline+=","
        first=0

        baseline+=$(jq -c -n --arg m "$model" --argjson tps "$media_tps" --argjson load "$media_load" \
            '{key: $m, value: {media_tps: $tps, media_load_sec: $load}}' | jq -c '{("'"$model"'"): .value}')
    done <<< "$models"

    baseline+="}"
    echo "$baseline" | jq '.' > "$METRICS_BASELINE" 2>/dev/null || echo "{}" > "$METRICS_BASELINE"
}

# ============================================================================
# BASELINE: Compara performance atual com baseline
# ============================================================================
# Retorna: 0 = OK, 1 = degradação detectada, 2 = melhoria significativa
# Imprime: percentual de mudança
metrics_compare_baseline() {
    local model="$1"
    [[ ! -f "$METRICS_BASELINE" ]] && return 0

    local baseline_tps
    baseline_tps=$(jq -r --arg m "$model" '.[$m].media_tps // 0' "$METRICS_BASELINE" 2>/dev/null || echo "0")
    [[ "$baseline_tps" == "0" || "$baseline_tps" == "null" ]] && return 0

    local current_stats current_tps
    current_stats=$(metrics_get_model_stats "$model")
    current_tps=$(echo "$current_stats" | jq -r '.media_tps // 0')

    local delta_pct
    delta_pct=$(awk -v cur="$current_tps" -v base="$baseline_tps" 'BEGIN {
        if (base == 0) { print 0; exit }
        printf "%.1f", ((cur - base) / base) * 100
    }')

    echo "$delta_pct"

    # Classificação
    local abs_delta
    abs_delta=$(awk -v d="$delta_pct" 'BEGIN { d = (d < 0) ? -d : d; print d }')

    if (( $(awk -v d="$abs_delta" 'BEGIN { print (d >= 20) ? 1 : 0 }') )); then
        if (( $(awk -v d="$delta_pct" 'BEGIN { print (d < 0) ? 1 : 0 }') )); then
            return 1  # degradação
        else
            return 2  # melhoria
        fi
    fi

    return 0
}
