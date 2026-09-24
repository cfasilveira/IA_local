#!/bin/bash
# Sempre roda a partir do diretório da API para imports absolutos funcionarem
cd "$(dirname "$0")"
source venv/bin/activate
uvicorn main:app --reload
