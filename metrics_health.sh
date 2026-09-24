#!/usr/bin/env bash
# =============================================================================
# metrics_health.sh v1.1 - Healthcheck rápido de performance
# =============================================================================
# Este script é chamado pelo status_ia.sh para exibir 2-3 linhas resumidas.
# Não é interativo, não pede input, não modifica nada.
#
# EXIT CODES:
#   0 = Tudo OK
#   1 = Alerta de degradação
#   2 = Sem baseline (não é erro, apenas aviso)
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/metrics_core.sh"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

[[ ! -f "$METRICS_JSONL" ]] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

models=$(metrics_list_models)
[[ -z "$models" ]] && exit 0

if [[ ! -f "$METRICS_BASELINE" ]]; then
    echo -e "  ${YELLOW}ℹ${NC} Baseline não definido. Execute: ./metrics_report.sh --save-baseline"
    exit 2
fi

alerts=0
stable=0
improved=0

while IFS= read -r model; do
    [[ -z "$model" ]] && continue
    delta=$(metrics_compare_baseline "$model")
    rc=$?

    case $rc in
        1)
            alerts=$((alerts + 1))
            echo -e "  ${RED}⚠${NC}  ${model}: degradação de ${delta}%" ;;
        2)
            improved=$((improved + 1)) ;;
        0)
            stable=$((stable + 1)) ;;
    esac
done <<< "$models"

if [[ $alerts -gt 0 ]]; then
    echo -e "      Detalhes: ./metrics_report.sh --health"
    exit 1
elif [[ $improved -gt 0 ]]; then
    echo -e "  ${GREEN}✓${NC}  ${stable} estáveis, ${improved} melhoraram"
    exit 0
else
    echo -e "  ${GREEN}✓${NC}  ${stable} modelo(s) estável(is)"
    exit 0
fi
