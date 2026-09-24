#!/usr/bin/env bash
# =============================================================================
# backup_scripts.sh v1.2 - Backup Automatizado de Scripts com Prefixo 'bkp_'
# Uso: ./backup_scripts.sh
# =============================================================================
set -uo pipefail

# Cores (TODAS declaradas corretamente)
GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
BOLD='\033[1m'

# Diretório base do projeto
BASE_DIR="/home/carlos/Projetos/AI"
DEST_BASE="/home/carlos/Projetos/AI/backup_sanitizacao"

# Gera carimbo de data/hora para nomear a pasta de destino
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
DEST_DIR="${DEST_BASE}_${TIMESTAMP}"

# Fail First: Verifica se o diretório base existe
if [[ ! -d "$BASE_DIR" ]]; then
    echo -e "${RED}[ERRO]${NC} Diretório base ${BASE_DIR} não existe. Backup abortado."
    exit 1
fi

# Cria o diretório de destino
mkdir -p "$DEST_DIR"
if [[ $? -ne 0 ]]; then
    echo -e "${RED}[ERRO]${NC} Falha ao criar diretório de destino: ${DEST_DIR}"
    exit 1
fi

echo -e "${CYAN}${BOLD}📦 INICIANDO BACKUP DE SCRIPTS${NC}"
echo -e "${CYAN}   Origem: ${BASE_DIR}${NC}"
echo -e "${CYAN}   Destino: ${DEST_DIR}${NC}"
echo ""

# Arquivo de log do backup
LOG_FILE="${DEST_DIR}/backup_log.txt"
echo "Backup realizado em: $(date '+%Y-%m-%d %H:%M:%S')" > "$LOG_FILE"
echo "Origem: ${BASE_DIR}" >> "$LOG_FILE"
echo "Destino: ${DEST_DIR}" >> "$LOG_FILE"
echo "----------------------------------------" >> "$LOG_FILE"

# Contador de arquivos copiados
TOTAL_COPIED=0
TOTAL_FAILED=0

# Loop para processar todos os arquivos .sh no diretório base
while IFS= read -r -d '' SCRIPT_FILE; do
    SCRIPT_NAME=$(basename "$SCRIPT_FILE")
    DEST_FILE="${DEST_DIR}/bkp_${SCRIPT_NAME}"
    
    # Fail First: Verifica se o arquivo de origem existe e é legível
    if [[ ! -f "$SCRIPT_FILE" || ! -r "$SCRIPT_FILE" ]]; then
        echo -e "${RED}[ERRO]${NC} Arquivo não encontrado ou ilegível: ${SCRIPT_NAME}"
        echo "FALHA | ${SCRIPT_NAME} | Não encontrado ou ilegível" >> "$LOG_FILE"
        ((TOTAL_FAILED++))
        continue
    fi

    # Copia o arquivo com o prefixo 'bkp_'
    if cp "$SCRIPT_FILE" "$DEST_FILE"; then
        echo -e "${GREEN}[OK]${NC} Copiado: ${CYAN}${SCRIPT_NAME}${NC} → ${GREEN}${DEST_FILE}${NC}"
        echo "OK | ${SCRIPT_NAME} | Copiado para ${DEST_FILE}" >> "$LOG_FILE"
        ((TOTAL_COPIED++))
    else
        echo -e "${RED}[ERRO]${NC} Falha ao copiar: ${SCRIPT_NAME}"
        echo "FALHA | ${SCRIPT_NAME} | Falha ao copiar" >> "$LOG_FILE"
        ((TOTAL_FAILED++))
    fi
done < <(find "$BASE_DIR" -maxdepth 1 -name "*.sh" -print0 | sort -z)

echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}${BOLD}📊 RESUMO DO BACKUP${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✅ Scripts copiados: ${TOTAL_COPIED}${NC}"
echo -e "${RED}❌ Falhas: ${TOTAL_FAILED}${NC}"
echo -e "${YELLOW}📂 Pasta de backup: ${DEST_DIR}${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"

# Verifica se houve falhas
if [[ $TOTAL_FAILED -gt 0 ]]; then
    echo -e "\n${YELLOW}⚠️  Alguns arquivos falharam. Verifique o log em: ${LOG_FILE}${NC}"
    exit 1
else
    echo -e "\n${GREEN}🟢 Backup concluído com sucesso!${NC}"
    exit 0
fi
