#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
readonly SCRIPT_DIR
readonly DEFAULT_MODEL="hf.co/mlabonne/Meta-Llama-3.1-8B-Instruct-abliterated-GGUF:Q4_K_M"
readonly DOLPHIN_MODEL="dolphin3:8b"
readonly OLLAMA_URL="http://127.0.0.1:11434"
readonly AGENT_VENV="${SCRIPT_DIR}/.agents-venv"
readonly AGENT_PYTHON="${AGENT_VENV}/bin/python"
readonly PYTHON_BIN="${PYTHON_BIN:-python3.12}"
readonly VISION_MODEL="${VISION_MODEL:-gemma3:4b}"
readonly MAC_MODEL="${MAC_MODEL:-qwen3-vl:8b}"
export VISION_MODEL MAC_MODEL
readonly TAILSCALE_APP=/Applications/Tailscale.app/Contents/MacOS/Tailscale
readonly TAILSCALE_PACKAGE_URL=https://pkgs.tailscale.com/stable/Tailscale-latest-macos.pkg
readonly CONSOLE_HOST="${CONSOLE_HOST:-127.0.0.1}"
readonly CONSOLE_PORT="${CONSOLE_PORT:-8787}"
readonly LAUNCH_AGENT_LABEL="com.yuusakuri.local-agent-console"
readonly LAUNCH_AGENT_PATH="${HOME}/Library/LaunchAgents/${LAUNCH_AGENT_LABEL}.plist"
readonly CONSOLE_LOG_DIR="${SCRIPT_DIR}/agents/output"

MODEL_NAME="${MODEL_NAME:-${DEFAULT_MODEL}}"
CUSTOM_MODEL_NAME="${CUSTOM_MODEL_NAME:-my-local-llm}"
START_CHAT=true
CREATE_CUSTOM_MODEL=true
ACTIVE_MODEL_NAME=""
OLLAMA_BIN=""
TEMP_DIR=""
TAILSCALE_PACKAGE_PATH=""
CONSOLE_PID=""

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
    if [[ -n "${CONSOLE_PID}" ]] && kill -0 "${CONSOLE_PID}" >/dev/null 2>&1; then
        kill "${CONSOLE_PID}" >/dev/null 2>&1 || true
        wait "${CONSOLE_PID}" 2>/dev/null || true
    fi
    if [[ -n "${TAILSCALE_PACKAGE_PATH}" && -f "${TAILSCALE_PACKAGE_PATH}" ]]; then
        rm -f -- "${TAILSCALE_PACKAGE_PATH}"
    fi
    if [[ -n "${TEMP_DIR}" && -d "${TEMP_DIR}" ]]; then
        rm -rf -- "${TEMP_DIR}"
    fi
}

require-macos() {
    [[ "$(uname -s)" == "Darwin" ]] || fail "This script supports macOS only."
}

check-platform() {
    log "[1/7] Checking this Mac"

    require-macos
    [[ "$(uname -m)" == "arm64" ]] || fail "An Apple Silicon Mac is required."

    local macos_major
    macos_major="$(sw_vers -productVersion | cut -d. -f1)"
    ((macos_major >= 14)) || fail "Ollama requires macOS 14 Sonoma or newer."

    command -v curl >/dev/null 2>&1 || fail "curl is required but was not found."
    success "Apple Silicon and macOS requirements are satisfied."
}

reset-ai-settings() {
    START_CHAT=true
    CREATE_CUSTOM_MODEL=true
}

print-ai-help() {
    cat <<'EOF'
Usage: ./run.sh setup-ai [options]

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
EOF
}

parse-ai-args() {
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
                print-ai-help
                return 1
                ;;
            *)
                fail "Unknown setup-ai option: $1"
                ;;
        esac
    done

    [[ "${MODEL_NAME}" =~ ^[[:alnum:]_.:/-]+$ ]] || fail \
        "Invalid base model name: ${MODEL_NAME}"
    [[ "${CUSTOM_MODEL_NAME}" =~ ^[[:alnum:]_.:/-]+$ ]] || fail \
        "Invalid custom model name: ${CUSTOM_MODEL_NAME}"
}

