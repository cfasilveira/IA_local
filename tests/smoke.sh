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
echo "== [6/6] validate_system + cleanup cirurgico (stubs, sem docker) =="
# T1: stack nossa rodando + porta bound por docker-proxy (PID fantasma que
# nunca aparece no `docker top`). O codigo antigo errava: "processo externo".
# (o `err` interno faz exit: o rc e o exit code do subshell, nao echo interno)
t1_out=$(bash -c '
  eval "$(sed -n "/^validate_system()/,/^}/p" setup_ia.sh)"
  log(){ :; }; warn(){ :; }; err(){ echo "ERR:$1" >&2; exit 1; }
  BASE_DIR=/tmp; LOG=/tmp/smoke_fake.log
  ss(){ echo "tcp LISTEN 0 4096 *:11434 *:* users:(\"docker-proxy\",pid=99999,fd=4)";
        echo "tcp LISTEN 0 4096 *:8080 *:* users:(\"docker-proxy\",pid=99999,fd=4)"; return 0; }
  sudo(){ "$@"; }
  docker(){ case "$1 $2" in
    "info"*) return 0;;
    "ps --format"*) printf "ollama-service\nopen-webui-gui\n"; return 0;;
    *) echo "PID TTY TIME CMD"; return 0;; esac; }
  free(){ echo "Mem: 31 9 22 0 0 22"; }
  validate_system >/dev/null 2>/tmp/smoke_t1err.txt; echo "rc=$?"
' 2>/dev/null); t1_rc=$?
[[ "$t1_rc" == "0" && "$t1_out" == "rc=0" ]] && ok "stack propria nao e 'processo externo'" || bad "stack propria rejeitada (exit=$t1_rc out=$t1_out err=$(cat /tmp/smoke_t1err.txt 2>/dev/null))"

# T2: processo realmente externo, sem containers nossos -> deve barrar
t2_out=$(bash -c '
  eval "$(sed -n "/^validate_system()/,/^}/p" setup_ia.sh)"
  log(){ :; }; warn(){ :; }; err(){ echo "ERR:$1"; exit 1; }
  BASE_DIR=/tmp; LOG=/tmp/smoke_fake.log
  ss(){ echo "tcp LISTEN 0 128 *:11434 *:* users:(\"algum-outro\",pid=1234,fd=3)"; return 0; }
  sudo(){ "$@"; }
  docker(){ case "$1 $2" in
    "info"*) return 0;;
    "ps --format"*) return 0;;
    *) echo "PID TTY TIME CMD"; return 0;; esac; }
  free(){ echo "Mem: 31 9 22 0 0 22"; }
  validate_system 2>&1
' 2>/dev/null); t2_rc=$?
echo "$t2_out" | grep -q "processo externo" && ok "processo externo ainda barrado" || bad "processo externo nao barrado"
[[ "$t2_rc" == "1" ]] && ok "validate falha com rc=1" || bad "rc inesperado: $t2_rc [$t2_out]"

# T3: falha pre-criacao nao remove nada (stack saudavel preservada)
rm -f /tmp/smoke_rm.log
bash -c '
  eval "$(sed -n "/^cleanup()/,/^}/p" setup_ia.sh)"
  warn(){ :; }
  docker(){ echo "$*" >> /tmp/smoke_rm.log; return 0; }
  CREATED_CONTAINERS=()
  false; cleanup >/dev/null 2>&1
' 2>/dev/null
[[ ! -s /tmp/smoke_rm.log ]] && ok "cleanup pre-criacao nao remove nada" || bad "cleanup removeu: $(cat /tmp/smoke_rm.log)"

# T4: falha pos-criacao remove SOMENTE o que o run criou
rm -f /tmp/smoke_rm.log
bash -c '
  eval "$(sed -n "/^cleanup()/,/^}/p" setup_ia.sh)"
  warn(){ :; }
  docker(){ echo "$*" >> /tmp/smoke_rm.log; return 0; }
  CREATED_CONTAINERS=("ollama-service")
  false; cleanup >/dev/null 2>&1
' 2>/dev/null
[[ "$(cat /tmp/smoke_rm.log 2>/dev/null)" == "rm -f ollama-service" ]] && ok "cleanup pos-criacao remove so o criado" || bad "cleanup inesperado: [$(cat /tmp/smoke_rm.log 2>/dev/null)]"
rm -f /tmp/smoke_rm.log

echo ""
echo "Resultado: ${pass} pass, ${fail} fail"
[[ "$fail" -eq 0 ]]
