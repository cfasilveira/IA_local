#!/usr/bin/env bash
# =============================================================================
# metrics_report.sh v1.1 - Relatório de performance das LLMs
# =============================================================================
# USO:
#   ./metrics_report.sh                # Relatório completo
#   ./metrics_report.sh <modelo>       # Filtrar por modelo
#   ./metrics_report.sh --last <N>     # Últimas N execuções
#   ./metrics_report.sh --health       # Apenas healthcheck
#   ./metrics_report.sh --save-baseline # Salvar baseline atual
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/metrics_core.sh"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
BOLD='\033[1m'

# ============================================================================
# PARSER DE ARGUMENTOS
# ============================================================================
FILTER_MODEL=""
LAST_N=0
HEALTH_ONLY=0
SAVE_BASELINE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --last)
            if [[ $# -lt 2 || ! "$2" =~ ^[0-9]+$ ]]; then
                echo -e "${RED}❌ --last requer um número.${NC}" >&2
                exit 1
            fi
            LAST_N="$2"; shift 2 ;;
        --health) HEALTH_ONLY=1; shift ;;
        --save-baseline) SAVE_BASELINE=1; shift ;;
        --help|-h)
            cat << HELP
Uso: $0 [opções] [modelo]

OPÇÕES:
    (sem args)          Relatório completo
    <modelo>            Filtrar por modelo específico
    --last <N>          Últimas N execuções
    --health            Apenas healthcheck de regressão
    --save-baseline     Salva snapshot atual como baseline

EXEMPLOS:
    $0                       # Relatório completo
    $0 mistral-nemo          # Detalhes do Mistral
    $0 --last 20             # Últimas 20 execuções
    $0 --health              # Apenas alertas de degradação
HELP
            exit 0 ;;
        -*) echo -e "${RED}❌ Opção desconhecida: $1${NC}" >&2; exit 1 ;;
        *) FILTER_MODEL="$1"; shift ;;
    esac
done

# ============================================================================
# VERIFICAÇÕES INICIAIS
# ============================================================================
if [[ ! -f "$METRICS_JSONL" ]]; then
    echo -e "${YELLOW}⚠️  Nenhuma métrica encontrada em $METRICS_JSONL${NC}"
    echo "Execute './setup_ia.sh' para gerar dados."
    exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
    echo -e "${RED}❌ jq não está instalado. Instale com: sudo apt install jq${NC}" >&2
    exit 1
fi

# ============================================================================
# FUNÇÕES DE FORMATAÇÃO
# ============================================================================
format_tps() {
    local tps="$1"
    if [[ "$tps" == "0" || "$tps" == "null" || -z "$tps" ]]; then
        echo "-"
    else
        printf "%.2f tok/s" "$tps"
    fi
}

format_pct() {
    local pct="$1"
    if [[ -z "$pct" || "$pct" == "null" ]]; then
        echo "-"
        return
    fi
    if (( $(awk -v p="$pct" 'BEGIN { print (p >= 0) ? 1 : 0 }') )); then
        echo -e "${GREEN}+${pct}%${NC}"
    else
        echo -e "${RED}${pct}%${NC}"
    fi
}

# ============================================================================
# MODO: SALVAR BASELINE
# ============================================================================
if [[ "$SAVE_BASELINE" -eq 1 ]]; then
    metrics_save_baseline
    echo -e "${GREEN}✅ Baseline salvo em $METRICS_BASELINE${NC}"
    exit 0
fi

# ============================================================================
# MODO: HEALTHCHECK
# ============================================================================
run_healthcheck() {
    echo -e "${CYAN}${BOLD}🩺 Healthcheck de Performance${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"

    if [[ ! -f "$METRICS_BASELINE" ]]; then
        echo -e "${YELLOW}⚠️  Baseline não existe. Execute:${NC}"
        echo "   ./metrics_report.sh --save-baseline"
        return 0
    fi

    local models
    models=$(metrics_list_models)
    if [[ -z "$models" ]]; then
        echo "Nenhum modelo registrado."
        return 0
    fi

    local alerts=0
    while IFS= read -r model; do
        [[ -z "$model" ]] && continue
        local delta rc
        delta=$(metrics_compare_baseline "$model")
        rc=$?

        case $rc in
            1)
                echo -e "${RED}⚠️  ${model}: DEGRADAÇÃO de ${delta}%${NC}"
                alerts=$((alerts + 1)) ;;
            2)
                echo -e "${GREEN}✅ ${model}: melhoria de ${delta}%${NC}" ;;
            0)
                echo -e "${CYAN}✓${NC}  ${model}: estável (${delta}%)" ;;
        esac
    done <<< "$models"

    echo ""
    if [[ $alerts -gt 0 ]]; then
        echo -e "${RED}${BOLD}${alerts} alerta(s) de degradação detectado(s).${NC}"
        echo "Considere investigar com: ./metrics_report.sh <modelo>"
        return 1
    else
        echo -e "${GREEN}${BOLD}✅ Todos os modelos estáveis.${NC}"
        return 0
    fi
}

