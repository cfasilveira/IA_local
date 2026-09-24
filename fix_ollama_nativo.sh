#!/usr/bin/env bash
# =============================================================================
# fix_ollama_nativo.sh v1.0 - Elimina conflito entre Ollama nativo e Docker
# =============================================================================
# OBJETIVO: Garantir que APENAS o container ollama-service controle a porta 11434
# 
# USO: sudo ./fix_ollama_nativo.sh [--dry-run]
# =============================================================================
set -uo pipefail

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
BOLD='\033[1m'

BASE_DIR="/home/carlos/Projetos/AI"
LOG="${BASE_DIR}/fix_ollama_nativo_$(date +%Y%m%d_%H%M%S).log"
MARKER_FILE="${BASE_DIR}/.ollama_nativo_desabilitado"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

log()      { local msg; msg="[INFO] $(date '+%H:%M:%S') - $1"; echo -e "${CYAN}${msg}${NC}" | tee -a "$LOG"; }
warn()     { local msg; msg="[WARN] $(date '+%H:%M:%S') - $1"; echo -e "${YELLOW}${msg}${NC}" | tee -a "$LOG"; }
err()      { local msg; msg="[ERRO] $(date '+%H:%M:%S') - $1"; echo -e "${RED}${msg}${NC}" | tee -a "$LOG" >&2; }
success()  { local msg; msg="[OK] $(date '+%H:%M:%S') - $1"; echo -e "${GREEN}${msg}${NC}" | tee -a "$LOG"; }
step()     { echo -e "\n${BLUE}${BOLD}▶ $1${NC}" | tee -a "$LOG"; }

# Verificar se está rodando como root (necessário para systemctl)
if [[ $EUID -ne 0 ]]; then
    err "Este script precisa ser executado com sudo."
    err "Uso: sudo $0 [--dry-run]"
    exit 1
fi

# Ajustar BASE_DIR se estiver rodando como root
if [[ ! -d "$BASE_DIR" ]]; then
    err "Diretório ${BASE_DIR} não existe."
    exit 1
fi

mkdir -p "$BASE_DIR"

echo -e "${CYAN}${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}${BOLD}  🔧 FIX: Eliminar conflito Ollama Nativo vs Docker${NC}"
echo -e "${CYAN}${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo ""
[[ $DRY_RUN -eq 1 ]] && warn "MODO DRY-RUN: nenhuma alteração será aplicada"
echo ""

# ============================================================================
# ETAPA 1: Diagnóstico inicial
# ============================================================================
step "1/6 — Diagnóstico do estado atual"

NATIVO_ATIVO=0
NATIVO_INSTALADO=0
PORTA_OCUPADA=0
PROCESSOS_NATIVOS=0

# Verificar se o serviço systemd existe
if systemctl list-unit-files 2>/dev/null | grep -q "^ollama.service"; then
    NATIVO_INSTALADO=1
    log "Serviço systemd 'ollama.service' detectado"
    
    if systemctl is-active --quiet ollama 2>/dev/null; then
        NATIVO_ATIVO=1
        warn "Serviço systemd 'ollama.service' está ATIVO"
    else
        log "Serviço systemd 'ollama.service' está inativo"
    fi
    
    if systemctl is-enabled --quiet ollama 2>/dev/null; then
        warn "Serviço systemd 'ollama.service' está HABILITADO para iniciar no boot"
    fi
else
    log "Nenhum serviço systemd 'ollama.service' encontrado"
fi

