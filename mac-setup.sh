#!/bin/bash

# Local AI - Apple Silicon Mac Startup Script
# This script starts llama-server natively (for Metal GPU acceleration)
# and Open WebUI in Docker.

set -e

MODEL_DIR="$HOME/ai-models"
PORT=18080
LLAMA_PID_FILE="/tmp/local-ai-llama.pid"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_error() { echo -e "${RED}Error: $1${NC}" >&2; }
print_success() { echo -e "${GREEN}$1${NC}"; }
print_warning() { echo -e "${YELLOW}$1${NC}"; }

usage() {
    echo "Usage: ./mac-setup.sh <command> [model-filename]"
    echo ""
    echo "Commands:"
    echo "  start <model-filename>  Start llama-server and Open WebUI"
    echo "  stop                    Stop llama-server and Open WebUI"
    echo "  status                  Check if services are running"
    echo ""
    echo "Example:"
    echo "  ./mac-setup.sh start Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
    echo "  ./mac-setup.sh stop"
    exit 1
}

check_homebrew() {
    if ! command -v brew &> /dev/null; then
        print_error "Homebrew is not installed."
        echo "Install it from https://brew.sh or run:"
        echo '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
        exit 1
    fi
}

check_llama_cpp() {
    if ! command -v llama-server &> /dev/null; then
        print_warning "llama.cpp is not installed."
        echo ""
        read -p "Would you like to install it via Homebrew? [Y/n] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Nn]$ ]]; then
            echo "Please install llama.cpp manually and try again."
            exit 1
        fi
        echo "Installing llama.cpp..."
        brew install llama.cpp
        print_success "llama.cpp installed successfully!"
    fi
}

check_docker() {
    if ! command -v docker &> /dev/null; then
        print_error "Docker is not installed."
        echo "Install Docker Desktop from https://www.docker.com/products/docker-desktop/"
        exit 1
    fi
    if ! docker info &> /dev/null; then
        print_error "Docker is not running. Please start Docker Desktop."
        exit 1
    fi
}

start_services() {
    local model_file="$1"

    if [ -z "$model_file" ]; then
        print_error "Model filename is required."
        usage
    fi

    local model_path="$MODEL_DIR/$model_file"

    if [ ! -f "$model_path" ]; then
        print_error "Model file not found: $model_path"
        echo "Make sure you've downloaded a model to ~/ai-models/"
        exit 1
    fi

    # Check if llama-server is already running
    if [ -f "$LLAMA_PID_FILE" ] && kill -0 "$(cat "$LLAMA_PID_FILE")" 2>/dev/null; then
        print_warning "llama-server is already running (PID: $(cat "$LLAMA_PID_FILE"))"
    else
        echo "Starting llama-server with $model_file..."
        llama-server -m "$model_path" --host 0.0.0.0 --port $PORT &
        echo $! > "$LLAMA_PID_FILE"
        print_success "llama-server started (PID: $(cat "$LLAMA_PID_FILE"))"

        # Wait for server to be ready
        echo "Waiting for llama-server to be ready..."
        for i in {1..60}; do
            if curl -s "http://127.0.0.1:$PORT/health" > /dev/null 2>&1; then
                print_success "llama-server is ready!"
                break
            fi
            if [ $i -eq 60 ]; then
                print_warning "llama-server is taking longer than expected to start."
                echo "Check the terminal output for any errors."
            fi
            sleep 2
        done
    fi

    # Start Open WebUI
    echo "Starting Open WebUI..."
    docker compose --profile mac up -d
    print_success "Open WebUI started!"

    echo ""
    print_success "All services are running!"
    echo "Open WebUI: http://localhost:3000"
    echo ""
    echo "To stop services, run: ./mac-setup.sh stop"
}

stop_services() {
    echo "Stopping services..."

    # Stop Open WebUI
    docker compose --profile mac down 2>/dev/null || true

    # Stop llama-server
    if [ -f "$LLAMA_PID_FILE" ]; then
        local pid=$(cat "$LLAMA_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid"
            print_success "llama-server stopped (PID: $pid)"
        fi
        rm -f "$LLAMA_PID_FILE"
    else
        # Try to find and kill any running llama-server
        pkill -f "llama-server" 2>/dev/null || true
    fi

    print_success "All services stopped."
}

show_status() {
    echo "Service Status:"
    echo ""

    # Check llama-server
    if [ -f "$LLAMA_PID_FILE" ] && kill -0 "$(cat "$LLAMA_PID_FILE")" 2>/dev/null; then
        print_success "llama-server: Running (PID: $(cat "$LLAMA_PID_FILE"))"
        if curl -s "http://127.0.0.1:$PORT/health" > /dev/null 2>&1; then
            echo "  Health: OK"
        else
            print_warning "  Health: Not responding"
        fi
    else
        echo "llama-server: Not running"
    fi

    echo ""

    # Check Open WebUI
    if docker ps --format '{{.Names}}' | grep -q "local-ai-open-webui"; then
        print_success "Open WebUI: Running"
        echo "  URL: http://localhost:3000"
    else
        echo "Open WebUI: Not running"
    fi
}

# Main
case "${1:-}" in
    start)
        check_homebrew
        check_llama_cpp
        check_docker
        start_services "$2"
        ;;
    stop)
        stop_services
        ;;
    status)
        show_status
        ;;
    *)
        usage
        ;;
esac