if [[ "$HEALTH_ONLY" -eq 1 ]]; then
    run_healthcheck
    exit $?
fi

# ============================================================================
# MODO: ÚLTIMAS N EXECUÇÕES
# ============================================================================
if [[ "$LAST_N" -gt 0 ]]; then
    echo -e "${CYAN}${BOLD}📋 Últimas ${LAST_N} execuções${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
    tail -n "$LAST_N" "$METRICS_LOG" 2>/dev/null || echo "Sem dados."
    exit 0
fi

# ============================================================================
# RELATÓRIO POR MODELO (função)
# ============================================================================
print_model_report() {
    local model="$1"
    local stats
    stats=$(metrics_get_model_stats "$model")

    local execucoes sucessos falhas media melhor pior ultima status_ultimo ultimo_ts media_load
    execucoes=$(echo "$stats" | jq -r '.execucoes // 0')
    sucessos=$(echo "$stats" | jq -r '.sucessos // 0')
    falhas=$(echo "$stats" | jq -r '.falhas // 0')
    media=$(echo "$stats" | jq -r '.media_tps // 0')
    melhor=$(echo "$stats" | jq -r '.melhor_tps // 0')
    pior=$(echo "$stats" | jq -r '.pior_tps // 0')
    ultima=$(echo "$stats" | jq -r '.ultima_tps // 0')
    status_ultimo=$(echo "$stats" | jq -r '.ultimo_status // "unknown"')
    ultimo_ts=$(echo "$stats" | jq -r '.ultimo_timestamp // ""')
    media_load=$(echo "$stats" | jq -r '.media_load_sec // 0')

    echo -e "${CYAN}${BOLD}📊 ${model}${NC}"
    echo -e "${BLUE}───────────────────────────────────────────────────────${NC}"
    printf "  Execuções:        %s\n" "$execucoes"

    if [[ "$falhas" -gt 0 ]]; then
        printf "  Sucessos:         %s\n" "$sucessos"
        printf "  Falhas:           ${RED}%s${NC}\n" "$falhas"
    fi

    printf "  Última execução:  %s (%s)\n" "$(format_tps "$ultima")" "${ultimo_ts:0:19}"
    printf "  Status final:     %s\n" "$status_ultimo"

    if (( $(awk -v m="$media" 'BEGIN { print (m > 0) ? 1 : 0 }') )); then
        printf "  Velocidade média: ${GREEN}%s${NC}\n" "$(format_tps "$media")"
        printf "  Melhor:           %s\n" "$(format_tps "$melhor")"
        printf "  Pior:             %s\n" "$(format_tps "$pior")"
        printf "  Load médio:       %.1fs\n" "$media_load"
    fi

    # Comparação com baseline
    if [[ -f "$METRICS_BASELINE" ]]; then
        local delta rc
        delta=$(metrics_compare_baseline "$model")
        rc=$?
        case $rc in
            1) printf "  vs Baseline:      ${RED}DEGRADOU %s%%${NC}\n" "$delta" ;;
            2) printf "  vs Baseline:      ${GREEN}MELHOROU %s%%${NC}\n" "$delta" ;;
            0) printf "  vs Baseline:      estável (%s%%)\n" "$delta" ;;
        esac
    fi

    echo ""
}

# ============================================================================
# MODO: FILTRO POR MODELO ESPECÍFICO
# ============================================================================
if [[ -n "$FILTER_MODEL" ]]; then
    local_stats=$(metrics_get_model_stats "$FILTER_MODEL")
    if [[ "$local_stats" == "{}" ]]; then
        echo -e "${RED}❌ Modelo '${FILTER_MODEL}' não encontrado.${NC}"
        echo "Modelos disponíveis:"
        metrics_list_models | sed 's/^/  - /'
        exit 1
    fi
    print_model_report "$FILTER_MODEL"
    exit 0
fi

# ============================================================================
# MODO: RELATÓRIO COMPLETO
# ============================================================================
echo -e "${CYAN}${BOLD}📊 RELATÓRIO DE PERFORMANCE${NC}"
echo -e "${CYAN}  Gerado em: $(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo ""

all_models=$(metrics_list_models)
if [[ -z "$all_models" ]]; then
    echo "Nenhum modelo registrado."
    exit 0
fi

while IFS= read -r model; do
    [[ -z "$model" ]] && continue
    print_model_report "$model"
done <<< "$all_models"

# Sumário
total_entries=$(wc -l < "$METRICS_JSONL" 2>/dev/null || echo "0")
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}Total de entradas:${NC} $total_entries"
echo -e "${CYAN}Arquivo de dados:${NC} $METRICS_JSONL"
echo -e "${CYAN}Log legível:${NC}     $METRICS_LOG"
[[ -f "$METRICS_BASELINE" ]] && echo -e "${CYAN}Baseline:${NC}        $METRICS_BASELINE"
echo ""
