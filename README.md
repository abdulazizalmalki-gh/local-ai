# Local AI

A self-hosted local LLM setup using llama.cpp and Open WebUI.

## Services

- **llama-server** - llama.cpp server running your chosen model
- **open-webui** - Web interface for interacting with the LLM

## Requirements

- Docker and Docker Compose
- A GGUF model file in `~/ai-models/` (see examples below, or bring your own—any single-file `.gguf` model works)
- **Disk space:** 3-4GB with the lightweight model, 15-18GB with GPT-OSS-20B, or 22-25GB with the recommended model (includes Docker images and data)
- **macOS only:** [Homebrew](https://brew.sh) (for installing dependencies)

## Quick Start

### Step 1: Download a Model

Choose a model based on your hardware and internet connection:

| Model | Size | Best For |
|-------|------|----------|
| Qwen3-0.6B (lightweight) | ~0.5GB | Limited bandwidth or testing |
| GPT-OSS-20B | ~12GB | Balanced performance and size |
| Qwen3-Coder-30B-A3B-Instruct (recommended) | ~19GB | Better quality, requires decent hardware |

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

Qwen3-0.6B (~0.5GB):
```bash
hf download unsloth/Qwen3-0.6B-GGUF Qwen3-0.6B-Q4_K_M.gguf --local-dir ~/ai-models/
```

GPT-OSS-20B (~12GB):
```bash
hf download unsloth/gpt-oss-20b-GGUF gpt-oss-20b-Q4_K_M.gguf --local-dir ~/ai-models/
```

Qwen3-Coder-30B (~19GB):
```bash
hf download unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf --local-dir ~/ai-models/
```

#### Using wget

Install wget if needed: Ubuntu/Debian: `sudo apt install wget` | Fedora: `sudo dnf install wget` | macOS: `brew install wget` | Windows: `winget install wget`

Qwen3-0.6B (~0.5GB):
```bash
wget -O ~/ai-models/Qwen3-0.6B-Q4_K_M.gguf \
  "https://huggingface.co/unsloth/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q4_K_M.gguf?download=true"
```

GPT-OSS-20B (~12GB):
```bash
wget -O ~/ai-models/gpt-oss-20b-Q4_K_M.gguf \
  "https://huggingface.co/unsloth/gpt-oss-20b-GGUF/resolve/main/gpt-oss-20b-Q4_K_M.gguf?download=true"
```

Qwen3-Coder-30B (~19GB):
```bash
wget -O ~/ai-models/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf \
  "https://huggingface.co/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF/resolve/main/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf?download=true"
```

#### Using curl

curl is pre-installed on macOS, most Linux distributions, and Windows 10/11.

Qwen3-0.6B (~0.5GB):
```bash
curl -L -o ~/ai-models/Qwen3-0.6B-Q4_K_M.gguf \
  "https://huggingface.co/unsloth/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q4_K_M.gguf?download=true"
```

GPT-OSS-20B (~12GB):
```bash
curl -L -o ~/ai-models/gpt-oss-20b-Q4_K_M.gguf \
  "https://huggingface.co/unsloth/gpt-oss-20b-GGUF/resolve/main/gpt-oss-20b-Q4_K_M.gguf?download=true"
```

Qwen3-Coder-30B (~19GB):
```bash
curl -L -o ~/ai-models/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf \
  "https://huggingface.co/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF/resolve/main/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf?download=true"
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

Replace `<model-filename>` with your downloaded model, e.g., `Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf`

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
./mac-setup.sh start Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf
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
