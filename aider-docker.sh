#!/bin/bash
# aider-docker.sh - Aider com Qwen Coder 14B

if ! curl -s http://localhost:11434/api/tags > /dev/null; then
    echo "❌ Ollama offline. Execute ./setup_ia.sh primeiro."
    exit 1
fi

echo "🚀 Iniciando Aider com Qwen Coder 14B (modelo complementar)..."
echo "   Base: qwen-dev-pro:latest"

docker run -it --rm \
  --name aider-instance \
  --network host \
  -v $(pwd):/app \
  -e OLLAMA_API_BASE=http://localhost:11434 \
  paulgauthier/aider \
  --model ollama/qwen2.5-coder:14b-instruct-q8_0 \
  --watch-files \
  --edit-format diff
