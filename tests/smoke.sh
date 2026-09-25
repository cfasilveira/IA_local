#!/usr/bin/env bash
# smoke.sh - gate de qualidade sem dependencias externas (bash + shellcheck)
# Uso: bash tests/smoke.sh
# Falha (exit 1) no primeiro gate quebrado.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

SCRIPTS=(setup_ia.sh ia_gatekeeper.sh lib_ia.sh metrics_core.sh metrics_report.sh
         metrics_health.sh qwen-dev-cli.sh ollama-tui.sh shutdown_ia.sh
         status_ia.sh fix_ollama_nativo.sh chat_IA.sh coletar_dados.sh mini-api/run.sh)

pass=0; fail=0
ok()   { pass=$((pass+1)); echo "  PASS $1"; }
bad()  { fail=$((fail+1)); echo "  FAIL $1"; }

echo "== [1/4] bash -n (sintaxe) =="
for f in "${SCRIPTS[@]}"; do
    if bash -n "$f" 2>/tmp/smoke_err.txt; then ok "$f"; else bad "$f: $(cat /tmp/smoke_err.txt)"; fi
done

echo "== [2/4] shellcheck -S error (sem erros) =="
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -S error setup_ia.sh ia_gatekeeper.sh lib_ia.sh qwen-dev-cli.sh \
        ollama-tui.sh shutdown_ia.sh metrics_core.sh 2>/tmp/smoke_sc.txt; then
        ok "shellcheck errors=0"
    else
        bad "shellcheck: $(head -5 /tmp/smoke_sc.txt)"
    fi
else
    echo "  SKIP shellcheck ausente"
fi

echo "== [3/4] guard_transition (qwen-dev-cli) =="
# Extrai a funcao real do script e exercita transicoes validas/invalidas
guard_src="$(sed -n '/^guard_transition()/,/^}/p' qwen-dev-cli.sh)"
if [[ -z "$guard_src" ]]; then
    bad "guard_transition nao encontrada"
else
    eval "$guard_src"
    guard_transition PLANNED AUTHORIZED && ok "PLANNED->AUTHORIZED" || bad "PLANNED->AUTHORIZED bloqueada"
    guard_transition TESTING FAILED && ok "TESTING->FAILED" || bad "TESTING->FAILED bloqueada"
    if guard_transition PLANNED RUNNING; then bad "PLANNED->RUNNING deveria bloquear"; else ok "PLANNED->RUNNING bloqueada"; fi
fi

echo "== [4/4] lib_ia + warmup timeout =="
warmup_src="$(sed -n '/^get_warmup_timeout()/,/^}/p' setup_ia.sh)"
if [[ -z "$warmup_src" ]]; then
    bad "get_warmup_timeout nao encontrada"
else
    eval "$warmup_src"
    [[ "$(get_warmup_timeout 7.1)" == "120" ]] && ok "7.1GB->120s" || bad "7.1GB!=120s"
    [[ "$(get_warmup_timeout 10)" == "180" ]] && ok "10GB->180s" || bad "10GB!=180s"
    [[ "$(get_warmup_timeout 15)" == "300" ]] && ok "15GB->300s" || bad "15GB!=300s"
fi
# get_container_status deve ecoar status, nunca falhar com 'return' nao-numerico
if bash -c 'source lib_ia.sh && out=$(get_container_status) && [[ "$out" =~ ^(running|stopped|not_found)$ ]]' 2>/dev/null; then
    ok "get_container_status ecoa status valido"
else
    bad "get_container_status retorno invalido"
fi

echo ""
echo "== [5/5] registro canonico de modelos (lib_ia) =="
source lib_ia.sh
[[ "$(ia_model_tag qwen-coder)" == "qwen2.5-coder:14b-instruct-q8_0" ]] && ok "tag qwen-coder" || bad "tag qwen-coder"
[[ "$(ia_model_min_ram mistral-base)" == "8" ]] && ok "min mistral-base=8" || bad "min mistral-base"
[[ "$(ia_model_min_ram mistral-otimizado)" == "10" ]] && ok "min mistral-otimizado=10" || bad "min mistral-otimizado"
[[ "$(ia_model_key_for_tag qwen-dev-pro:latest)" == "qwen-base" ]] && ok "key-for-tag qwen-dev-pro" || bad "key-for-tag qwen-dev-pro"
# consistencia: setup_ia e gatekeeper devem refletir o canonico
grep -q 'source "${BASE_DIR}/lib_ia.sh"' setup_ia.sh && ok "setup consome lib_ia" || bad "setup nao consome lib_ia"
grep -q 'ia_model_min_ram' ia_gatekeeper.sh && ok "gatekeeper consome lib_ia" || bad "gatekeeper nao consome lib_ia"

echo ""
echo "Resultado: ${pass} pass, ${fail} fail"
[[ "$fail" -eq 0 ]]