setup-package-manager() {
    log "[2/7] Checking Homebrew"

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

resolve-ollama-binary() {
    if [[ -x /opt/homebrew/opt/ollama/bin/ollama ]]; then
        OLLAMA_BIN="/opt/homebrew/opt/ollama/bin/ollama"
    elif command -v ollama >/dev/null 2>&1; then
        OLLAMA_BIN="$(command -v ollama)"
    else
        fail "Ollama was installed, but its CLI could not be found."
    fi
}

install-inference-engine() {
    log "[3/7] Checking Ollama"

    if brew list --formula ollama >/dev/null 2>&1; then
        success "Ollama is already installed."
    else
        HOMEBREW_NO_INSTALL_CLEANUP=1 brew install --no-ask ollama
    fi

    resolve-ollama-binary
    success "Using Ollama CLI: ${OLLAMA_BIN}"
}

ollama-is-ready() {
    curl --fail --silent --max-time 2 "${OLLAMA_URL}/api/tags" >/dev/null 2>&1
}

configure-local-only() {
    log "[4/7] Disabling Ollama cloud features"

    local config_dir="${HOME}/.ollama"
    local config_file="${config_dir}/server.json"
    mkdir -p "${config_dir}"

    if [[ -f "${config_file}" ]] &&
        grep -Eq '"disable_ollama_cloud"[[:space:]]*:[[:space:]]*true' \
            "${config_file}"; then
        success "Ollama is already configured for local-only operation."
        return
    fi

    if [[ -f "${config_file}" ]]; then
        /usr/bin/plutil -replace disable_ollama_cloud -bool true \
            "${config_file}" 2>/dev/null ||
            /usr/bin/plutil -insert disable_ollama_cloud -bool true \
                "${config_file}" ||
            fail "Could not update ${config_file}. Check that it contains valid JSON."
    else
        printf '{\n  "disable_ollama_cloud": true\n}\n' > "${config_file}"
    fi

    if ollama-is-ready; then
        brew services restart ollama
    fi
    success "Ollama cloud features are disabled in ${config_file}."
}

start-llm-service() {
    log "[5/7] Starting the local Ollama service"

    if ollama-is-ready; then
        success "Ollama is already listening on ${OLLAMA_URL}."
        return
    fi

    brew services start ollama
    printf '%s' "Waiting for Ollama"

    local attempt
    for ((attempt = 1; attempt <= 60; attempt++)); do
        if ollama-is-ready; then
            printf '\n'
            success "Ollama is ready on ${OLLAMA_URL}."
            return
        fi
        printf '.'
        sleep 1
    done

    printf '\n'
    fail "Ollama did not become ready within 60 seconds."
}

pull-model() {
    log "[6/7] Downloading base model: ${MODEL_NAME}"
    "${OLLAMA_BIN}" pull "${MODEL_NAME}"
    success "Model is ready: ${MODEL_NAME}"
}

create-custom-model() {
    log "[7/7] Creating custom model: ${CUSTOM_MODEL_NAME}"

    [[ -f "${SCRIPT_DIR}/Modelfile" ]] || fail "Modelfile was not found next to run.sh."
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

run-model() {
    printf '\nStarting local chat with %s. Enter /bye to exit.\n' \
        "${ACTIVE_MODEL_NAME}"
    "${OLLAMA_BIN}" run "${ACTIVE_MODEL_NAME}"
}

setup-ai() {
    reset-ai-settings
    parse-ai-args "$@" || return 0
    ACTIVE_MODEL_NAME="${MODEL_NAME}"

    printf '%s\n' \
        "============================================================" \
        " Apple Silicon local LLM setup with Ollama" \
        "============================================================"

    check-platform
    setup-package-manager
    install-inference-engine
    configure-local-only
    start-llm-service
    pull-model

    if [[ "${CREATE_CUSTOM_MODEL}" == true ]]; then
        create-custom-model
    else
        log "[7/7] Skipping Modelfile customization (--base-only)"
    fi

    if [[ "${START_CHAT}" == true ]]; then
        run-model
    else
        success "Setup completed without starting chat (--no-chat)."
        printf 'Run later with: %q run %q\n' "${OLLAMA_BIN}" "${ACTIVE_MODEL_NAME}"
    fi
}

setup-agent-environment() {
    command -v "${PYTHON_BIN}" >/dev/null 2>&1 || fail \
        "${PYTHON_BIN} was not found. Install it with: brew install python@3.12"

    log "Creating the Python agent environment"
    if [[ ! -x "${AGENT_PYTHON}" ]]; then
        "${PYTHON_BIN}" -m venv "${AGENT_VENV}"
    fi
    "${AGENT_PYTHON}" -m pip install --upgrade pip
    "${AGENT_PYTHON}" -m pip install --upgrade \
        browser-use crawl4ai fastapi uvicorn python-multipart
    "${AGENT_PYTHON}" -m playwright install chromium
    "${AGENT_VENV}/bin/crawl4ai-setup"
    success "Browser Use, Crawl4AI, and the console are ready."
}

pull-vision-model() {
    resolve-ollama-binary
    log "Downloading the local vision model: ${VISION_MODEL}"
    "${OLLAMA_BIN}" pull "${VISION_MODEL}"
    success "Vision model is ready: ${VISION_MODEL}"
}

pull-mac-model() {
    resolve-ollama-binary
    log "Downloading the local Mac agent model: ${MAC_MODEL}"
    "${OLLAMA_BIN}" pull "${MAC_MODEL}"
    success "Mac agent model is ready: ${MAC_MODEL}"
}

verify-agent-environment() {
    curl --fail --silent "${OLLAMA_URL}/api/version" >/dev/null || fail \
        "The Ollama API is not responding. Run: brew services restart ollama"
    "${AGENT_PYTHON}" -c \
        'import browser_use, crawl4ai, fastapi, uvicorn; print("Local agents are ready.")'
}

setup-agents() {
    setup-ai --no-chat
    setup-agent-environment
    pull-vision-model
    pull-mac-model
    verify-agent-environment
}

validate-tailscale-package() {
    /usr/sbin/pkgutil --check-signature "${TAILSCALE_PACKAGE_PATH}" >/dev/null ||
        fail "The downloaded Tailscale package has an invalid signature."
    /usr/sbin/installer -pkginfo -pkg "${TAILSCALE_PACKAGE_PATH}" >/dev/null ||
        fail "The downloaded file is not a valid macOS installer package."
}

install-tailscale() {
    if [[ -x "${TAILSCALE_APP}" ]]; then
        success "Tailscale is already installed."
        return
    fi

    log "Installing the official Tailscale macOS package"
    if [[ -z "${TEMP_DIR}" ]]; then
        TEMP_DIR="$(mktemp -d)"
    fi
    TAILSCALE_PACKAGE_PATH="${TEMP_DIR}/Tailscale.pkg"
    curl --fail --location --output "${TAILSCALE_PACKAGE_PATH}" \
        "${TAILSCALE_PACKAGE_URL}"
    validate-tailscale-package
    sudo /usr/sbin/installer -pkg "${TAILSCALE_PACKAGE_PATH}" -target /
    rm -f -- "${TAILSCALE_PACKAGE_PATH}"
    TAILSCALE_PACKAGE_PATH=""
    open -a Tailscale
    success "Tailscale was installed. Complete the VPN extension prompt and sign in."
}

setup-all() {
    setup-agents
    install-tailscale
}

resolve-tailscale-command() {
    if command -v tailscale >/dev/null 2>&1; then
        command -v tailscale
    elif [[ -x "${TAILSCALE_APP}" ]]; then
        printf '%s\n' "${TAILSCALE_APP}"
    else
        fail "Run ./run.sh install-tailscale first."
    fi
}

tailscale-extension-awaits-approval() {
    systemextensionsctl list 2>/dev/null |
        grep -F 'io.tailscale.ipn.macsys.network-extension' |
        grep -Fq 'waiting for user'
}

xml-escape() {
    local value="$1"
    value="${value//&/&amp;}"
    value="${value//</&lt;}"
    value="${value//>/&gt;}"
    value="${value//\"/&quot;}"
    value="${value//\'/&apos;}"
    printf '%s' "${value}"
}

require-agent-environment() {
    [[ -x "${AGENT_PYTHON}" ]] || fail "Run ./run.sh setup-agents first."
}

start-console() {
    require-agent-environment
    log "Opening the local console at http://${CONSOLE_HOST}:${CONSOLE_PORT}"
    "${AGENT_PYTHON}" -m uvicorn agents.console:app \
        --app-dir "${SCRIPT_DIR}" --host "${CONSOLE_HOST}" --port "${CONSOLE_PORT}"
}

start-console-in-background() {
    require-agent-environment
    "${AGENT_PYTHON}" -m uvicorn agents.console:app \
        --app-dir "${SCRIPT_DIR}" --host "${CONSOLE_HOST}" --port "${CONSOLE_PORT}" &
    CONSOLE_PID="$!"

    local attempt
    for ((attempt = 1; attempt <= 30; attempt++)); do
        if curl --fail --silent "http://${CONSOLE_HOST}:${CONSOLE_PORT}/" >/dev/null; then
            success "Local console is ready."
            return
        fi
        sleep 1
    done
    fail "The local console did not start within 30 seconds."
}

write-launch-agent() {
    local escaped_python
    local escaped_root
    local escaped_stdout
    local escaped_stderr
    local escaped_vision_model
    local escaped_mac_model

    escaped_python="$(xml-escape "${AGENT_PYTHON}")"
    escaped_root="$(xml-escape "${SCRIPT_DIR}")"
    escaped_stdout="$(xml-escape "${CONSOLE_LOG_DIR}/console.log")"
    escaped_stderr="$(xml-escape "${CONSOLE_LOG_DIR}/console.error.log")"
    escaped_vision_model="$(xml-escape "${VISION_MODEL}")"
    escaped_mac_model="$(xml-escape "${MAC_MODEL}")"

    mkdir -p "$(dirname -- "${LAUNCH_AGENT_PATH}")" "${CONSOLE_LOG_DIR}"
    cat > "${LAUNCH_AGENT_PATH}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LAUNCH_AGENT_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${escaped_python}</string>
    <string>-m</string>
    <string>uvicorn</string>
    <string>agents.console:app</string>
    <string>--app-dir</string>
    <string>${escaped_root}</string>
    <string>--host</string>
    <string>${CONSOLE_HOST}</string>
    <string>--port</string>
    <string>${CONSOLE_PORT}</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${escaped_root}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>VISION_MODEL</key>
    <string>${escaped_vision_model}</string>
    <key>MAC_MODEL</key>
    <string>${escaped_mac_model}</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Background</string>
  <key>ThrottleInterval</key>
  <integer>10</integer>
  <key>StandardOutPath</key>
  <string>${escaped_stdout}</string>
  <key>StandardErrorPath</key>
  <string>${escaped_stderr}</string>
</dict>
</plist>
EOF
    plutil -lint "${LAUNCH_AGENT_PATH}" >/dev/null ||
        fail "Could not create a valid LaunchAgent configuration."
}

enable-autostart() {
    local tailscale_command
    local user_domain
    user_domain="gui/$(id -u)"
    tailscale_command="$(resolve-tailscale-command)"

    require-agent-environment
    if tailscale-extension-awaits-approval; then
        open -a Tailscale
        fail "Approve and sign in to Tailscale before enabling automatic startup."
    fi

    write-launch-agent
    launchctl bootout "${user_domain}/${LAUNCH_AGENT_LABEL}" >/dev/null 2>&1 || true
    launchctl bootstrap "${user_domain}" "${LAUNCH_AGENT_PATH}"
    launchctl enable "${user_domain}/${LAUNCH_AGENT_LABEL}"
    launchctl kickstart -k "${user_domain}/${LAUNCH_AGENT_LABEL}"

    local attempt
    for ((attempt = 1; attempt <= 30; attempt++)); do
        if curl --fail --silent "http://${CONSOLE_HOST}:${CONSOLE_PORT}/" >/dev/null; then
            break
        fi
        sleep 1
    done
    curl --fail --silent "http://${CONSOLE_HOST}:${CONSOLE_PORT}/" >/dev/null ||
        fail "The automatic console did not start. Check ${CONSOLE_LOG_DIR}/console.error.log"

    export TAILSCALE_BE_CLI=1
    "${tailscale_command}" serve --bg --yes "${CONSOLE_PORT}"
    success "Automatic startup is enabled. The console will start when you log in."
    "${tailscale_command}" serve status
}

disable-autostart() {
    local tailscale_command
    local user_domain
    user_domain="gui/$(id -u)"
    tailscale_command="$(resolve-tailscale-command)"

    launchctl bootout "${user_domain}/${LAUNCH_AGENT_LABEL}" >/dev/null 2>&1 || true
    if [[ -f "${LAUNCH_AGENT_PATH}" ]]; then
        rm -f -- "${LAUNCH_AGENT_PATH}"
    fi

    export TAILSCALE_BE_CLI=1
    "${tailscale_command}" serve --https=443 off >/dev/null 2>&1 || true
    success "Automatic startup is disabled."
}

start-android-remote() {
    local tailscale_command
    tailscale_command="$(resolve-tailscale-command)"

    if tailscale-extension-awaits-approval; then
        open -a Tailscale
        fail "Approve the Tailscale Network Extension, turn on Tailscale, and sign in. Then rerun: ./run.sh remote"
    fi

    start-console-in-background
    export TAILSCALE_BE_CLI=1

    log "Connecting the Mac to Tailscale"
    "${tailscale_command}" up

    log "Publishing the console to Android through Tailscale Serve"
    "${tailscale_command}" serve "${CONSOLE_PORT}"
}

usage() {
    cat <<'EOF'
Usage: ./run.sh <command> [options]

Commands:
  setup                 Set up everything, including official Tailscale
  setup-ai [options]    Set up Ollama and the local text model
  setup-agents          Set up Ollama, browser, crawl, vision, and Mac agents
  install-tailscale     Install official Tailscale only
  start                 Open the console on this Mac only
  remote                Open the console from Android through Tailscale Serve
  enable-autostart      Start the remote console automatically after login
  disable-autostart     Disable automatic startup and Tailscale Serve
  help                  Show this help

Run './run.sh setup-ai --help' for model options.
EOF
}

main() {
    require-macos
    local command="${1:-help}"
    if (($# > 0)); then
        shift
    fi

    case "${command}" in
        setup)
            (($# == 0)) || fail "setup does not accept options."
            setup-all
            ;;
        setup-ai)
            setup-ai "$@"
            ;;
        setup-agents)
            (($# == 0)) || fail "setup-agents does not accept options."
            setup-agents
            ;;
        install-tailscale)
            (($# == 0)) || fail "install-tailscale does not accept options."
            install-tailscale
            ;;
        start)
            (($# == 0)) || fail "start does not accept options."
            start-console
            ;;
        remote)
            (($# == 0)) || fail "remote does not accept options."
            start-android-remote
            ;;
        enable-autostart)
            (($# == 0)) || fail "enable-autostart does not accept options."
            enable-autostart
            ;;
        disable-autostart)
            (($# == 0)) || fail "disable-autostart does not accept options."
            disable-autostart
            ;;
        help|-h|--help)
            usage
            ;;
        *)
            usage >&2
            exit 1
            ;;
    esac
}

trap cleanup EXIT INT TERM
main "$@"
