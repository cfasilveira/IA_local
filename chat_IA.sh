#!/bin/bash

echo "--- Seletor de IA Local (Docker) ---"
echo "1) Mistral Nemo Otimizado ⭐ CRIADO A PARTIR DO BASE"
echo "2) Mistral Nemo Base 📦 MODELO BASE"
echo "3) Qwen Coder 14B 🔧 MODELO COMPLEMENTAR"
echo "4) Qwen Dev Pro Base 📦 MODELO BASE"
echo "5) Sair"
read -p "Escolha: " OPT

case $OPT in
    1) MODEL="mistral-nemo-otimizado:latest" ;;
    2) MODEL="mistral-nemo:latest" ;;
    3) MODEL="qwen2.5-coder:14b-instruct-q8_0" ;;
    4) MODEL="qwen-dev-pro:latest" ;;
    5) exit ;;
    *) echo "Opção inválida."; exit ;;
esac

echo -e "\nEntrando no modo chat com $MODEL..."
echo "Dica: Digite /exit para sair do chat da IA."
echo "------------------------------------------"

docker exec -it ollama-service ollama run "$MODEL"
