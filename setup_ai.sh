#!/usr/bin/env bash

set -Eeuo pipefail

readonly DEFAULT_MODEL="hf.co/mlabonne/Meta-Llama-3.1-8B-Instruct-abliterated-GGUF:Q4_K_M"
readonly DOLPHIN_MODEL="dolphin3:8b"
readonly OLLAMA_URL="http://127.0.0.1:11434"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
readonly SCRIPT_DIR

MODEL_NAME="${MODEL_NAME:-${DEFAULT_MODEL}}"
CUSTOM_MODEL_NAME="${CUSTOM_MODEL_NAME:-my-local-llm}"
START_CHAT=true
CREATE_CUSTOM_MODEL=true
ACTIVE_MODEL_NAME=""
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

Install Ollama, download a low-refusal model, customize its response style, and chat.

Options:
  --model NAME        Base Ollama/Hugging Face model
  --dolphin           Use dolphin3:8b instead of the abliterated default
  --custom-name NAME  Custom model name (default: my-local-llm)
  --base-only         Skip Modelfile customization and run the base model
  --no-chat           Complete setup without opening interactive chat
  -h, --help          Show this help

Environment:
  MODEL_NAME          Alternative way to select the base model
  CUSTOM_MODEL_NAME   Alternative way to name the custom model

Examples:
  ./setup_ai.sh
  ./setup_ai.sh --no-chat
  ./setup_ai.sh --dolphin
  ./setup_ai.sh --model dolphin-llama3:8b
  ./setup_ai.sh --custom-name private-dolphin
  ./setup_ai.sh --base-only
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
            --dolphin)
                MODEL_NAME="${DOLPHIN_MODEL}"
                shift
                ;;
            --custom-name)
                (($# >= 2)) || fail "--custom-name requires a model name."
                CUSTOM_MODEL_NAME="$2"
                shift 2
                ;;
            --base-only)
                CREATE_CUSTOM_MODEL=false
                shift
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

    [[ "${MODEL_NAME}" =~ ^[[:alnum:]_.:/-]+$ ]] || fail \
        "Invalid base model name: ${MODEL_NAME}"
    [[ "${CUSTOM_MODEL_NAME}" =~ ^[[:alnum:]_.:/-]+$ ]] || fail \
        "Invalid custom model name: ${CUSTOM_MODEL_NAME}"
}

check_platform() {
    log "[1/6] Checking this Mac"

    [[ "$(uname -s)" == "Darwin" ]] || fail "This script supports macOS only."
    [[ "$(uname -m)" == "arm64" ]] || fail "An Apple Silicon Mac is required."

    local macos_major
    macos_major="$(sw_vers -productVersion | cut -d. -f1)"
    ((macos_major >= 14)) || fail "Ollama requires macOS 14 Sonoma or newer."

    command -v curl >/dev/null 2>&1 || fail "curl is required but was not found."
    success "Apple Silicon and macOS requirements are satisfied."
}

setup_package_manager() {
    log "[2/6] Checking Homebrew"

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
    log "[3/6] Checking Ollama"

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
    log "[4/6] Starting the local Ollama service"

    if ollama_is_ready; then
        success "Ollama is already listening on ${OLLAMA_URL}."
        return
    fi

    open -a Ollama
    printf '%s' "Waiting for Ollama"

    for _ in {1..60}; do
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
    log "[5/6] Downloading base model: ${MODEL_NAME}"
    printf '%s\n' "The first download requires internet access. Model inference is local after download."
    "${OLLAMA_BIN}" pull "${MODEL_NAME}"
    success "Model is ready: ${MODEL_NAME}"
}

create_custom_model() {
    log "[6/6] Creating custom model: ${CUSTOM_MODEL_NAME}"

    [[ -f "${SCRIPT_DIR}/Modelfile" ]] || fail \
        "Modelfile was not found next to setup_ai.sh."

    if [[ -z "${TEMP_DIR}" ]]; then
        TEMP_DIR="$(mktemp -d)"
    fi

    local generated_modelfile="${TEMP_DIR}/Modelfile"
    awk -v model="${MODEL_NAME}" \
        'NR == 1 { print "FROM " model; next } { print }' \
        "${SCRIPT_DIR}/Modelfile" > "${generated_modelfile}"

    "${OLLAMA_BIN}" create "${CUSTOM_MODEL_NAME}" -f "${generated_modelfile}"
    ACTIVE_MODEL_NAME="${CUSTOM_MODEL_NAME}"
    success "Custom model is ready: ${CUSTOM_MODEL_NAME}"
}

run_model() {
    printf '\nStarting local chat with %s. Enter /bye to exit.\n' \
        "${ACTIVE_MODEL_NAME}"
    exec "${OLLAMA_BIN}" run "${ACTIVE_MODEL_NAME}"
}

main() {
    parse_args "$@"
    ACTIVE_MODEL_NAME="${MODEL_NAME}"

    printf '%s\n' \
        "============================================================" \
        " Apple Silicon local LLM setup with Ollama" \
        "============================================================"

    check_platform
    setup_package_manager
    install_inference_engine
    start_llm_service
    pull_model

    if [[ "${CREATE_CUSTOM_MODEL}" == true ]]; then
        create_custom_model
    else
        log "[6/6] Skipping Modelfile customization (--base-only)"
    fi

    if [[ "${START_CHAT}" == true ]]; then
        run_model
    else
        success "Setup completed without starting chat (--no-chat)."
        printf 'Run later with: %q run %q\n' \
            "${OLLAMA_BIN}" "${ACTIVE_MODEL_NAME}"
    fi
}

main "$@"
