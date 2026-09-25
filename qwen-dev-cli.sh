#!/usr/bin/env bash
# =============================================================================
# qwen-dev-cli.sh v6.4 - ORCHESTRATOR (Protocolo QWEN_PROTOCOL v1)
# v6.4 corrige: (1) loop de retry sem linhas invalidas + ERROR_LOG alimentado
#               por LAST_EXEC_OUTPUT; (2) process_proposals sem re-parse
#               destrutivo (fallback de protocolo preservado).
# Maquina de estados: PLANNED>AUTHORIZED>RUNNING>TESTING>VALIDATED|FAILED
# =============================================================================
set -uo pipefail

MODEL="qwen-dev-pro"
WORKSPACE="/home/carlos/Projetos/AI"
DATA_DIR="${WORKSPACE}/data"
TEMP_SCRIPT="/tmp/qwen_generated_setup.sh"
ERROR_LOG="/tmp/qwen_last_error.log"
PAYLOAD_LOG="/tmp/qwen_last_payload.json"
MAX_RETRY=3
MAX_CONTEXT=5
MAX_PROMPT_CHARS=3000
API_TIMEOUT=1800
CONTEXT_BUDGET=2048
CHECK_TIMEOUT=120
PROMPT_FILE="${WORKSPACE}/prompts/system-prompt-qwen-dev.txt"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
BOLD='\033[1m'

