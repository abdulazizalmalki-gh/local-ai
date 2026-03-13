# Local AI

A self-hosted local LLM setup using llama.cpp and Open WebUI.

## Services

- **llama-server** - llama.cpp server running your chosen model
- **open-webui** - Web interface for interacting with the LLM

## Requirements

- Docker and Docker Compose
- A GGUF model file in `~/ai-models/` (see examples below, or bring your own—any single-file `.gguf` model works)
- **Disk space:** 4-5GB with the lightweight model, 10-12GB with the balanced model, or 28-32GB with the recommended model (includes Docker images and data)

## Quick Start

### Step 1: Download a Model

Choose a model based on your hardware and internet connection:

| Model | Size | Best For |
|-------|------|----------|
| Qwen3.5-2B (lightweight) | ~1.2GB | Limited bandwidth or testing |
| Qwen3.5-9B (balanced) | ~5.7GB | Good performance with moderate hardware |
| Qwen3.5-35B-A3B (recommended) | ~22GB | Best quality, requires decent hardware |

Create the models directory:

```bash
mkdir -p ~/ai-models/
```

Download using one of the methods below:

#### Using Hugging Face CLI (recommended)

**Windows (WSL2)/Ubuntu users:** Install dependencies first:
```bash
sudo apt update && sudo apt install -y python3-venv python3-pip
```

**Install the CLI:**

Standalone (Linux/macOS/Windows WSL2):
```bash
curl -LsSf https://hf.co/cli/install.sh | bash
```

Homebrew (macOS/Linux):
```bash
brew install huggingface-cli
```

**Download:**

**Qwen3.5-2B (~1.2GB):**
```bash
hf download unsloth/Qwen3.5-2B-GGUF Qwen3.5-2B-Q4_0.gguf --local-dir ~/ai-models/
```

**Qwen3.5-9B (~5.7GB):**
```bash
hf download unsloth/Qwen3.5-9B-GGUF Qwen3.5-9B-Q4_K_M.gguf --local-dir ~/ai-models/
```

**Qwen3.5-35B-A3B (~22GB):**
```bash
hf download unsloth/Qwen3.5-35B-A3B-GGUF Qwen3.5-35B-A3B-Q4_K_M.gguf --local-dir ~/ai-models/
```

#### Using wget

Install wget if needed: Ubuntu/Debian: `sudo apt install wget` | Fedora: `sudo dnf install wget` | macOS: `brew install wget` | Windows: `winget install wget`

**Qwen3.5-2B (~1.2GB):**
```bash
wget -O ~/ai-models/Qwen3.5-2B-Q4_0.gguf \
  "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q4_0.gguf?download=true"
```

**Qwen3.5-9B (~5.7GB):**
```bash
wget -O ~/ai-models/Qwen3.5-9B-Q4_K_M.gguf \
  "https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-Q4_K_M.gguf?download=true"
```

**Qwen3.5-35B-A3B (~22GB):**
```bash
wget -O ~/ai-models/Qwen3.5-35B-A3B-Q4_K_M.gguf \
  "https://huggingface.co/unsloth/Qwen3.5-35B-A3B-GGUF/resolve/main/Qwen3.5-35B-A3B-Q4_K_M.gguf?download=true"
```

#### Using curl

curl is pre-installed on macOS, most Linux distributions, and Windows 10/11.

**Qwen3.5-2B (~1.2GB):**
```bash
curl -L -o ~/ai-models/Qwen3.5-2B-Q4_0.gguf \
  "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q4_0.gguf?download=true"
```

**Qwen3.5-9B (~5.7GB):**
```bash
curl -L -o ~/ai-models/Qwen3.5-9B-Q4_K_M.gguf \
  "https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-Q4_K_M.gguf?download=true"
```

**Qwen3.5-35B-A3B (~22GB):**
```bash
curl -L -o ~/ai-models/Qwen3.5-35B-A3B-Q4_K_M.gguf \
  "https://huggingface.co/unsloth/Qwen3.5-35B-A3B-GGUF/resolve/main/Qwen3.5-35B-A3B-Q4_K_M.gguf?download=true"
```

### Step 2: Start the Services

Choose your platform below:

---

#### Linux / Windows (WSL2) / Intel Mac

**With NVIDIA GPU (Linux/Windows WSL2 only):**

```bash
MODEL_FILE=<model-filename> docker compose --profile nvidia-cuda up -d
```

**CPU only:**

```bash
MODEL_FILE=<model-filename> docker compose --profile cpu up -d
```

Replace `<model-filename>` with your downloaded model, e.g., `Qwen3.5-35B-A3B-Q4_K_M.gguf`

**Stop services:**

```bash
docker compose --profile <profile> down
```

---

#### Apple Silicon Mac (M1/M2/M3/M4/M5)

Apple Silicon Macs require native llama.cpp installation to use Metal GPU acceleration. A helper script is provided to simplify the setup.

**Start services:**

```bash
./mac-setup.sh start <model-filename>
```

The script will:
1. Check for (and offer to install) llama.cpp via Homebrew
2. Start llama-server with Metal acceleration
3. Start Open WebUI in Docker

**Stop services:**

```bash
./mac-setup.sh stop
```

**Check status:**

```bash
./mac-setup.sh status
```

**Example:**

```bash
./mac-setup.sh start Qwen3.5-35B-A3B-Q4_K_M.gguf
```

---

### Step 3: Open the Web Interface

Access Open WebUI at http://localhost:3000

## Platform Summary

| Platform | Method | GPU Support |
|----------|--------|-------------|
| Linux (x86_64) | Docker | NVIDIA CUDA or CPU |
| Windows (WSL2) | Docker | NVIDIA CUDA or CPU |
| Intel Mac | Docker | CPU only |
| Apple Silicon Mac | Native + Docker | Metal (via native llama.cpp) |

## Ports

| Service | Port |
|---------|------|
| llama.cpp API | 18080 |
| Open WebUI | 3000 |

## Windows Notes

Requirements for NVIDIA GPU support:

- Docker Desktop with WSL2 backend enabled
- NVIDIA GPU drivers installed on Windows
- NVIDIA CUDA support in WSL2

If `gpus: all` doesn't work, edit `docker-compose.yaml` and replace it with:

```yaml
deploy:
  resources:
    reservations:
      devices:
        - driver: nvidia
          count: all
          capabilities: [gpu]
```

## License

MIT