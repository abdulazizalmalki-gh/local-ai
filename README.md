# Local AI

A self-hosted local LLM setup using llama.cpp and Open WebUI.

## Services

- **llama-qwen3-coder** - llama.cpp server running Qwen3-Coder-30B model
- **open-webui** - Web interface for interacting with the LLM

## Requirements

- Docker and Docker Compose
- Model file: `Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf` in `/opt/stacks/shared-ai-models/`

### Platform-specific

| Platform | File | GPU Support |
|----------|------|-------------|
| Linux (NVIDIA) | `docker-compose.yaml` | CUDA |
| macOS | `docker-compose.mac.yaml` | CPU only |
| Windows (NVIDIA) | `docker-compose.yaml` | CUDA (see notes) |

## Usage

### Linux / Windows

```bash
docker compose up -d
```

### macOS

```bash
docker compose -f docker-compose.mac.yaml up -d
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

## Windows Notes

The `gpus: all` syntax may not work on Windows. If you get errors, replace it with the deploy syntax:

```yaml
services:
  llama-qwen3-coder:
    # Remove this line:
    # gpus: all

    # Add this instead:
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
```

Requirements for Windows:
- Docker Desktop with WSL2 backend enabled
- NVIDIA GPU drivers installed on Windows
- NVIDIA CUDA support in WSL2

## License

MIT