PROJ_OVERRIDE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --model)
            if [[ $# -lt 2 || "$2" == --* ]]; then echo -e "${RED}❌ --model requer argumento.${NC}" >&2; exit 1; fi
            MODEL="$2"; shift 2 ;;
        --prompt)
            if [[ $# -lt 2 || "$2" == --* ]]; then echo -e "${RED}❌ --prompt requer caminho.${NC}" >&2; exit 1; fi
            PROMPT_FILE="$2"; shift 2 ;;
        --projeto)
            if [[ $# -lt 2 || "$2" == --* ]]; then echo -e "${RED}❌ --projeto requer nome/caminho.${NC}" >&2; exit 1; fi
            PROJ_OVERRIDE="$2"; shift 2 ;;
        *) echo -e "${RED}❌ Flag desconhecida: $1${NC}" >&2; exit 1 ;;
    esac
done

command -v jq >/dev/null 2>&1 || { echo -e "${RED}[ERRO]${NC} jq não instalado: sudo apt install -y jq" >&2; exit 1; }

# ─────────────────────────────────────────────────────────────
# MEMORIAS: estado/eventos/conversa por projeto | global sem projeto
# ─────────────────────────────────────────────────────────────
PROJECT_DIR=""; QWEN_DIR=""; STATE_FILE=""; EVENTS_FILE=""; CTX_YML=""; HISTORY_FILE=""; CHECKS_FILE=""
APPROVED_CHECKS=""
LAST_PROTO_VALIDATION="NONE"
LAST_EXEC_OUTPUT=""

ts() { date '+%Y-%m-%dT%H:%M:%S'; }

set_project_vars() {
    PROJECT_DIR="$1"
    QWEN_DIR="${PROJECT_DIR}/.qwen"
    STATE_FILE="${QWEN_DIR}/state"
    EVENTS_FILE="${QWEN_DIR}/events.log"
    CTX_YML="${QWEN_DIR}/context.yml"
    HISTORY_FILE="${QWEN_DIR}/history.json"
    CHECKS_FILE="${QWEN_DIR}/approved_checks"
    APPROVED_CHECKS=""
    if [[ -f "$CHECKS_FILE" && "$(cat "$STATE_FILE" 2>/dev/null)" == "AUTHORIZED" ]]; then
        APPROVED_CHECKS=$(cat "$CHECKS_FILE")
    fi
}

discover_project() {
    if [[ -n "$PROJ_OVERRIDE" ]]; then
        local p="$PROJ_OVERRIDE"
        if [[ ! -d "$p" ]]; then p="${WORKSPACE}/${p}"; fi
        if [[ -d "${p}/.qwen" ]]; then set_project_vars "$p"; return 0; fi
        HISTORY_FILE="${DATA_DIR}/global_history.json"; return 1
    fi
    local dir="$PWD"
    while [[ "$dir" != "/" ]]; do
        if [[ -d "${dir}/.qwen" ]]; then set_project_vars "$dir"; return 0; fi
        dir="$(dirname "$dir")"
    done
    HISTORY_FILE="${DATA_DIR}/global_history.json"
    return 1
}

cur_state() { cat "$STATE_FILE" 2>/dev/null || echo "NONE"; }

next_id() {
    local type="$1" prefix="$2" n
    n=$(grep -c "|${type}|" "$EVENTS_FILE" 2>/dev/null); n=${n:-0}
    printf '%s-%03d' "$prefix" $((n + 1))
}

append_event() {
    local type="$1" id="$2" authority="$3" ref="$4" payload="$5"
    payload="${payload//|//}"; payload="${payload//$'\n'/ }"
    echo "$(ts)|${type}|${id}|${authority}|${ref}|${payload}" >> "$EVENTS_FILE"
    render_context_view
}

guard_transition() {
    case "$1->$2" in
        ("PLANNED->AUTHORIZED"|"AUTHORIZED->RUNNING"|"RUNNING->TESTING"|"TESTING->VALIDATED"|"TESTING->FAILED"|"FAILED->PLANNED"|"VALIDATED->PLANNED") return 0 ;;
        *) return 1 ;;
    esac
}

set_state() {
    local new="$1" auth="${2:-cli}" cur
    cur=$(cur_state)
    if ! guard_transition "$cur" "$new"; then
        echo -e "${YELLOW}⚠️ Transição inválida: ${cur} → ${new} (ignorada).${NC}"
        return 1
    fi
    echo "$new" > "$STATE_FILE"
    append_event STATE "$(next_id STATE ST)" "$auth" "-" "de=${cur} para=${new}"
    echo -e "${GREEN}✅ Estado: ${cur} → ${new}${NC}"
}

render_context_view() {
    [[ -n "$PROJECT_DIR" && -d "$QWEN_DIR" ]] || return 0
    {
        echo "# Gerado pelo qwen-dev-cli v6.4. NAO editar manualmente."
        echo "project: $(basename "$PROJECT_DIR")"
        echo "path: ${PROJECT_DIR}"
        echo "state: $(cur_state)"
        local obj
        obj=$(grep '|OBJECTIVE|' "$EVENTS_FILE" 2>/dev/null | tail -n1 | cut -d'|' -f6-)
        echo "objective: |"
        if [[ -n "$obj" ]]; then echo "  ${obj}"; else echo "  (não definido)"; fi
        local cnt
        cnt=$(grep -c '|REQUIREMENT|' "$EVENTS_FILE" 2>/dev/null); cnt=${cnt:-0}
        if [[ "$cnt" -gt 0 ]]; then
            echo "requirements:"
            grep '|REQUIREMENT|' "$EVENTS_FILE" | while IFS='|' read -r _ _ id _ _ payload; do echo "- ${id}: ${payload} (autoridade: human)"; done
        else echo "requirements: []"; fi
        cnt=$(grep -c '|RESTRICT|' "$EVENTS_FILE" 2>/dev/null); cnt=${cnt:-0}
        if [[ "$cnt" -gt 0 ]]; then
            echo "restrictions:"
            grep '|RESTRICT|' "$EVENTS_FILE" | while IFS='|' read -r _ _ id _ _ payload; do echo "- ${id}: ${payload} (autoridade: human)"; done
        else echo "restrictions: []"; fi
        cnt=$(grep -c '|DECISION|' "$EVENTS_FILE" 2>/dev/null); cnt=${cnt:-0}
        if [[ "$cnt" -gt 0 ]]; then
            echo "decisions:"
            grep '|DECISION|' "$EVENTS_FILE" | while IFS='|' read -r _ _ id _ _ payload; do echo "- ${id}: ${payload} (autoridade: human)"; done
        else echo "decisions: []"; fi
        cnt=$(grep -c '|LESSON|' "$EVENTS_FILE" 2>/dev/null); cnt=${cnt:-0}
        if [[ "$cnt" -gt 0 ]]; then
            echo "lessons:"
            grep '|LESSON|' "$EVENTS_FILE" | while IFS='|' read -r _ _ id _ _ payload; do echo "- ${id}: ${payload} (autoridade: human)"; done
        else echo "lessons: []"; fi
        cnt=$(grep -c '|FAIL|' "$EVENTS_FILE" 2>/dev/null); cnt=${cnt:-0}
        if [[ "$cnt" -gt 0 ]]; then
            echo "failures:"
            grep '|FAIL|' "$EVENTS_FILE" | while IFS='|' read -r _ _ id _ _ payload; do
                local st="aberta"
                grep -q "|RESOLUTION|${id}|" "$EVENTS_FILE" 2>/dev/null && st="resolvida"
                echo "- ${id}: ${payload} | status=${st} (autoridade: runtime/test)"
            done
        else echo "failures: []"; fi
        echo "updated: $(ts)"
        echo "version: $(wc -l < "$EVENTS_FILE" 2>/dev/null || echo 0)"
    } > "$CTX_YML"
}

build_context_block() {
    if [[ -z "$PROJECT_DIR" ]]; then echo ""; return 0; fi
    local block=""
    block+="PROJETO: $(basename "$PROJECT_DIR")"$'\n'
    block+="ESTADO: $(cur_state)"$'\n'
    local obj
    obj=$(grep '|OBJECTIVE|' "$EVENTS_FILE" 2>/dev/null | tail -n1 | cut -d'|' -f6-)
    [[ -n "$obj" ]] && block+="OBJETIVO: ${obj} (human)"$'\n'
    while IFS='|' read -r _ _ id _ _ payload; do block+="REQUISITO ${id}: ${payload} (human)"$'\n'; done < <(grep '|REQUIREMENT|' "$EVENTS_FILE" 2>/dev/null)
    while IFS='|' read -r _ _ id _ _ payload; do block+="RESTRICAO ${id}: ${payload} (human)"$'\n'; done < <(grep '|RESTRICT|' "$EVENTS_FILE" 2>/dev/null)
    while IFS='|' read -r _ _ id _ _ payload; do block+="DECISAO ${id}: ${payload} (human)"$'\n'; done < <(grep '|DECISION|' "$EVENTS_FILE" 2>/dev/null | tail -n5)
    while IFS='|' read -r _ _ id _ _ payload; do
        local st="aberta"; grep -q "|RESOLUTION|${id}|" "$EVENTS_FILE" 2>/dev/null && st="resolvida"
        block+="FALHA ${id} (${st}): ${payload} (runtime/test)"$'\n'
    done < <(grep '|FAIL|' "$EVENTS_FILE" 2>/dev/null | tail -n3)
    while IFS='|' read -r _ _ id _ _ payload; do block+="LICAO ${id}: ${payload} (human)"$'\n'; done < <(grep '|LESSON|' "$EVENTS_FILE" 2>/dev/null | tail -n3)
    if [[ ${#block} -gt $CONTEXT_BUDGET ]]; then
        block="${block:0:$CONTEXT_BUDGET}"$'\n'"[contexto truncado em ${CONTEXT_BUDGET} chars]"
    fi
    echo "$block"
}

# ─────────────────────────────────────────────────────────────
# PROTOCOLO QWEN_PROTOCOL v1 (parser tolerante + canal duplo)
# ─────────────────────────────────────────────────────────────
PROTO_STATUS=""; PROTO_INTENT=""; PROTO_DECISION="NONE"; PROTO_LESSON="NONE"; PROTO_VALIDATION="NONE"; PROTO_CODE="NONE"; PROTO_OK=0

proto_field() { local block="$1" key="$2"; echo "$block" | grep -E "^[[:space:]]*${key}:" | head -n1 | cut -d':' -f2- | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/\r$//'; }

parse_protocol() {
    local reply="$1" block
    PROTO_OK=0; PROTO_STATUS=""; PROTO_INTENT=""; PROTO_DECISION="NONE"; PROTO_LESSON="NONE"; PROTO_VALIDATION="NONE"; PROTO_CODE="NONE"
    block=$(echo "$reply" | sed -n '/<QWEN_PROTOCOL>/,/<\/QWEN_PROTOCOL>/p')
    [[ -z "$block" ]] && return 1
    PROTO_STATUS=$(proto_field "$block" STATUS)
    PROTO_INTENT=$(proto_field "$block" INTENT)
    PROTO_DECISION=$(proto_field "$block" DECISION); [[ -z "$PROTO_DECISION" ]] && PROTO_DECISION="NONE"
    PROTO_LESSON=$(proto_field "$block" LESSON); [[ -z "$PROTO_LESSON" ]] && PROTO_LESSON="NONE"
    PROTO_VALIDATION=$(proto_field "$block" VALIDATION); [[ -z "$PROTO_VALIDATION" ]] && PROTO_VALIDATION="NONE"
    PROTO_CODE=$(proto_field "$block" CODE); [[ -z "$PROTO_CODE" ]] && PROTO_CODE="NONE"
    case "$PROTO_STATUS" in
        PLANNED|AWAITING_APPROVAL|BLOCKED|ANSWERING) PROTO_OK=1; return 0 ;;
        *) PROTO_STATUS=""; return 2 ;;
    esac
}

fallback_infer() {
    local reply="$1"
    if echo "$reply" | grep -q "AGUARDAR CONFIRMA"; then PROTO_STATUS="AWAITING_APPROVAL"; PROTO_OK=1; fi
    if echo "$reply" | grep -q "<bash_script>"; then PROTO_CODE="PRESENT"; fi
    [[ -z "$PROTO_INTENT" ]] && PROTO_INTENT="ANSWER"
}

repair_protocol() {
    local reply content
    reply=$(curl -s --max-time 300 http://localhost:11434/api/chat -H "Content-Type: application/json" \
        -d "$(jq -n --arg model "$MODEL" --arg sys "$SYSTEM_MESSAGE" \
        '{model: $model, messages: [{"role": "system", "content": $sys}, {"role": "user", "content": "Reemita SOMENTE o bloco <QWEN_PROTOCOL> valido da sua ultima resposta, sem nenhum texto adicional."}], stream: false}')" 2>/dev/null) || return 1
    content=$(echo "$reply" | jq -r '.message.content // ""')
    parse_protocol "$content"
}

# v6.4: propostas processadas a partir dos globals JA parseados (sem re-parse)
process_proposals() {
    local ans
    if [[ "$PROTO_DECISION" != "NONE" && -n "$PROTO_DECISION" ]]; then
        echo -e "\n${YELLOW}📌 PROPOSTA DE DECISÃO (llm):${NC} ${PROTO_DECISION}"
        if [[ -n "$PROJECT_DIR" ]]; then
            read -rp "Registrar como decisão confirmada? (y/N): " ans
            [[ "${ans,,}" == "y" ]] && append_event DECISION "$(next_id DECISION DEC)" human "-" "${PROTO_DECISION} (proposta: llm)"
        fi
    fi
    if [[ "$PROTO_LESSON" != "NONE" && -n "$PROTO_LESSON" ]]; then
        echo -e "\n${YELLOW}📌 PROPOSTA DE LIÇÃO (llm):${NC} ${PROTO_LESSON}"
        if [[ -n "$PROJECT_DIR" ]]; then
            read -rp "Registrar como lição confirmada? (y/N): " ans
            [[ "${ans,,}" == "y" ]] && append_event LESSON "$(next_id LESSON LES)" human "-" "${PROTO_LESSON} (proposta: llm)"
        fi
    fi
}

# ─────────────────────────────────────────────────────────────
# FAIL FIRST: infraestrutura
# ─────────────────────────────────────────────────────────────
CONTAINER_STATUS=$(docker inspect -f '{{.State.Running}}' ollama-service 2>/dev/null)
if [[ "$CONTAINER_STATUS" != "true" ]]; then
    echo -e "${RED}[ERRO]${NC} Container 'ollama-service' não está rodando." >&2
    echo -e "${YELLOW}[DICA]${NC} Execute: cd ${WORKSPACE} && ./setup_ia.sh --model ${MODEL}" >&2
    exit 1
fi

if ! docker exec ollama-service ollama list 2>/dev/null | grep -q "^${MODEL}"; then
    echo -e "${RED}[ERRO]${NC} Modelo '${MODEL}' não encontrado." >&2; exit 1
fi

echo -e "${BLUE}────────────────────────────────────────────────────────${NC}"
echo -e "${CYAN}🛡️  Consultando Gatekeeper...${NC}"
MODEL_IN_RAM=$(curl -s http://localhost:11434/api/ps 2>/dev/null | jq -r '.models[].name' 2>/dev/null | grep -c "$MODEL" || true)
if [[ "$MODEL_IN_RAM" -gt 0 ]]; then
    echo -e "${GREEN}✅ [BYPASS] Modelo já está na RAM.${NC}"
else
    if [[ -f "$WORKSPACE/ia_gatekeeper.sh" ]]; then
        if ! bash "$WORKSPACE/ia_gatekeeper.sh" authorize "$MODEL"; then
            echo -e "${RED}❌ [GATEKEEPER] Acesso negado!${NC}"; exit 1
        fi
    else
        RAM_AVAILABLE=$(free -g | awk '/^Mem:/{print $7}')
        if [[ "$RAM_AVAILABLE" -lt 16 ]]; then echo -e "${RED}[ERRO]${NC} RAM insuficiente." >&2; exit 1; fi
        echo -e "${GREEN}✅ Fallback OK: RAM disponível${NC}"
    fi
fi
echo -e "${BLUE}────────────────────────────────────────────────────────${NC}"

if [[ ! -f "$PROMPT_FILE" ]]; then echo -e "${RED}[ERRO]${NC} System Prompt não encontrado: ${PROMPT_FILE}" >&2; exit 1; fi
SYSTEM_PROMPT=$(cat "$PROMPT_FILE")
if [[ -z "$SYSTEM_PROMPT" ]]; then echo -e "${RED}[ERRO]${NC} System Prompt vazio.${NC}" >&2; exit 1; fi

mkdir -p "$DATA_DIR"
discover_project || true
[[ -f "$HISTORY_FILE" ]] || echo '[]' > "$HISTORY_FILE"

CTX_BLOCK=$(build_context_block)
if [[ -n "$CTX_BLOCK" ]]; then
    SYSTEM_MESSAGE="${SYSTEM_PROMPT}"$'\n\n'"=== CONTEXTO OPERACIONAL DO PROJETO ==="$'\n'"${CTX_BLOCK}"
else
    SYSTEM_MESSAGE="$SYSTEM_PROMPT"
fi

echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}${BOLD}  🤖 Qwen Dev Pro CLI v6.4 (Orchestrator + Protocolo)${NC}"
echo -e "${BLUE}  Modelo:         ${GREEN}${MODEL}${NC}"
echo -e "${BLUE}  System Prompt:  ${GREEN}$(basename "$PROMPT_FILE")${NC}"
if [[ -n "$PROJECT_DIR" ]]; then
    echo -e "${BLUE}  Projeto:        ${GREEN}$(basename "$PROJECT_DIR")${NC} [$(cur_state)]"
    echo -e "${BLUE}  História:       ${GREEN}por projeto${NC}"
else
    echo -e "${BLUE}  Projeto:        ${YELLOW}nenhum (histórico global)${NC}"
fi
echo -e "${BLUE}  Comandos: 'reset' | 'status' | 'debug' | 'aprovar' | 'diag'${NC}"
echo -e "${BLUE}            'projeto [init|usar|listar|status]'${NC}"
echo -e "${BLUE}            'ctx [view|approve|replan|decision|lesson|restrict|requirement|resolve|evidence]' | 'exit'${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo ""

diagnose_error() {
    local script_content="$1" error_output="$2" attempt="$3"
    echo -e "\n${YELLOW}🔍 DIAGNOSTICANDO ERRO (${attempt}/${MAX_RETRY})...${NC}"
    local diag_prompt="O script bash falhou. ERRO: ${error_output}. SCRIPT: ${script_content}. Gere um NOVO <bash_script> corrigido. Caminhos absolutos em ${WORKSPACE}/. NUNCA use rm -rf, sudo ou comandos destrutivos. Inclua o bloco <QWEN_PROTOCOL> no inicio com INTENT: ANALYZE_FAILURE e, se houver licao generalizavel, campo LESSON."
    local response curl_exit_code=0
    response=$(curl -s --max-time "$API_TIMEOUT" http://localhost:11434/api/chat -H "Content-Type: application/json" \
        -d "$(jq -n --arg model "$MODEL" --arg sys "$SYSTEM_MESSAGE" --arg content "$diag_prompt" \
        '{model: $model, messages: [{"role": "system", "content": $sys}, {"role": "user", "content": $content}], stream: false}')" 2>/dev/null) || curl_exit_code=$?
    if [[ $curl_exit_code -ne 0 ]]; then echo -e "${RED}[ERRO]${NC} Falha no diagnóstico (${curl_exit_code})." >&2; return 1; fi
    local fixed_script
    fixed_script=$(echo "$response" | jq -r '.message.content // ""')
    if echo "$fixed_script" | grep -q "<bash_script>"; then
        fixed_script=$(echo "$fixed_script" | sed -n '/<bash_script>/,/<\/bash_script>/p' | sed '1d;$d' | tr -d '\r' | sed 's/^```bash$//;s/^```$//')
        echo "$fixed_script" > "$TEMP_SCRIPT"; chmod +x "$TEMP_SCRIPT"
        echo -e "${GREEN}✅ Script corrigido gerado.${NC}"
        if [[ -n "$PROJECT_DIR" ]]; then
            local last_fail
            last_fail=$(grep '|FAIL|' "$EVENTS_FILE" 2>/dev/null | tail -n1 | cut -d'|' -f3)
            [[ -n "$last_fail" ]] && append_event FAIL_ANALYSIS "$(next_id FAIL_ANALYSIS FA)" llm "$last_fail" "correcao gerada em TEMP_SCRIPT"
        fi
        parse_protocol "$fixed_script" || true
        process_proposals
        return 0
    fi
    echo -e "${RED}[ERRO]${NC} Modelo não retornou <bash_script> válido.${NC}"
    return 1
}

do_approve() {
    if [[ -z "$PROJECT_DIR" ]]; then echo -e "${YELLOW}Nenhum projeto ativo.${NC}"; return 1; fi
    local cur; cur=$(cur_state)
    if [[ "$cur" != "PLANNED" ]]; then
        echo -e "${YELLOW}Estado ${cur} não permite aprovação (esperado PLANNED).${NC}"; return 1
    fi
    set_state AUTHORIZED human
    APPROVED_CHECKS=""
    if [[ "$LAST_PROTO_VALIDATION" != "NONE" && -n "$LAST_PROTO_VALIDATION" ]]; then APPROVED_CHECKS="$LAST_PROTO_VALIDATION"; fi
    echo "$APPROVED_CHECKS" > "$CHECKS_FILE"
    if [[ -n "$APPROVED_CHECKS" ]]; then
        echo -e "${CYAN}Checks aprovados (serão executados após a implementação):${NC} ${APPROVED_CHECKS}"
    else
        echo -e "${CYAN}Nenhum check adicional aprovado (apenas bash -n obrigatório).${NC}"
    fi
}

# v6.4: publica a saida em LAST_EXEC_OUTPUT (exibida + gravada + diagnosticada)
execute_implementation() {
    local cur start_ts dur exec_output exit_code checks_fail=0 exec_id bn chk chk_trim ce old_ifs
    if [[ -n "$PROJECT_DIR" ]]; then
        cur=$(cur_state)
        [[ "$cur" == "AUTHORIZED" ]] && set_state RUNNING human
    fi
    start_ts=$(date +%s)
    exec_output=$(bash "$TEMP_SCRIPT" 2>&1)
    exit_code=$?
    dur=$(( $(date +%s) - start_ts ))
    LAST_EXEC_OUTPUT="$exec_output"
    echo "$exec_output"
    if [[ -n "$PROJECT_DIR" ]]; then
        exec_id=$(next_id EXEC EXC)
        append_event EXEC "$exec_id" runtime "-" "cmd=bash ${TEMP_SCRIPT} exit=${exit_code} dur=${dur}s"
        cur=$(cur_state); [[ "$cur" == "RUNNING" ]] && set_state TESTING cli
        bash -n "$TEMP_SCRIPT" >/dev/null 2>&1; bn=$?
        append_event CHECK "$(next_id CHECK CHK)" test "$exec_id" "cmd=bash -n exit=${bn}"
        [[ $bn -ne 0 ]] && checks_fail=1
        if [[ -n "$APPROVED_CHECKS" ]]; then
            old_ifs="$IFS"; IFS=';'
            for chk in $APPROVED_CHECKS; do
                IFS="$old_ifs"
                chk_trim=$(echo "$chk" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
                [[ -z "$chk_trim" ]] && continue
                ( cd "$PROJECT_DIR" 2>/dev/null && timeout "$CHECK_TIMEOUT" bash -c "$chk_trim" ) >/dev/null 2>&1; ce=$?
                append_event CHECK "$(next_id CHECK CHK)" test "$exec_id" "cmd=${chk_trim} exit=${ce}"
                [[ $ce -ne 0 ]] && checks_fail=1
            done
            IFS="$old_ifs"
        fi
        cur=$(cur_state)
        if [[ "$cur" == "TESTING" ]]; then
            if [[ $exit_code -ne 0 || $checks_fail -ne 0 ]]; then
                set_state FAILED test
                append_event FAIL "$(next_id FAIL FAIL)" runtime "$exec_id" "exec_exit=${exit_code} checks_fail=${checks_fail}"
            else
                set_state VALIDATED test
            fi
        fi
    fi
    return $exit_code
}

show_status() {
    echo -e "\n${CYAN}📊 Status:${NC}"
    echo -e "  Container:   $(docker inspect -f '{{.State.Status}}' ollama-service 2>/dev/null || echo 'n/d')"
    echo -e "  RAM Livre:   $(free -g | awk '/^Mem:/{print $7}')GB / $(free -g | awk '/^Mem:/{print $2}')GB"
    echo -e "  Histórico:   $(jq 'length' "$HISTORY_FILE" 2>/dev/null || echo 0) msgs ($(basename "$HISTORY_FILE"))"
    echo -e "  Modelo:      ${MODEL}"
    if [[ -n "$PROJECT_DIR" ]]; then
        echo -e "  Projeto:     $(basename "$PROJECT_DIR") [$(cur_state)]"
        echo -e "  Contexto:    ${#CTX_BLOCK} chars | Checks aprovados: ${APPROVED_CHECKS:-nenhum}"
    else
        echo -e "  Projeto:     nenhum"
    fi
    local loaded
    loaded=$(curl -s http://localhost:11434/api/ps 2>/dev/null | jq -r '.models[0].name // "nenhum"' 2>/dev/null)
    echo -e "  Na RAM:      ${loaded}"
    echo ""
}

debug_payload() {
    local test_prompt="$1" payload first_role
    echo -e "\n${CYAN}🔍 DEBUG: payload enviado ao Ollama${NC}"
    echo -e "${GREEN}✓${NC} System Prompt: ${#SYSTEM_PROMPT} chars | Contexto projeto: ${#CTX_BLOCK} chars"
    payload=$(jq -n --arg model "$MODEL" --arg sys "$SYSTEM_MESSAGE" \
        --argjson hist "$(jq ".[-${MAX_CONTEXT}:]" "$HISTORY_FILE")" --arg user "$test_prompt" \
        '{model: $model, messages: ([{"role": "system", "content": $sys}] + $hist + [{"role": "user", "content": $user}]), stream: false}')
    echo "$payload" > "$PAYLOAD_LOG"
    echo "$payload" | jq -r '.messages | to_entries[] | "  [\(.key)] role=\(.value.role) | \(.value.content | length) chars"'
    first_role=$(echo "$payload" | jq -r '.messages[0].role')
    [[ "$first_role" == "system" ]] && echo -e "${GREEN}✅ CANAL OK: system em [0]${NC}" || echo -e "${RED}❌ CANAL QUEBRADO${NC}"
    echo -e "${CYAN}📄 ${PAYLOAD_LOG}${NC}\n"
}

cmd_projeto() {
    local sub="${1:-status}"; shift 2>/dev/null || true
    case "$sub" in
        status)
            if [[ -n "$PROJECT_DIR" ]]; then echo -e "${CYAN}Projeto:${NC} $(basename "$PROJECT_DIR") [$(cur_state)]"; else echo -e "${YELLOW}Nenhum projeto ativo.${NC}"; fi ;;
        init)
            local nome="${1:-}"; shift 2>/dev/null || true
            [[ -z "$nome" ]] && { echo -e "${RED}Uso: projeto init <nome> [objetivo...]${NC}"; return 1; }
            nome=$(echo "$nome" | tr 'A-Z' 'a-z' | sed 's/ /-/g')
            local alvo="${WORKSPACE}/${nome}"
            [[ -d "${alvo}/.qwen" ]] && { echo -e "${RED}Projeto já existe.${NC}"; return 1; }
            mkdir -p "${alvo}/.qwen"; set_project_vars "$alvo"
            echo "PLANNED" > "$STATE_FILE"; touch "$EVENTS_FILE"
            append_event INIT "$(next_id INIT INI)" human "-" "projeto criado"
            [[ $# -gt 0 ]] && append_event OBJECTIVE "$(next_id OBJECTIVE OBJ)" human "-" "$*"
            render_context_view
            echo -e "${GREEN}✅ Projeto '${nome}' criado [PLANNED].${NC}" ;;
        usar)
            local alvo="${1:-}"
            [[ -z "$alvo" ]] && { echo -e "${RED}Uso: projeto usar <nome|caminho>${NC}"; return 1; }
            [[ ! -d "$alvo" ]] && alvo="${WORKSPACE}/${alvo}"
            if [[ -d "${alvo}/.qwen" ]]; then set_project_vars "$alvo"; echo -e "${GREEN}✅ Ativo: $(basename "$alvo") [$(cur_state)]${NC}"; else echo -e "${RED}❌ .qwen não encontrado.${NC}"; fi ;;
        listar)
            local d p
            for d in "${WORKSPACE}"/*/.qwen; do [[ -d "$d" ]] || continue; p="$(dirname "$d")"; echo "  • $(basename "$p") [$(cat "$d/state" 2>/dev/null || echo NONE)]"; done ;;
        *) echo -e "${RED}Subcomando desconhecido.${NC}" ;;
    esac
}

cmd_ctx() {
    local sub="${1:-view}"; shift 2>/dev/null || true
    [[ -z "$PROJECT_DIR" ]] && { echo -e "${YELLOW}Nenhum projeto ativo.${NC}"; return 1; }
    case "$sub" in
        view) render_context_view; cat "$CTX_YML" ;;
        approve) do_approve ;;
        replan) set_state PLANNED human ;;
        decision) append_event DECISION "$(next_id DECISION DEC)" human "-" "$*"; echo -e "${GREEN}✅ Decisão registrada.${NC}" ;;
        lesson) append_event LESSON "$(next_id LESSON LES)" human "-" "$*"; echo -e "${GREEN}✅ Lição registrada.${NC}" ;;
        restrict) append_event RESTRICT "$(next_id RESTRICT RST)" human "-" "$*"; echo -e "${GREEN}✅ Restrição registrada.${NC}" ;;
        requirement) append_event REQUIREMENT "$(next_id REQUIREMENT REQ)" human "-" "$*"; echo -e "${GREEN}✅ Requisito registrado.${NC}" ;;
        resolve)
            local fid="${1:-}"; shift 2>/dev/null || true
            [[ -z "$fid" ]] && { echo -e "${RED}Uso: ctx resolve <FAIL-id> [texto]${NC}"; return 1; }
            append_event RESOLUTION "$fid" human "-" "$*"; echo -e "${GREEN}✅ ${fid} resolvida.${NC}" ;;
        evidence) grep -E '\|(EXEC|CHECK)\|' "$EVENTS_FILE" 2>/dev/null | tail -n10 || echo "  (sem evidências)" ;;
        *) echo -e "${RED}Subcomando desconhecido.${NC}" ;;
    esac
}

# ─────────────────────────────────────────────────────────────
# LOOP PRINCIPAL
# ─────────────────────────────────────────────────────────────
while true; do
    TOTAL_MESSAGES=$(jq 'length' "$HISTORY_FILE" 2>/dev/null || echo "0")
    [[ "$TOTAL_MESSAGES" -gt 20 ]] && echo -e "${YELLOW}⚠️  Histórico grande (${TOTAL_MESSAGES}). Considere 'reset'.${NC}\n"

    echo -e "${GREEN}➜ Cole seu prompt abaixo.${NC}"
    echo -e "${YELLOW}   Digite FIM em uma linha separada para enviar${NC}"

    USER_PROMPT=""
    while IFS= read -r line; do
        clean_line=$(echo "$line" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ "$clean_line" == "FIM" ]] && break
        USER_PROMPT+="$clean_line"$'\n'
    done
    USER_PROMPT="${USER_PROMPT%$'\n'}"

    if [[ "${USER_PROMPT,,}" == "exit" || "${USER_PROMPT,,}" == "sair" ]]; then
        echo -e "\n${CYAN}Saindo. Memórias preservadas.${NC}"; break
    elif [[ "${USER_PROMPT,,}" == "reset" || "${USER_PROMPT,,}" == "limpar" ]]; then
        echo '[]' > "$HISTORY_FILE"; echo -e "${YELLOW}🧹 Conversa limpa (contexto/eventos intactos).${NC}"; continue
    elif [[ "${USER_PROMPT,,}" == "status" ]]; then show_status; continue
    elif [[ "${USER_PROMPT,,}" == "debug" || "${USER_PROMPT,,}" == "payload" ]]; then
        echo -e "${CYAN}Prompt de teste (FIM encerra):${NC}"
        TEST_PROMPT=""
        while IFS= read -r line; do
            clean_line=$(echo "$line" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [[ "$clean_line" == "FIM" ]] && break
            TEST_PROMPT+="$clean_line"$'\n'
        done
        TEST_PROMPT="${TEST_PROMPT%$'\n'}"
        [[ -n "$TEST_PROMPT" ]] && debug_payload "$TEST_PROMPT" || echo -e "${YELLOW}Vazio.${NC}"
        continue
    elif [[ "${USER_PROMPT,,}" == projeto* ]]; then read -ra _args <<< "${USER_PROMPT#*[pP]rojeto }"; cmd_projeto "${_args[@]}"; continue
    elif [[ "${USER_PROMPT,,}" == ctx* ]]; then read -ra _args <<< "${USER_PROMPT#*[cC]tx }"; cmd_ctx "${_args[@]}"; continue
    elif [[ "${USER_PROMPT,,}" == "diag" || "${USER_PROMPT,,}" == "diagnostico" ]]; then
        if [[ -f "$ERROR_LOG" ]]; then
            cat "$ERROR_LOG"
            read -rp "Analisar com o modelo? (y/N): " run_diag
            [[ "${run_diag,,}" == "y" ]] && diagnose_error "$(cat "$TEMP_SCRIPT" 2>/dev/null || echo 'n/d')" "$(cat "$ERROR_LOG")" "manual"
        else echo -e "${YELLOW}Nenhum erro recente.${NC}"; fi
        continue
    elif [[ "${USER_PROMPT,,}" == "aprovar" || "${USER_PROMPT,,}" == "aprovado" || "${USER_PROMPT,,}" == "confirmar" ]]; then
        do_approve
        USER_PROMPT="APROVADO. Prossiga com a implementação conforme o plano confirmado."
    elif [[ -z "$USER_PROMPT" ]]; then continue
    fi

    PROMPT_LENGTH=${#USER_PROMPT}
    if [[ $PROMPT_LENGTH -gt $MAX_PROMPT_CHARS ]]; then
        echo -e "${YELLOW}⚠️ Prompt longo (${PROMPT_LENGTH} chars).${NC}"
        read -rp "Continuar? (y/N): " cont
        [[ "${cont,,}" != "y" ]] && continue
    fi

    CTX_BLOCK=$(build_context_block)
    if [[ -n "$CTX_BLOCK" ]]; then
        SYSTEM_MESSAGE="${SYSTEM_PROMPT}"$'\n\n'"=== CONTEXTO OPERACIONAL DO PROJETO ==="$'\n'"${CTX_BLOCK}"
    else
        SYSTEM_MESSAGE="$SYSTEM_PROMPT"
    fi

    echo -e "\n${YELLOW}⏳ Processando (até $((API_TIMEOUT / 60)) min)...${NC}\n"

    jq --arg role "user" --arg content "$USER_PROMPT" '. + [{"role": $role, "content": $content}]' "$HISTORY_FILE" > /tmp/hist_tmp.json
    mv /tmp/hist_tmp.json "$HISTORY_FILE"

    CONTEXT_WITH_SYSTEM=$(jq --arg sys "$SYSTEM_MESSAGE" '[{"role": "system", "content": $sys}] + .' <<< "$(jq ".[-${MAX_CONTEXT}:]" "$HISTORY_FILE")")

    RESPONSE=""; curl_exit_code=0
    RESPONSE=$(curl -s --max-time "$API_TIMEOUT" http://localhost:11434/api/chat -H "Content-Type: application/json" \
        -d "$(jq -n --arg model "$MODEL" --argjson messages "$CONTEXT_WITH_SYSTEM" '{model: $model, messages: $messages, stream: false}')" 2>/dev/null) || curl_exit_code=$?

    if [[ $curl_exit_code -ne 0 ]]; then
        if [[ $curl_exit_code -eq 28 ]]; then
            echo -e "${RED}[ERRO]${NC} Timeout.${NC}" >&2
            jq 'del(.[-1])' "$HISTORY_FILE" > /tmp/hist_tmp.json; mv /tmp/hist_tmp.json "$HISTORY_FILE"
        elif [[ $curl_exit_code -eq 7 ]]; then echo -e "${RED}[ERRO]${NC} Conexão recusada.${NC}" >&2
        else echo -e "${RED}[ERRO]${NC} Falha curl (${curl_exit_code}).${NC}" >&2; fi
        continue
    fi

    if echo "$RESPONSE" | jq -e '.error' >/dev/null 2>&1; then
        echo -e "${RED}[ERRO]${NC} API: $(echo "$RESPONSE" | jq -r '.error')" >&2
        jq 'del(.[-1])' "$HISTORY_FILE" > /tmp/hist_tmp.json; mv /tmp/hist_tmp.json "$HISTORY_FILE"
        continue
    fi

    ASSISTANT_REPLY=$(echo "$RESPONSE" | jq -r '.message.content // ""')
    if [[ -z "$ASSISTANT_REPLY" ]]; then
        echo -e "${RED}[ERRO]${NC} Resposta vazia.${NC}" >&2
        jq 'del(.[-1])' "$HISTORY_FILE" > /tmp/hist_tmp.json; mv /tmp/hist_tmp.json "$HISTORY_FILE"
        continue
    fi

    jq --arg role "assistant" --arg content "$ASSISTANT_REPLY" '. + [{"role": $role, "content": $content}]' "$HISTORY_FILE" > /tmp/hist_tmp.json
    mv /tmp/hist_tmp.json "$HISTORY_FILE"

    echo "$ASSISTANT_REPLY" | tr -d '\r'

    # ── Protocolo: parse → reparo (1x) → fallback + violação ──
    parse_rc=0
    parse_protocol "$ASSISTANT_REPLY" || parse_rc=$?
    if [[ $parse_rc -ne 0 ]]; then
        repair_protocol || true
        if [[ $PROTO_OK -ne 1 ]]; then
            fallback_infer "$ASSISTANT_REPLY"
            if [[ -n "$PROJECT_DIR" ]]; then
                append_event PROTOCOL_VIOLATION "$(next_id PROTOCOL_VIOLATION PV)" cli "-" "rc=${parse_rc} bloco ausente/invalido; fallback aplicado"
            fi
        fi
    fi
    LAST_PROTO_VALIDATION="$PROTO_VALIDATION"
    process_proposals

    if [[ "$PROTO_STATUS" == "AWAITING_APPROVAL" ]]; then
        echo -e "\n${YELLOW}═══════════════════════════════════════════════════════${NC}"
        echo -e "${YELLOW} ⏸️  PROTOCOLO: STATUS=AWAITING_APPROVAL${NC}"
        echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
        echo -e "${CYAN}   Digite 'aprovar' (PLANNED → AUTHORIZED; checks listados serão executados)${NC}"
        echo -e "${CYAN}   Ou envie ajustes ao plano antes de aprovar${NC}\n"
        continue
    fi

    if [[ "$PROTO_CODE" == "PRESENT" || $(echo "$ASSISTANT_REPLY" | grep -c "<bash_script>") -gt 0 ]]; then
        echo -e "\n${BLUE}═══════════════════════════════════════════════════════${NC}"
        echo -e "${YELLOW} ⚠️  SCRIPT DETECTADO (CODE=PRESENT)${NC}"
        echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"

        SCRIPT_CONTENT=$(echo "$ASSISTANT_REPLY" | sed -n '/<bash_script>/,/<\/bash_script>/p' | sed '1d;$d' | tr -d '\r' | sed 's/^```bash$//;s/^```$//')

        if echo "$SCRIPT_CONTENT" | grep -qE 'rm -rf|sudo|mkfs|dd |chmod 777|chown'; then
            echo -e "${RED}🚫 BLOQUEADO: comandos perigosos.${NC}"; continue
        fi

        echo "$SCRIPT_CONTENT" > "$TEMP_SCRIPT"; chmod +x "$TEMP_SCRIPT"
        cat "$TEMP_SCRIPT"

        read -rp $'\nAbrir no nano? (y/N): ' edit_confirm
        [[ "${edit_confirm,,}" == "y" ]] && { nano -l "$TEMP_SCRIPT"; SCRIPT_CONTENT=$(cat "$TEMP_SCRIPT"); }

        read -rp $'\n✅ Confirmar EXECUÇÃO? (y/N): ' exec_confirm
        if [[ "${exec_confirm,,}" == "y" ]]; then
            attempt=1; success=false
            while [[ $attempt -le $MAX_RETRY ]]; do
                echo -e "\n${CYAN}── Tentativa ${attempt}/${MAX_RETRY} ─${NC}"
                if execute_implementation; then
                    success=true; break
                else
                    echo "$LAST_EXEC_OUTPUT" > "$ERROR_LOG"
                    echo -e "${RED}⚠️ Falha na execução/validação (evidência em $ERROR_LOG).${NC}"
                    if [[ $attempt -lt $MAX_RETRY ]]; then
                        read -rp "Corrigir automaticamente? (y/N): " auto_fix
                        [[ "${auto_fix,,}" != "y" ]] && { echo -e "${YELLOW}⛔ Cancelado.${NC}"; break; }
                        if diagnose_error "$SCRIPT_CONTENT" "$LAST_EXEC_OUTPUT" "$attempt"; then
                            cat "$TEMP_SCRIPT"
                            read -rp $'\n✅ Executar versão corrigida? (y/N): ' retry_confirm
                            [[ "${retry_confirm,,}" != "y" ]] && break
                            if [[ -n "$PROJECT_DIR" && "$(cur_state)" == "FAILED" ]]; then
                                set_state PLANNED human; set_state AUTHORIZED human
                            fi
                            SCRIPT_CONTENT=$(cat "$TEMP_SCRIPT")
                        else break; fi
                    else
                        echo -e "${RED}❌ Limite de tentativas. Use 'ctx view' e 'diag'.${NC}"
                    fi
                fi
                ((attempt++))
            done
            [[ "$success" == "false" ]] && echo -e "\n${YELLOW}⛔ Falha. Script em $TEMP_SCRIPT${NC}"
        else
            echo -e "${YELLOW}⛔ Cancelado. Script em $TEMP_SCRIPT${NC}"
        fi
    fi

    echo -e "\n"
done
