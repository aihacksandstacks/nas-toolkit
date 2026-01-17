#!/bin/zsh
# Common functions for nas-toolkit

# Get the toolkit root directory (derived from SCRIPT_DIR set by caller)
TOOLKIT_ROOT="${SCRIPT_DIR:h}"
source "$TOOLKIT_ROOT/config.sh"

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${CYAN}==>${NC} ${BOLD}$1${NC}"
}

# Check if NAS is reachable
check_nas_connection() {
    if ! ping -c 1 -W 2 "$NAS_IP" &>/dev/null; then
        log_error "Cannot reach NAS at $NAS_IP"
        log_info "Make sure Tailscale is connected: tailscale status"
        return 1
    fi
    return 0
}

# Check if SSH to NAS works
check_nas_ssh() {
    if ! ssh -o ConnectTimeout=5 "$NAS_SSH_HOST" "echo ok" &>/dev/null; then
        log_error "Cannot SSH to NAS"
        log_info "Check your ~/.ssh/config for host '$NAS_SSH_HOST'"
        return 1
    fi
    return 0
}

# Check if Docker context exists
check_docker_context() {
    if ! docker context inspect "$NAS_DOCKER_CONTEXT" &>/dev/null; then
        log_error "Docker context '$NAS_DOCKER_CONTEXT' not found"
        return 1
    fi
    return 0
}

# Format bytes to human readable
format_bytes() {
    local bytes=$1
    if [ "$bytes" -gt 1073741824 ]; then
        echo "$(echo "scale=1; $bytes / 1073741824" | bc)G"
    elif [ "$bytes" -gt 1048576 ]; then
        echo "$(echo "scale=1; $bytes / 1048576" | bc)M"
    elif [ "$bytes" -gt 1024 ]; then
        echo "$(echo "scale=1; $bytes / 1024" | bc)K"
    else
        echo "${bytes}B"
    fi
}

# Get directory size in bytes
get_dir_size_bytes() {
    local dir=$1
    if [ -d "$dir" ] || [ -L "$dir" ]; then
        du -sk "$dir" 2>/dev/null | cut -f1 | awk '{print $1 * 1024}'
    else
        echo "0"
    fi
}

# Get directory size human readable
get_dir_size() {
    local dir=$1
    if [ -d "$dir" ] || [ -L "$dir" ]; then
        du -sh "$dir" 2>/dev/null | cut -f1
    else
        echo "0"
    fi
}

# Check if a path is a symlink
is_symlink() {
    [ -L "$1" ]
}

# Create backup of a directory
backup_dir() {
    local src=$1
    local backup="${src}.backup.$(date +%Y%m%d_%H%M%S)"
    if [ -d "$src" ] && [ ! -L "$src" ]; then
        mv "$src" "$backup"
        echo "$backup"
    fi
}

# Run command on NAS via SSH
nas_run() {
    ssh "$NAS_SSH_HOST" "$@"
}

# Create directory on NAS
nas_mkdir() {
    local dir=$1
    nas_run "mkdir -p '$dir'"
}

# Check if directory exists on NAS
nas_dir_exists() {
    local dir=$1
    nas_run "[ -d '$dir' ]"
}

# Confirm action with user
confirm() {
    local message=$1
    local default=${2:-n}

    if [ "$default" = "y" ]; then
        local prompt="[Y/n]"
    else
        local prompt="[y/N]"
    fi

    echo -n "${YELLOW}$message${NC} $prompt "
    read response
    response=${response:-$default}

    [[ "$response" =~ ^[Yy]$ ]]
}

# Print a horizontal rule
hr() {
    printf '%*s\n' "${COLUMNS:-80}" '' | tr ' ' '─'
}

# Print a header
print_header() {
    local title=$1
    echo ""
    hr
    echo -e "${BOLD}${PURPLE}$title${NC}"
    hr
}

# Print key-value pair
print_kv() {
    local key=$1
    local value=$2
    local color=${3:-$NC}
    printf "  %-25s ${color}%s${NC}\n" "$key:" "$value"
}