# Verificar processos nativos
PROCESSOS_NATIVOS=$(pgrep -f "ollama serve" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$PROCESSOS_NATIVOS" -gt 0 ]]; then
    warn "Encontrados ${PROCESSOS_NATIVOS} processo(s) 'ollama serve' rodando"
    ps -eo pid,comm,cmd | grep -E "ollama" | grep -v grep | head -n5 | tee -a "$LOG" || true
else
    log "Nenhum processo 'ollama serve' rodando fora do Docker"
fi

# Verificar porta 11434
if ss -tlnp 2>/dev/null | grep -q ":11434"; then
    PORTA_OCUPADA=1
    local_port_info=$(ss -tlnp 2>/dev/null | grep ":11434" | head -1)
    log "Porta 11434 está ocupada:"
    echo "  $local_port_info" | tee -a "$LOG"
    
    # Identificar quem está na porta
    local_pid=$(echo "$local_port_info" | grep -oP 'pid=\K[0-9]+' | head -1)
    if [[ -n "$local_pid" ]]; then
        local_proc=$(ps -p "$local_pid" -o comm= 2>/dev/null || echo "desconhecido")
        log "Processo ocupando a porta: PID=$local_pid ($local_proc)"
    fi
else
    log "Porta 11434 está LIVRE"
fi

# Diagnóstico do container Docker
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^ollama-service$"; then
    log "Container 'ollama-service' está RODANDO"
elif docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^ollama-service$"; then
    warn "Container 'ollama-service' existe mas está PARADO"
else
    log "Container 'ollama-service' não existe"
fi

echo ""
log "Resumo: nativo_instalado=$NATIVO_INSTALADO nativo_ativo=$NATIVO_ATIVO porta_ocupada=$PORTA_OCUPADA processos=$PROCESSOS_NATIVOS"

# ============================================================================
# ETAPA 2: Parar serviço systemd (se ativo)
# ============================================================================
step "2/6 — Parando serviço systemd ollama.service"

if [[ $NATIVO_INSTALADO -eq 1 ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
        log "[DRY-RUN] Executaria: systemctl stop ollama"
        log "[DRY-RUN] Executaria: systemctl disable ollama"
    else
        if systemctl is-active --quiet ollama 2>/dev/null; then
            if systemctl stop ollama 2>/dev/null; then
                success "Serviço 'ollama.service' parado"
            else
                warn "Falha ao parar 'ollama.service' (pode já estar parado)"
            fi
        else
            log "Serviço já estava parado"
        fi
        
        if systemctl is-enabled --quiet ollama 2>/dev/null; then
            if systemctl disable ollama 2>/dev/null; then
                success "Serviço 'ollama.service' desabilitado do boot"
            else
                warn "Falha ao desabilitar 'ollama.service'"
            fi
        else
            log "Serviço já estava desabilitado"
        fi
    fi
else
    log "Nada a fazer (serviço não instalado)"
fi

# ============================================================================
# ETAPA 3: Matar processos órfãos
# ============================================================================
step "3/6 — Eliminando processos 'ollama serve' órfãos"

if [[ $PROCESSOS_NATIVOS -gt 0 ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
        log "[DRY-RUN] Executaria: pkill -9 -f 'ollama serve'"
        log "[DRY-RUN] Mataria $PROCESSOS_NATIVOS processo(s)"
    else
        # Tentar terminação graceful primeiro
        pkill -TERM -f "ollama serve" 2>/dev/null || true
        sleep 2
        
        # Verificar se ainda há processos
        local_remaining=$(pgrep -f "ollama serve" 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$local_remaining" -gt 0 ]]; then
            warn "Processos resistiram ao TERM, forçando KILL"
            pkill -9 -f "ollama serve" 2>/dev/null || true
            sleep 1
        fi
        
        # Verificação final
        local_final=$(pgrep -f "ollama serve" 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$local_final" -eq 0 ]]; then
            success "Todos os processos 'ollama serve' foram eliminados"
        else
            err "Ainda restam $local_final processo(s). Verifique manualmente:"
            pgrep -af "ollama" | tee -a "$LOG" || true
        fi
    fi
else
    log "Nenhum processo órfão para matar"
fi

# ============================================================================
# ETAPA 4: Aguardar liberação da porta
# ============================================================================
step "4/6 — Aguardando liberação da porta 11434"

if [[ $DRY_RUN -eq 1 ]]; then
    log "[DRY-RUN] Aguardaria até 10s pela liberação da porta"
else
    local_wait=0
    while ss -tlnp 2>/dev/null | grep -q ":11434"; do
        ((local_wait++))
        if [[ $local_wait -gt 10 ]]; then
            warn "Porta 11434 ainda ocupada após 10s"
            
            # Identificar quem está na porta
            local_blocker=$(ss -tlnp 2>/dev/null | grep ":11434" | head -1)
            err "Bloqueador: $local_blocker"
            err "Investigue manualmente com: sudo lsof -i :11434"
            break
        fi
        sleep 1
    done
    
    if ! ss -tlnp 2>/dev/null | grep -q ":11434"; then
        success "Porta 11434 liberada"
    fi
fi

# ============================================================================
# ETAPA 5: Criar marcador de proteção
# ============================================================================
step "5/6 — Criando marcador de proteção"

if [[ $DRY_RUN -eq 1 ]]; then
    log "[DRY-RUN] Criaria marcador em $MARKER_FILE"
else
    cat > "$MARKER_FILE" << MARKER_EOF
# Marcador de proteção criado por fix_ollama_nativo.sh
# Data: $(date '+%Y-%m-%d %H:%M:%S')
# Motivo: Ollama nativo desabilitado para evitar conflito com container Docker
# 
# Se você reinstalar o Ollama nativo acidentalmente, remova este arquivo
# E execute o fix novamente:
#   sudo rm $MARKER_FILE
#   sudo ./fix_ollama_nativo.sh
MARKER_EOF
    chown carlos:carlos "$MARKER_FILE" 2>/dev/null || true
    success "Marcador criado em $MARKER_FILE"
fi

# ============================================================================
# ETAPA 6: Validação final
# ============================================================================
step "6/6 — Validação final do estado"

# Estado do systemd
if systemctl is-active --quiet ollama 2>/dev/null; then
    err "❌ Serviço systemd ainda está ATIVO"
else
    success "✓ Serviço systemd está inativo"
fi

# Estado dos processos
if pgrep -f "ollama serve" >/dev/null 2>&1; then
    err "❌ Ainda há processos 'ollama serve' rodando"
    pgrep -af "ollama serve" | tee -a "$LOG" || true
else
    success "✓ Nenhum processo 'ollama serve' órfão"
fi

# Estado da porta
if ss -tlnp 2>/dev/null | grep -q ":11434"; then
    err "❌ Porta 11434 ainda ocupada"
else
    success "✓ Porta 11434 livre"
fi

# Estado do container
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^ollama-service$"; then
    success "✓ Container 'ollama-service' rodando"
elif docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^ollama-service$"; then
    log "ℹ Container 'ollama-service' existe mas está parado"
    log "  Execute: cd $BASE_DIR && ./setup_ia.sh"
else
    log "ℹ Container 'ollama-service' ainda não foi criado"
    log "  Execute: cd $BASE_DIR && ./setup_ia.sh"
fi

# ============================================================================
# RELATÓRIO FINAL
# ============================================================================
echo ""
echo -e "${GREEN}${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  ✅ FIX CONCLUÍDO${NC}"
echo -e "${GREEN}${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${CYAN}Log completo:${NC} $LOG"
echo -e "${CYAN}Marcador:${NC}    $MARKER_FILE"
echo ""
echo -e "${YELLOW}Próximos passos:${NC}"
echo "  1. Teste o ambiente:  cd $BASE_DIR && ./setup_ia.sh"
echo "  2. Verifique o status: ./status_ia.sh"
echo "  3. Se tudo funcionar, prossiga para o Passo 2 (Gatekeeper)"
echo ""
echo -e "${YELLOW}Em caso de problema:${NC}"
echo "  - Verifique o log: cat $LOG"
echo "  - Reative o serviço:  sudo systemctl enable --now ollama"
echo "  - Reporte o erro com o log completo"
echo ""

exit 0
