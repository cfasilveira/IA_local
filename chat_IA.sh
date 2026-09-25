#!/bin/bash
# Fonte unica de modelos quando lib_ia.sh existe (fallback hardcoded abaixo)
BASE_DIR="${BASE_DIR:-/home/carlos/Projetos/AI}"
[[ -f "${BASE_DIR}/lib_ia.sh" ]] && source "${BASE_DIR}/lib_ia.sh" 2>/dev/null || true
if declare -f ia_model_tag >/dev/null 2>&1; then
    M_OTIM="$(ia_model_tag mistral-otimizado)"; M_OTIM="${M_OTIM:-mistral-nemo-otimizado:latest}"
    M_BASE="$(ia_model_tag mistral-base)";       M_BASE="${M_BASE:-mistral-nemo:latest}"
    M_QWENC="$(ia_model_tag qwen-coder)";        M_QWENC="${M_QWENC:-qwen2.5-coder:14b-instruct-q8_0}"
    M_QWENB="$(ia_model_tag qwen-base)";         M_QWENB="${M_QWENB:-qwen-dev-pro:latest}"
else
    M_OTIM="mistral-nemo-otimizado:latest"; M_BASE="mistral-nemo:latest"
    M_QWENC="qwen2.5-coder:14b-instruct-q8_0"; M_QWENB="qwen-dev-pro:latest"
fi

echo "--- Seletor de IA Local (Docker) ---"
echo "1) Mistral Nemo Otimizado ⭐ CRIADO A PARTIR DO BASE"
echo "2) Mistral Nemo Base 📦 MODELO BASE"
echo "3) Qwen Coder 14B 🔧 MODELO COMPLEMENTAR"
echo "4) Qwen Dev Pro Base 📦 MODELO BASE"
echo "5) Sair"
read -p "Escolha: " OPT

case $OPT in
    1) MODEL="$M_OTIM" ;;
    2) MODEL="$M_BASE" ;;
    3) MODEL="$M_QWENC" ;;
    4) MODEL="$M_QWENB" ;;
    5) exit ;;
    *) echo "Opção inválida."; exit ;;
esac

echo -e "\nEntrando no modo chat com $MODEL..."
echo "Dica: Digite /exit para sair do chat da IA."
echo "------------------------------------------"

docker exec -it ollama-service ollama run "$MODEL"
