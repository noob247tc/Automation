#!/usr/bin/env bash
# Standalone macOS/Linux setup and Playwright runner.
# The repository is cloned into a sibling directory named "automation".

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIR="${SCRIPT_DIR}/automation"
REPO_URL="https://github.com/christianmartincabucos/Automation.git"
OS_NAME="$(uname -s)"
PACKAGE_MANAGER=""

finish() {
    status=$?
    trap - EXIT
    printf '\n'
    if [ "$status" -eq 0 ]; then
        echo "=========================================="
        echo "  Automation run finished successfully."
        echo "=========================================="
    else
        echo "=========================================="
        echo "  Setup or Playwright run failed (code: $status)."
        echo "  Review the messages above and try again."
        echo "=========================================="
    fi
    if [ -t 0 ]; then
        printf '\nPress Enter to close this window...'
        read -r _ || true
    fi
    exit "$status"
}
trap finish EXIT

fail() {
    echo "[ERROR] $*" >&2
    exit 1
}

has_command() {
    command -v "$1" >/dev/null 2>&1
}

run_as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif has_command sudo; then
        sudo "$@"
    else
        fail "Administrator/root access is required to install packages. Install sudo or rerun as root."
    fi
}

node_is_usable() {
    has_command node && has_command npm || return 1
    local major
    major="$(node -p 'Number(process.versions.node.split(".")[0])' 2>/dev/null || echo 0)"
    [ "$major" -ge 20 ]
}

refresh_command_path() {
    hash -r 2>/dev/null || true
    if [ "$OS_NAME" = "Darwin" ]; then
        if [ -x /opt/homebrew/bin/brew ]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
        elif [ -x /usr/local/bin/brew ]; then
            eval "$(/usr/local/bin/brew shellenv)"
        fi
    fi
}

install_macos_tools() {
    if ! has_command brew; then
        echo "[INFO] Homebrew is missing. Installing Homebrew..."
        has_command curl || fail "curl is required to install Homebrew."
        NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        refresh_command_path
    fi

    has_command brew || fail "Homebrew was not found after installation. Open a new Terminal window and rerun this file."

    if ! has_command git; then
        echo "[INFO] Installing Git with Homebrew..."
        brew install git
    fi

    if ! node_is_usable; then
        echo "[INFO] Installing/upgrading Node.js LTS with Homebrew..."
        brew install node || brew upgrade node
    fi

    refresh_command_path
}

detect_linux_package_manager() {
    if has_command apt-get; then
        PACKAGE_MANAGER="apt"
    elif has_command dnf; then
        PACKAGE_MANAGER="dnf"
    elif has_command yum; then
        PACKAGE_MANAGER="yum"
    elif has_command pacman; then
        PACKAGE_MANAGER="pacman"
    elif has_command zypper; then
        PACKAGE_MANAGER="zypper"
    elif has_command apk; then
        PACKAGE_MANAGER="apk"
    else
        fail "Unsupported Linux package manager. Install Git and Node.js 20+ manually, then rerun this file."
    fi
}

install_linux_tools() {
    detect_linux_package_manager

    case "$PACKAGE_MANAGER" in
        apt)
            if ! has_command git; then
                echo "[INFO] Installing Git..."
                run_as_root apt-get update
                run_as_root apt-get install -y git
            fi
            if ! node_is_usable; then
                echo "[INFO] Installing Node.js LTS..."
                run_as_root apt-get update
                run_as_root apt-get install -y ca-certificates curl
                local installer
                installer="$(mktemp)"
                curl -fsSL https://deb.nodesource.com/setup_lts.x -o "$installer"
                run_as_root bash "$installer"
                rm -f "$installer"
                run_as_root apt-get install -y nodejs
            fi
            ;;
        dnf|yum)
            if ! has_command git; then
                echo "[INFO] Installing Git..."
                run_as_root "$PACKAGE_MANAGER" install -y git
            fi
            if ! node_is_usable; then
                echo "[INFO] Installing Node.js LTS..."
                run_as_root "$PACKAGE_MANAGER" install -y ca-certificates curl
                local installer
                installer="$(mktemp)"
                curl -fsSL https://rpm.nodesource.com/setup_lts.x -o "$installer"
                run_as_root bash "$installer"
                rm -f "$installer"
                run_as_root "$PACKAGE_MANAGER" install -y nodejs
            fi
            ;;
        pacman)
            if ! has_command git || ! node_is_usable; then
                echo "[INFO] Installing Git and Node.js..."
                run_as_root pacman -Sy --noconfirm git nodejs npm
            fi
            ;;
        zypper)
            if ! has_command git || ! node_is_usable; then
                echo "[INFO] Installing Git and Node.js..."
                run_as_root zypper --non-interactive refresh
                run_as_root zypper --non-interactive install git nodejs npm
            fi
            ;;
        apk)
            if ! has_command git || ! node_is_usable; then
                echo "[INFO] Installing Git and Node.js..."
                run_as_root apk add --no-cache git nodejs npm
            fi
            ;;
    esac
    refresh_command_path
}

echo
echo "=========================================="
echo "  Automation - Playwright Setup and Runner"
echo "=========================================="
echo
echo "[INFO] Operating system: $OS_NAME"
echo "[INFO] Project folder: $PROJECT_DIR"
echo

case "$OS_NAME" in
    Darwin)
        if ! has_command git || ! node_is_usable; then
            install_macos_tools
        fi
        ;;
    Linux)
        detect_linux_package_manager
        if ! has_command git || ! node_is_usable; then
            install_linux_tools
        fi
        ;;
    *)
        fail "This script supports macOS and Linux. Detected: $OS_NAME"
        ;;
esac

has_command git || fail "Git is still unavailable. Install Git manually and rerun."
node_is_usable || fail "Node.js 20+ and npm are required. Install the current Node.js LTS release and rerun."

echo "[OK] Git: $(git --version)"
echo "[OK] Node.js: $(node --version)"
echo "[OK] npm: $(npm --version)"

if [ -d "$PROJECT_DIR/.git" ]; then
    echo
    echo "[INFO] Repository already exists. Updating it..."
    git -C "$PROJECT_DIR" pull
elif [ -e "$PROJECT_DIR" ]; then
    fail "'$PROJECT_DIR' exists but is not a Git repository. Rename or remove that folder, then rerun."
else
    echo
    echo "[INFO] Cloning repository..."
    git clone "$REPO_URL" "$PROJECT_DIR"
fi

cd "$PROJECT_DIR"

echo
echo "[INFO] Installing npm dependencies..."
npm install

echo
echo "[INFO] Installing Playwright browsers..."
if [ "$OS_NAME" = "Linux" ] && [ "$PACKAGE_MANAGER" = "apt" ]; then
    # On Debian/Ubuntu, also install the operating-system libraries Playwright browsers need.
    npx playwright install --with-deps
else
    npx playwright install
fi

echo
echo "[INFO] Running Playwright tests..."
if [ -x "./node_modules/.bin/playwright" ]; then
    ./node_modules/.bin/playwright test
else
    npx playwright test
fi
