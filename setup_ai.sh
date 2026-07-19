#!/usr/bin/env bash

set -Eeuo pipefail

readonly DEFAULT_MODEL="dolphin3:8b"
readonly OLLAMA_URL="http://127.0.0.1:11434"

MODEL_NAME="${MODEL_NAME:-${DEFAULT_MODEL}}"
START_CHAT=true
OLLAMA_BIN=""
TEMP_DIR=""

log() {
    printf '\n\033[1;34m%s\033[0m\n' "$*"
}

success() {
    printf '\033[1;32m%s\033[0m\n' "$*"
}

fail() {
    printf '\033[1;31mError: %s\033[0m\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n "${TEMP_DIR}" && -d "${TEMP_DIR}" ]]; then
        rm -rf -- "${TEMP_DIR}"
    fi
}

trap cleanup EXIT

print_help() {
    cat <<'HELP'
Usage: ./setup_ai.sh [options]

Install Ollama on an Apple Silicon Mac, download a Dolphin model, and start chat.

Options:
  --model NAME   Ollama model to use (default: dolphin3:8b)
  --no-chat      Install, start Ollama, and pull the model without opening chat
  -h, --help     Show this help

Environment:
  MODEL_NAME     Alternative way to select the model

Examples:
  ./setup_ai.sh
  ./setup_ai.sh --no-chat
  ./setup_ai.sh --model dolphin-llama3:8b
  ./setup_ai.sh --model dolphin-mixtral:8x7b
HELP
}

parse_args() {
    while (($# > 0)); do
        case "$1" in
            --model)
                (($# >= 2)) || fail "--model requires a model name."
                MODEL_NAME="$2"
                shift 2
                ;;
            --no-chat)
                START_CHAT=false
                shift
                ;;
            -h|--help)
                print_help
                exit 0
                ;;
            *)
                fail "Unknown option: $1 (run with --help)"
                ;;
        esac
    done
}

check_platform() {
    log "[1/5] Checking this Mac"

    [[ "$(uname -s)" == "Darwin" ]] || fail "This script supports macOS only."
    [[ "$(uname -m)" == "arm64" ]] || fail "An Apple Silicon Mac is required."

    local macos_major
    macos_major="$(sw_vers -productVersion | cut -d. -f1)"
    ((macos_major >= 14)) || fail "Ollama requires macOS 14 Sonoma or newer."

    command -v curl >/dev/null 2>&1 || fail "curl is required but was not found."
    success "Apple Silicon and macOS requirements are satisfied."
}

setup_package_manager() {
    log "[2/5] Checking Homebrew"

    if command -v brew >/dev/null 2>&1; then
        success "Homebrew is already installed."
        return
    fi

    printf '%s\n' "Homebrew was not found. Downloading the official installer..."
    TEMP_DIR="$(mktemp -d)"
    local installer="${TEMP_DIR}/homebrew-install.sh"
    curl --fail --silent --show-error --location \
        https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh \
        --output "${installer}"
    /bin/bash "${installer}"

    if [[ -x /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi

    command -v brew >/dev/null 2>&1 || fail \
        "Homebrew installed, but brew is not on PATH. Follow the instructions printed above and rerun this script."
    success "Homebrew is ready."
}

resolve_ollama_binary() {
    if command -v ollama >/dev/null 2>&1; then
        OLLAMA_BIN="$(command -v ollama)"
    elif [[ -x /Applications/Ollama.app/Contents/Resources/ollama ]]; then
        OLLAMA_BIN="/Applications/Ollama.app/Contents/Resources/ollama"
    else
        fail "Ollama was installed, but its CLI could not be found. Open Ollama once and rerun this script."
    fi
}

install_inference_engine() {
    log "[3/5] Checking Ollama"

    if command -v ollama >/dev/null 2>&1 || \
        [[ -x /Applications/Ollama.app/Contents/Resources/ollama ]]; then
        success "Ollama is already installed."
    else
        brew install --cask ollama
    fi

    resolve_ollama_binary
    success "Using Ollama CLI: ${OLLAMA_BIN}"
}

ollama_is_ready() {
    curl --fail --silent --max-time 2 "${OLLAMA_URL}/api/tags" >/dev/null 2>&1
}

start_llm_service() {
    log "[4/5] Starting the local Ollama service"

    if ollama_is_ready; then
        success "Ollama is already listening on ${OLLAMA_URL}."
        return
    fi

    open -a Ollama
    printf '%s' "Waiting for Ollama"

    local attempt
    for attempt in {1..60}; do
        if ollama_is_ready; then
            printf '\n'
            success "Ollama is ready on ${OLLAMA_URL}."
            return
        fi
        printf '.'
        sleep 1
    done

    printf '\n'
    fail "Ollama did not become ready within 60 seconds. Open the Ollama app and check ~/.ollama/logs/server.log."
}

pull_model() {
    log "[5/5] Downloading model: ${MODEL_NAME}"
    printf '%s\n' "The first download requires internet access. Model inference is local after download."
    "${OLLAMA_BIN}" pull "${MODEL_NAME}"
    success "Model is ready: ${MODEL_NAME}"
}

run_model() {
    printf '\n%s\n' "Starting local chat. Enter /bye to exit."
    exec "${OLLAMA_BIN}" run "${MODEL_NAME}"
}

main() {
    parse_args "$@"

    printf '%s\n' \
        "============================================================" \
        " Apple Silicon local LLM setup with Ollama + Dolphin" \
        "============================================================"

    check_platform
    setup_package_manager
    install_inference_engine
    start_llm_service
    pull_model

    if [[ "${START_CHAT}" == true ]]; then
        run_model
    else
        success "Setup completed without starting chat (--no-chat)."
        printf 'Run later with: %q run %q\n' "${OLLAMA_BIN}" "${MODEL_NAME}"
    fi
}

main "$@"
