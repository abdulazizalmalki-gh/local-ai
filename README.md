# Local AI

A self-hosted local LLM setup using llama.cpp and Open WebUI.

## Services

- **llama-qwen3-coder** - llama.cpp server running Qwen3-Coder-30B model with CUDA acceleration
- **open-webui** - Web interface for interacting with the LLM

## Requirements

- Docker and Docker Compose
- NVIDIA GPU with CUDA support
- Model file: `Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf` in `/opt/stacks/shared-ai-models/`

## Usage

Start the services:

```bash
docker compose up -d
```

Access Open WebUI at http://localhost:3000

Stop the services:

```bash
docker compose down
```

## Ports

| Service | Port |
|---------|------|
| llama.cpp API | 18080 |
| Open WebUI | 3000 |

## License

MIT
