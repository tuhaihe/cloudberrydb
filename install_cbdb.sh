#!/bin/bash
#
# Apache Cloudberry (Incubating) Build & Install Script
#
# This script automates the process of building and installing Apache Cloudberry.
# It supports multiple modes:
#   1. build (default): Full source build and installation.
#   2. prepare: Only install system dependencies and configure user (for multi-node setups).
#   3. uninstall: Remove Cloudberry installation.
#
# Usage: ./install_cbdb.sh [options] [mode]
#
# For production deployments, consider using a configuration file:
#   ./install_cbdb.sh --config /path/to/config.yaml build
#

set -euo pipefail

# ----------------------------------------------------------------------
# Constants & Variables
# ----------------------------------------------------------------------
readonly SCRIPT_VERSION="2.0.0"
readonly SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
readonly ROOT_DIR="$SCRIPT_DIR"
readonly LOCK_FILE="/var/run/cloudberry_install.lock"
readonly DEFAULT_LOG_DIR="/var/log/cloudberry"
readonly DEFAULT_INSTALL_DIR="/usr/local/cloudberry-db"
readonly DEFAULT_GPADMIN_USER="gpadmin"

# Xerces-C configuration
readonly XERCES_VERSION="3.3.0"
readonly XERCES_SHA256="05a11f2f3739f3c3f89d6e4c8f61a4e7c9a0e3e5c8b7d6f5a4e3d2c1b0a9f8e7"  # Update with actual SHA256
readonly XERCES_URL="https://archive.apache.org/dist/xerces/c/3/sources/xerces-c-${XERCES_VERSION}.tar.gz"

# System limits constants
readonly NPROC_LIMIT=131072      # Max number of processes
readonly NOFILE_LIMIT=65536     # Max open files
readonly SHMMAX_BYTES=500000000 # Shared memory max (500MB)
readonly SHMALL_PAGES=4000000000 # Shared memory all pages

# Minimum requirements
readonly MIN_DISK_GB=20
readonly MIN_MEMORY_GB=4
readonly MIN_GCC_VERSION="7.0.0"
readonly MIN_PYTHON_VERSION="3.6"

# Runtime variables (will be set during execution)
LOG_DIR="$DEFAULT_LOG_DIR"
LOG_FILE=""
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
GPADMIN_USER="$DEFAULT_GPADMIN_USER"
GPADMIN_PASS=""
MODE="build"
INTERACTIVE=true
DRY_RUN=false
VERBOSE=false
QUIET=false
CONFIG_FILE=""
RESUME_FROM=""
OS_ID=""
OS_VERSION=""

# Colors (disabled if not a terminal)
if [[ -t 1 ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly NC='\033[0m'
else
    readonly RED=''
    readonly GREEN=''
    readonly YELLOW=''
    readonly BLUE=''
    readonly NC=''
fi

# Feature Flags (Defaults)
declare -A FEATURES=(
    [ORCA]=true
    [PXF]=true
    [GSSAPI]=false
    [LDAP]=false
    [XML]=true
    [LZ4]=true
    [ZSTD]=true
    [PAM]=true
    [PERL]=true
    [PYTHON]=true
    [ICU]=false
    [SELINUX]=false
    [SECCOMP]=false
    [SYSTEMD]=false
    [UUID]=false
    [XSLT]=false
    [PAX]=false
    [GPFDIST]=true
    [MAPREDUCE]=false
    [IC_PROXY]=false
    [DEBUG]=false
    [PYTHONSRC_EXT]=false
    [GPCLOUD]=false
    [EXTERNAL_FTS]=false
    [PRELOAD_IC_MODULE]=true
    [TCL]=false
    [SSL]=true
    [OPENSSL_REDIRECT]=false
    [DEPEND]=false
    [CASSERT]=false
    [PROFILING]=false
    [COVERAGE]=false
    [DTRACE]=false
    [TAP_TESTS]=false
    [SERVERLESS]=false
    [SHARED_POSTGRES_BACKEND]=true
    [LINK_POSTGRES_WITH_SHARED]=false
    [CATALOG_EXT]=false
)

# Completed steps tracking for resume functionality
declare -a COMPLETED_STEPS=()
readonly STEPS_FILE="/tmp/cloudberry_install_steps.$$"

# Allowed sudo commands for gpadmin (restricted)
readonly ALLOWED_SUDO_COMMANDS="/usr/bin/systemctl restart sshd, /usr/bin/systemctl reload sshd, /usr/bin/systemctl start sshd, /usr/bin/systemctl stop sshd, /sbin/sysctl -p, /bin/mkdir -p /data/*, /bin/chown -R ${DEFAULT_GPADMIN_USER}:${DEFAULT_GPADMIN_USER} /data/*"


# ----------------------------------------------------------------------
# Helper Functions
# ----------------------------------------------------------------------

# Logging functions with levels
_log() {
    local level="$1"
    local color="$2"
    local message="$3"
    local timestamp
    timestamp="$(date +'%Y-%m-%d %H:%M:%S')"
    
    # Always write to log file if available
    if [[ -n "${LOG_FILE:-}" ]] && [[ -w "$(dirname "$LOG_FILE")" ]]; then
        echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    fi
    
    # Console output based on verbosity
    if [[ "$QUIET" != true ]]; then
        if [[ "$level" == "DEBUG" ]] && [[ "$VERBOSE" != true ]]; then
            return
        fi
        echo -e "${color}[$level]${NC} $message"
    fi
}

log_debug() { _log "DEBUG" "$BLUE" "$1"; }
log_info() { _log "INFO" "$GREEN" "$1"; }
log_warn() { _log "WARN" "$YELLOW" "$1"; }
log_error() { _log "ERROR" "$RED" "$1"; }

fail() {
    log_error "$1"
    cleanup_on_failure
    exit 1
}

# Input sanitization
sanitize_path() {
    local input="$1"
    # Remove dangerous characters, allow only alphanumeric, /, -, _, .
    local sanitized
    sanitized=$(echo "$input" | sed 's/[^a-zA-Z0-9/_.-]//g')
    # Prevent path traversal
    sanitized=$(echo "$sanitized" | sed 's/\.\.\///g')
    # Ensure it starts with /
    if [[ ! "$sanitized" =~ ^/ ]]; then
        sanitized="/$sanitized"
    fi
    echo "$sanitized"
}

sanitize_username() {
    local input="$1"
    # Allow only alphanumeric and underscore, max 32 chars
    local sanitized
    sanitized=$(echo "$input" | sed 's/[^a-zA-Z0-9_]//g' | cut -c1-32)
    if [[ -z "$sanitized" ]]; then
        echo "$DEFAULT_GPADMIN_USER"
    else
        echo "$sanitized"
    fi
}

validate_password() {
    local pass="$1"
    if [[ ${#pass} -lt 8 ]]; then
        return 1
    fi
    # Check for at least one number and one letter
    if ! [[ "$pass" =~ [0-9] ]] || ! [[ "$pass" =~ [a-zA-Z] ]]; then
        return 1
    fi
    return 0
}

# Secure command execution (avoid eval)
# Output is shown to user by default for transparency
run_cmd() {
    local description="$1"
    shift
    local cmd=("$@")
    
    log_debug "Executing: ${cmd[*]}"
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would execute: ${cmd[*]}"
        return 0
    fi
    
    # Show output to user (with indentation for clarity)
    if [[ "$QUIET" == true ]]; then
        "${cmd[@]}" >> "$LOG_FILE" 2>&1
        return $?
    else
        # Pipe output with prefix for visual clarity, also log to file
        "${cmd[@]}" 2>&1 | while IFS= read -r line; do
            echo -e "    ${line}"
            echo "$line" >> "$LOG_FILE"
        done
        return "${PIPESTATUS[0]}"
    fi
}

# Enhanced command execution with header display
# Shows real-time output so users can see what's happening
run_with_header() {
    local step_name="$1"
    shift
    local cmd=("$@")
    
    echo ""
    echo -e "${BLUE}┌──────────────────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${BLUE}│${NC} ${GREEN}▶ $step_name${NC}"
    echo -e "${BLUE}│${NC} ${YELLOW}CMD:${NC} ${cmd[*]:0:70}..."
    echo -e "${BLUE}└──────────────────────────────────────────────────────────────────────────────┘${NC}"
    
    log_debug "Full command: ${cmd[*]}"
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would execute: ${cmd[*]}"
        return 0
    fi
    
    local exit_code=0
    local start_time
    start_time=$(date +%s)
    
    if [[ "$QUIET" == true ]]; then
        # Quiet mode: only log to file
        "${cmd[@]}" >> "$LOG_FILE" 2>&1
        exit_code=$?
    else
        # Show real-time output with indentation
        "${cmd[@]}" 2>&1 | while IFS= read -r line; do
            echo -e "    ${line}"
            echo "$line" >> "$LOG_FILE"
        done
        exit_code="${PIPESTATUS[0]}"
    fi
    
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    if [[ $exit_code -eq 0 ]]; then
        echo -e "${GREEN}✓ Completed: $step_name${NC} (${duration}s)"
    else
        log_error "Failed: $step_name (exit code: $exit_code)"
    fi
    
    return $exit_code
}

# Lock management
acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local pid
        pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            fail "Another installation is running (PID: $pid). If this is incorrect, remove $LOCK_FILE"
        fi
        log_warn "Stale lock file found, removing..."
        rm -f "$LOCK_FILE"
    fi
    echo $$ > "$LOCK_FILE"
    log_debug "Acquired lock: $LOCK_FILE"
}

release_lock() {
    rm -f "$LOCK_FILE" 2>/dev/null || true
    log_debug "Released lock"
}

# Cleanup functions
cleanup_on_failure() {
    log_warn "Cleaning up after failure..."
    release_lock
    
    # Save completed steps for resume
    if [[ ${#COMPLETED_STEPS[@]} -gt 0 ]]; then
        printf '%s\n' "${COMPLETED_STEPS[@]}" > "$STEPS_FILE"
        log_info "Progress saved. Resume with: $0 --resume $STEPS_FILE $MODE"
    fi
}

cleanup_on_success() {
    release_lock
    rm -f "$STEPS_FILE" 2>/dev/null || true
}

# Trap setup
setup_traps() {
    trap 'cleanup_on_failure; exit 1' INT TERM
    trap 'cleanup_on_success' EXIT
}

mark_step_complete() {
    local step="$1"
    COMPLETED_STEPS+=("$step")
    log_debug "Step completed: $step"
}

is_step_completed() {
    local step="$1"
    for completed in "${COMPLETED_STEPS[@]}"; do
        if [[ "$completed" == "$step" ]]; then
            return 0
        fi
    done
    return 1
}

load_resume_state() {
    local resume_file="$1"
    if [[ -f "$resume_file" ]]; then
        while IFS= read -r step; do
            COMPLETED_STEPS+=("$step")
        done < "$resume_file"
        log_info "Loaded ${#COMPLETED_STEPS[@]} completed steps from previous run"
    fi
}


# ----------------------------------------------------------------------
# Preflight Checks
# ----------------------------------------------------------------------

check_root() {
    if [[ $EUID -ne 0 ]]; then
        fail "This script must be run as root or with sudo."
    fi
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        OS_ID="$ID"
        OS_VERSION="$VERSION_ID"
    else
        fail "Cannot detect OS. /etc/os-release not found."
    fi
    
    # Validate supported OS
    case "$OS_ID" in
        centos|rhel|rocky|almalinux|ubuntu)
            log_info "Detected OS: $OS_ID $OS_VERSION"
            ;;
        *)
            fail "Unsupported OS: $OS_ID. Supported: centos, rhel, rocky, almalinux, ubuntu"
            ;;
    esac
}

check_disk_space() {
    local target_dir
    target_dir=$(dirname "$INSTALL_DIR")
    
    # Ensure target directory exists for df check
    if [[ ! -d "$target_dir" ]]; then
        target_dir="/"
    fi
    
    local available_gb
    available_gb=$(df -BG "$target_dir" | awk 'NR==2 {gsub(/G/,"",$4); print $4}')
    
    if [[ "$available_gb" -lt "$MIN_DISK_GB" ]]; then
        fail "Insufficient disk space. Required: ${MIN_DISK_GB}GB, Available: ${available_gb}GB"
    fi
    log_info "Disk space check passed: ${available_gb}GB available"
}

check_memory() {
    local total_mem_gb
    total_mem_gb=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)
    
    if [[ "$total_mem_gb" -lt "$MIN_MEMORY_GB" ]]; then
        fail "Insufficient memory. Required: ${MIN_MEMORY_GB}GB, Available: ${total_mem_gb}GB"
    fi
    log_info "Memory check passed: ${total_mem_gb}GB available"
}

check_network() {
    log_info "Checking network connectivity..."
    
    # Test connectivity to Apache archive
    if ! curl -s --connect-timeout 10 --head "https://archive.apache.org" > /dev/null 2>&1; then
        log_warn "Cannot reach archive.apache.org. Downloads may fail."
        if [[ "$INTERACTIVE" == true ]]; then
            read -rp "Continue anyway? [y/N] " choice
            if [[ ! "$choice" =~ ^[Yy]$ ]]; then
                fail "Aborted due to network issues"
            fi
        fi
    else
        log_info "Network connectivity check passed"
    fi
}

check_existing_installation() {
    if [[ -d "$INSTALL_DIR" ]] && [[ -f "$INSTALL_DIR/greenplum_path.sh" ]]; then
        log_warn "Existing Cloudberry installation found at $INSTALL_DIR"
        if [[ "$INTERACTIVE" == true ]]; then
            read -rp "Remove existing installation and continue? [y/N] " choice
            if [[ "$choice" =~ ^[Yy]$ ]]; then
                log_info "Removing existing installation..."
                rm -rf "$INSTALL_DIR"
            else
                fail "Aborted. Use --path to specify a different installation directory."
            fi
        else
            fail "Existing installation found. Use uninstall mode first or specify different --path"
        fi
    fi
}

check_port_availability() {
    local ports=(5432 22)  # PostgreSQL and SSH
    for port in "${ports[@]}"; do
        if ss -tuln | grep -q ":$port "; then
            log_warn "Port $port is already in use"
        fi
    done
}

version_compare() {
    # Returns 0 if $1 >= $2
    local v1="$1"
    local v2="$2"
    
    if [[ "$(printf '%s\n' "$v2" "$v1" | sort -V | head -n1)" == "$v2" ]]; then
        return 0
    fi
    return 1
}

check_gcc_version() {
    if ! command -v gcc &> /dev/null; then
        log_debug "GCC not installed yet, will be installed with dependencies"
        return 0
    fi
    
    local gcc_version
    gcc_version=$(gcc -dumpversion)
    
    if ! version_compare "$gcc_version" "$MIN_GCC_VERSION"; then
        fail "GCC version $gcc_version is too old. Required: >= $MIN_GCC_VERSION"
    fi
    log_info "GCC version check passed: $gcc_version"
}

check_python_version() {
    if ! command -v python3 &> /dev/null; then
        log_debug "Python3 not installed yet, will be installed with dependencies"
        return 0
    fi
    
    local python_version
    python_version=$(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:2])))')
    
    if ! version_compare "$python_version" "$MIN_PYTHON_VERSION"; then
        fail "Python version $python_version is too old. Required: >= $MIN_PYTHON_VERSION"
    fi
    log_info "Python version check passed: $python_version"
}

preflight_checks() {
    log_info "Running preflight checks..."
    
    if is_step_completed "preflight"; then
        log_info "Preflight checks already completed, skipping..."
        return 0
    fi
    
    check_root
    detect_os
    check_disk_space
    check_memory
    check_network
    check_existing_installation
    check_port_availability
    check_gcc_version
    check_python_version
    
    mark_step_complete "preflight"
    log_info "All preflight checks passed"
}


# ----------------------------------------------------------------------
# Configuration File Support
# ----------------------------------------------------------------------

load_config_file() {
    local config_file="$1"
    
    if [[ ! -f "$config_file" ]]; then
        fail "Configuration file not found: $config_file"
    fi
    
    log_info "Loading configuration from: $config_file"
    
    # Simple YAML-like parser (key: value format)
    while IFS=': ' read -r key value || [[ -n "$key" ]]; do
        # Skip comments and empty lines
        [[ "$key" =~ ^#.*$ ]] && continue
        [[ -z "$key" ]] && continue
        
        # Remove leading/trailing whitespace
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)
        
        case "$key" in
            install_dir)
                INSTALL_DIR=$(sanitize_path "$value")
                ;;
            gpadmin_user)
                GPADMIN_USER=$(sanitize_username "$value")
                ;;
            log_dir)
                LOG_DIR=$(sanitize_path "$value")
                ;;
            feature_*)
                local feature_name
                feature_name=$(echo "$key" | sed 's/feature_//' | tr '[:lower:]' '[:upper:]')
                # Check if feature exists in array (compatible with older bash)
                if [[ -n "${FEATURES[$feature_name]+x}" ]]; then
                    FEATURES[$feature_name]="$value"
                fi
                ;;
        esac
    done < "$config_file"
    
    log_info "Configuration loaded successfully"
}

generate_sample_config() {
    local output_file="${1:-cloudberry_config.yaml}"
    
    cat > "$output_file" << 'EOF'
# Apache Cloudberry Installation Configuration
# Generated by install_cbdb.sh

# Installation settings
install_dir: /usr/local/cloudberry-db
gpadmin_user: gpadmin
log_dir: /var/log/cloudberry

# Feature flags (true/false)
feature_orca: true
feature_pxf: true
feature_gssapi: false
feature_ldap: false
feature_xml: true
feature_lz4: true
feature_zstd: true
feature_pam: true
feature_perl: true
feature_python: true
feature_icu: false
feature_selinux: false
feature_seccomp: false
feature_systemd: false
feature_uuid: false
feature_xslt: false
feature_pax: false
feature_gpfdist: true
feature_mapreduce: false
feature_ic_proxy: false
feature_debug: false
feature_ssl: true
feature_tap_tests: false
feature_coverage: false

# Multi-node configuration (optional)
# coordinator_hostname: mdw
# segment_hostnames:
#   - sdw1
#   - sdw2
#   - sdw3
# segments_per_host: 4
# data_directory: /data
EOF
    
    log_info "Sample configuration written to: $output_file"
}


# ----------------------------------------------------------------------
# Feature Selection Menu
# ----------------------------------------------------------------------

# Feature descriptions for display
declare -A FEATURE_DESCRIPTIONS=(
    [ORCA]="Query Optimizer (GPORCA)"
    [PXF]="Platform Extension Framework"
    [GSSAPI]="Kerberos Authentication"
    [LDAP]="LDAP Authentication"
    [XML]="XML Support (libxml2)"
    [LZ4]="LZ4 Compression"
    [ZSTD]="ZSTD Compression"
    [PAM]="PAM Authentication"
    [PERL]="PL/Perl Language Support"
    [PYTHON]="PL/Python Language Support"
    [ICU]="ICU Unicode Support"
    [SELINUX]="SELinux Support"
    [SECCOMP]="Seccomp Sandboxing"
    [SYSTEMD]="Systemd Integration"
    [UUID]="UUID Support"
    [XSLT]="XSLT Support"
    [PAX]="PAX Storage Format"
    [GPFDIST]="gpfdist External Table Tool"
    [MAPREDUCE]="MapReduce Support"
    [IC_PROXY]="Interconnect Proxy"
    [DEBUG]="Debug Build (with assertions)"
    [PYTHONSRC_EXT]="Python Source Extensions"
    [GPCLOUD]="Cloud Storage Support"
    [EXTERNAL_FTS]="External Full-Text Search"
    [PRELOAD_IC_MODULE]="Preload Interconnect Module"
    [TCL]="PL/Tcl Language Support"
    [SSL]="SSL/TLS Support"
    [OPENSSL_REDIRECT]="OpenSSL Redirect"
    [DEPEND]="Dependency Tracking"
    [CASSERT]="C Assertions"
    [PROFILING]="Profiling Support"
    [COVERAGE]="Code Coverage"
    [DTRACE]="DTrace Support"
    [TAP_TESTS]="TAP Tests"
    [SERVERLESS]="Serverless Mode"
    [SHARED_POSTGRES_BACKEND]="Shared Postgres Backend"
    [LINK_POSTGRES_WITH_SHARED]="Link Postgres with Shared Libs"
    [CATALOG_EXT]="Catalog Extensions"
)

select_features() {
    if [[ "$INTERACTIVE" == false ]]; then
        return
    fi

    # Try whiptail first, fall back to numeric menu
    if command -v whiptail &> /dev/null; then
        select_features_whiptail
    else
        log_info "Whiptail not available. Using text-based menu."
        select_features_numeric
    fi
}

select_features_whiptail() {
    local options=()
    local sorted_features
    
    # Sort features for consistent display
    sorted_features=$(echo "${!FEATURES[@]}" | tr ' ' '\n' | sort)
    
    for feature in $sorted_features; do
        local status="OFF"
        [[ "${FEATURES[$feature]}" == "true" ]] && status="ON"
        local desc="${FEATURE_DESCRIPTIONS[$feature]:-$feature}"
        options+=("$feature" "$desc" "$status")
    done

    local selected
    selected=$(whiptail --title "Apache Cloudberry Build Configuration v${SCRIPT_VERSION}" \
        --checklist "Use SPACE to toggle, ARROW keys to navigate, ENTER to confirm:" \
        30 78 22 \
        "${options[@]}" \
        3>&1 1>&2 2>&3) || {
        log_info "Using default configuration."
        return
    }

    # Reset all features to false
    for feature in "${!FEATURES[@]}"; do
        FEATURES[$feature]=false
    done

    # Set selected features to true
    for feature in $selected; do
        feature=$(echo "$feature" | tr -d '"')
        # Check if feature exists in array (compatible with older bash)
        if [[ -n "${FEATURES[$feature]+x}" ]]; then
            FEATURES[$feature]=true
        fi
    done
}

select_features_numeric() {
    local sorted_features
    sorted_features=($(echo "${!FEATURES[@]}" | tr ' ' '\n' | sort))
    
    while true; do
        clear
        echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║${NC}     ${GREEN}Apache Cloudberry Build Configuration v${SCRIPT_VERSION}${NC}                    ${BLUE}║${NC}"
        echo -e "${BLUE}╠════════════════════════════════════════════════════════════════════════════╣${NC}"
        echo -e "${BLUE}║${NC} Enter number to toggle, 'a' for all, 'n' for none, Enter to confirm      ${BLUE}║${NC}"
        echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        
        local half=$(( (${#sorted_features[@]} + 1) / 2 ))
        for ((i=0; i<half; i++)); do
            local feature1="${sorted_features[$i]}"
            local mark1="[ ]"
            [[ "${FEATURES[$feature1]}" == "true" ]] && mark1="[${GREEN}x${NC}]"
            local idx1=$((i+1))
            
            local right_col=""
            local j=$((i + half))
            if [[ $j -lt ${#sorted_features[@]} ]]; then
                local feature2="${sorted_features[$j]}"
                local mark2="[ ]"
                [[ "${FEATURES[$feature2]}" == "true" ]] && mark2="[${GREEN}x${NC}]"
                local idx2=$((j+1))
                right_col=$(printf "%2d) %b %-12s" "$idx2" "$mark2" "$feature2")
            fi
            
            printf " %2d) %b %-14s │ %s\n" "$idx1" "$mark1" "$feature1" "$right_col"
        done
        
        echo ""
        echo -e "${BLUE}Installation Path:${NC} $INSTALL_DIR"
        echo "------------------------------------------------------------------------------"
        echo -ne "Select option: "
        
        read -r choice
        
        case "$choice" in
            "")
                break
                ;;
            [aA])
                for feature in "${!FEATURES[@]}"; do
                    FEATURES[$feature]=true
                done
                ;;
            [nN])
                for feature in "${!FEATURES[@]}"; do
                    FEATURES[$feature]=false
                done
                ;;
            *)
                if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#sorted_features[@]} ]]; then
                    local idx=$((choice - 1))
                    local feature="${sorted_features[$idx]}"
                    if [[ "${FEATURES[$feature]}" == "true" ]]; then
                        FEATURES[$feature]=false
                    else
                        FEATURES[$feature]=true
                    fi
                fi
                ;;
        esac
    done
    clear
}


# ----------------------------------------------------------------------
# Step 1: Install Dependencies
# ----------------------------------------------------------------------

install_dependencies() {
    if is_step_completed "dependencies"; then
        log_info "Dependencies already installed, skipping..."
        return 0
    fi
    
    log_info "Installing system dependencies..."
    
    local BASE_DEPS=()
    local FEATURE_DEPS=()
    
    if [[ "$OS_ID" =~ ^(centos|rhel|rocky|almalinux)$ ]]; then
        install_dependencies_rhel
    elif [[ "$OS_ID" == "ubuntu" ]]; then
        install_dependencies_ubuntu
    else
        fail "Unsupported OS: $OS_ID"
    fi
    
    mark_step_complete "dependencies"
    log_info "Dependencies installed successfully"
}

install_dependencies_rhel() {
    local MAJOR_VER
    MAJOR_VER=$(echo "$OS_VERSION" | cut -d. -f1)
    
    # Enable EPEL & CRB/PowerTools
    if ! rpm -q epel-release >/dev/null 2>&1; then
        run_with_header "Installing EPEL repository" dnf install -y epel-release
    fi
    
    if [[ "$MAJOR_VER" == "9" ]]; then
        run_cmd "Enable CRB" dnf config-manager --set-enabled crb || true
    elif [[ "$MAJOR_VER" == "8" ]]; then
        run_cmd "Enable PowerTools" dnf config-manager --set-enabled powertools || true
        run_cmd "Enable Devel" dnf config-manager --set-enabled devel || true
    fi

    # Base Dependencies
    local BASE_DEPS=(
        git gcc gcc-c++ make flex bison
        openssl-devel bzip2-devel readline-devel zlib-devel
        libevent-devel apr-devel libyaml-devel libuv-devel
        iproute net-tools wget tar sudo passwd openssh-clients openssh-server
        perl-IPC-Run perl-Test-Simple perl-Env perl-ExtUtils-Embed perl-core
        which rsync diffutils file jansson-devel curl
    )
    
    local FEATURE_DEPS=()
    
    # Feature-specific dependencies
    [[ "${FEATURES[ORCA]}" == "true" ]] && FEATURE_DEPS+=(xerces-c-devel)
    [[ "${FEATURES[PXF]}" == "true" ]] && FEATURE_DEPS+=(libcurl-devel)
    [[ "${FEATURES[GSSAPI]}" == "true" ]] && FEATURE_DEPS+=(krb5-devel)
    [[ "${FEATURES[LDAP]}" == "true" ]] && FEATURE_DEPS+=(openldap-devel)
    [[ "${FEATURES[XML]}" == "true" ]] && FEATURE_DEPS+=(libxml2-devel)
    [[ "${FEATURES[LZ4]}" == "true" ]] && FEATURE_DEPS+=(lz4-devel)
    [[ "${FEATURES[ZSTD]}" == "true" ]] && FEATURE_DEPS+=(libzstd-devel)
    [[ "${FEATURES[PAM]}" == "true" ]] && FEATURE_DEPS+=(pam-devel)
    [[ "${FEATURES[PERL]}" == "true" ]] && FEATURE_DEPS+=(perl-ExtUtils-Embed perl-core)
    [[ "${FEATURES[PYTHON]}" == "true" ]] && FEATURE_DEPS+=(python3-devel)
    [[ "${FEATURES[ICU]}" == "true" ]] && FEATURE_DEPS+=(libicu-devel)
    [[ "${FEATURES[SELINUX]}" == "true" ]] && FEATURE_DEPS+=(libselinux-devel)
    [[ "${FEATURES[SECCOMP]}" == "true" ]] && FEATURE_DEPS+=(libseccomp-devel)
    [[ "${FEATURES[SYSTEMD]}" == "true" ]] && FEATURE_DEPS+=(systemd-devel)
    [[ "${FEATURES[UUID]}" == "true" ]] && FEATURE_DEPS+=(libuuid-devel)
    [[ "${FEATURES[XSLT]}" == "true" ]] && FEATURE_DEPS+=(libxslt-devel)
    [[ "${FEATURES[GPFDIST]}" == "true" ]] && FEATURE_DEPS+=(libevent-devel apr-devel libyaml-devel)
    [[ "${FEATURES[PYTHONSRC_EXT]}" == "true" ]] && FEATURE_DEPS+=(python3-pip libcurl-devel)
    [[ "${FEATURES[GPCLOUD]}" == "true" ]] && FEATURE_DEPS+=(libcurl-devel libxml2-devel)
    [[ "${FEATURES[EXTERNAL_FTS]}" == "true" ]] && FEATURE_DEPS+=(jansson-devel)
    [[ "${FEATURES[IC_PROXY]}" == "true" ]] && FEATURE_DEPS+=(libuv-devel)
    [[ "${FEATURES[TCL]}" == "true" ]] && FEATURE_DEPS+=(tcl-devel)
    [[ "${FEATURES[SSL]}" == "true" ]] && FEATURE_DEPS+=(openssl-devel)
    [[ "${FEATURES[DTRACE]}" == "true" ]] && FEATURE_DEPS+=(systemtap-sdt-devel)
    [[ "${FEATURES[TAP_TESTS]}" == "true" ]] && FEATURE_DEPS+=(perl-IPC-Run)
    [[ "${FEATURES[PAX]}" == "true" ]] && FEATURE_DEPS+=(cmake3 protobuf-devel)
    [[ "${FEATURES[COVERAGE]}" == "true" ]] && FEATURE_DEPS+=(lcov)
    
    # Remove duplicates
    local all_deps
    all_deps=($(echo "${BASE_DEPS[@]}" "${FEATURE_DEPS[@]}" | tr ' ' '\n' | sort -u))
    
    run_with_header "Installing Dependencies (RHEL/Rocky/CentOS)" \
        dnf install -y "${all_deps[@]}"
}

install_dependencies_ubuntu() {
    run_cmd "Update apt cache" apt-get update
    
    local BASE_DEPS=(
        build-essential git flex bison
        libssl-dev libbz2-dev libreadline-dev zlib1g-dev
        libevent-dev libapr1-dev libyaml-dev libuv1-dev libjansson-dev
        iproute2 net-tools wget tar sudo openssh-client openssh-server
        rsync curl
    )
    
    local FEATURE_DEPS=()
    
    [[ "${FEATURES[ORCA]}" == "true" ]] && FEATURE_DEPS+=(libxerces-c-dev)
    [[ "${FEATURES[PXF]}" == "true" ]] && FEATURE_DEPS+=(libcurl4-openssl-dev)
    [[ "${FEATURES[GSSAPI]}" == "true" ]] && FEATURE_DEPS+=(libkrb5-dev)
    [[ "${FEATURES[LDAP]}" == "true" ]] && FEATURE_DEPS+=(libldap2-dev)
    [[ "${FEATURES[XML]}" == "true" ]] && FEATURE_DEPS+=(libxml2-dev)
    [[ "${FEATURES[LZ4]}" == "true" ]] && FEATURE_DEPS+=(liblz4-dev)
    [[ "${FEATURES[ZSTD]}" == "true" ]] && FEATURE_DEPS+=(libzstd-dev)
    [[ "${FEATURES[PAM]}" == "true" ]] && FEATURE_DEPS+=(libpam0g-dev)
    [[ "${FEATURES[PERL]}" == "true" ]] && FEATURE_DEPS+=(libperl-dev)
    [[ "${FEATURES[PYTHON]}" == "true" ]] && FEATURE_DEPS+=(python3-dev)
    [[ "${FEATURES[ICU]}" == "true" ]] && FEATURE_DEPS+=(libicu-dev)
    [[ "${FEATURES[SELINUX]}" == "true" ]] && FEATURE_DEPS+=(libselinux1-dev)
    [[ "${FEATURES[SECCOMP]}" == "true" ]] && FEATURE_DEPS+=(libseccomp-dev)
    [[ "${FEATURES[SYSTEMD]}" == "true" ]] && FEATURE_DEPS+=(libsystemd-dev)
    [[ "${FEATURES[UUID]}" == "true" ]] && FEATURE_DEPS+=(uuid-dev)
    [[ "${FEATURES[XSLT]}" == "true" ]] && FEATURE_DEPS+=(libxslt1-dev)
    [[ "${FEATURES[GPFDIST]}" == "true" ]] && FEATURE_DEPS+=(libevent-dev libapr1-dev libyaml-dev)
    [[ "${FEATURES[PYTHONSRC_EXT]}" == "true" ]] && FEATURE_DEPS+=(python3-pip libcurl4-openssl-dev)
    [[ "${FEATURES[GPCLOUD]}" == "true" ]] && FEATURE_DEPS+=(libcurl4-openssl-dev libxml2-dev)
    [[ "${FEATURES[EXTERNAL_FTS]}" == "true" ]] && FEATURE_DEPS+=(libjansson-dev)
    [[ "${FEATURES[IC_PROXY]}" == "true" ]] && FEATURE_DEPS+=(libuv1-dev)
    [[ "${FEATURES[TCL]}" == "true" ]] && FEATURE_DEPS+=(tcl-dev)
    [[ "${FEATURES[SSL]}" == "true" ]] && FEATURE_DEPS+=(libssl-dev)
    [[ "${FEATURES[DTRACE]}" == "true" ]] && FEATURE_DEPS+=(systemtap-sdt-dev)
    [[ "${FEATURES[TAP_TESTS]}" == "true" ]] && FEATURE_DEPS+=(libipc-run-perl)
    [[ "${FEATURES[PAX]}" == "true" ]] && FEATURE_DEPS+=(cmake libprotobuf-dev protobuf-compiler)
    [[ "${FEATURES[COVERAGE]}" == "true" ]] && FEATURE_DEPS+=(lcov)
    
    local all_deps
    all_deps=($(echo "${BASE_DEPS[@]}" "${FEATURE_DEPS[@]}" | tr ' ' '\n' | sort -u))
    
    run_with_header "Installing Dependencies (Ubuntu)" \
        apt-get install -y "${all_deps[@]}"
}


# ----------------------------------------------------------------------
# Step 2: User & System Setup
# ----------------------------------------------------------------------

setup_user_and_system() {
    if is_step_completed "user_setup"; then
        log_info "User setup already completed, skipping..."
        return 0
    fi
    
    log_info "Setting up user '$GPADMIN_USER' and system configuration..."

    # Create user if not exists
    if ! id "$GPADMIN_USER" &>/dev/null; then
        run_cmd "Create user $GPADMIN_USER" useradd -m -s /bin/bash "$GPADMIN_USER"
        
        # Set password
        if [[ -n "$GPADMIN_PASS" ]]; then
            echo "$GPADMIN_USER:$GPADMIN_PASS" | chpasswd
            log_info "Password set for $GPADMIN_USER"
        else
            log_warn "No password set for $GPADMIN_USER. Set one manually with: passwd $GPADMIN_USER"
        fi
    else
        log_info "User $GPADMIN_USER already exists"
    fi

    # Configure restricted sudo access
    setup_sudo_access
    
    # Configure system limits
    setup_system_limits
    
    # Configure kernel parameters
    setup_kernel_params
    
    # Setup SSH
    setup_ssh
    
    # Setup environment
    setup_environment
    
    mark_step_complete "user_setup"
    log_info "User and system setup complete"
}

setup_sudo_access() {
    log_info "Configuring restricted sudo access..."
    
    local sudoers_file="/etc/sudoers.d/90-cloudberry"
    
    cat > "$sudoers_file" << EOF
# Cloudberry Database sudo configuration
# Generated by install_cbdb.sh on $(date)
# 
# SECURITY NOTE: This provides limited sudo access for database operations only.
# Do NOT modify to add NOPASSWD: ALL

# Allow specific commands for database administration
$GPADMIN_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart sshd
$GPADMIN_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl reload sshd
$GPADMIN_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl start sshd
$GPADMIN_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop sshd
$GPADMIN_USER ALL=(ALL) NOPASSWD: /sbin/sysctl -p
$GPADMIN_USER ALL=(ALL) NOPASSWD: /bin/mkdir -p /data/*
$GPADMIN_USER ALL=(ALL) NOPASSWD: /bin/chown -R $GPADMIN_USER\:$GPADMIN_USER /data/*

# Allow reading system logs for troubleshooting
$GPADMIN_USER ALL=(ALL) NOPASSWD: /bin/journalctl -u cloudberry*
EOF
    
    chmod 440 "$sudoers_file"
    
    # Validate sudoers syntax
    if ! visudo -c -f "$sudoers_file" > /dev/null 2>&1; then
        rm -f "$sudoers_file"
        fail "Invalid sudoers configuration generated"
    fi
    
    log_info "Sudo access configured with restricted permissions"
}

setup_system_limits() {
    log_info "Configuring system limits..."
    
    cat > /etc/security/limits.d/90-cloudberry.conf << EOF
# Cloudberry Database system limits
# Generated by install_cbdb.sh on $(date)

# Core dump size (unlimited for debugging)
$GPADMIN_USER soft core unlimited
$GPADMIN_USER hard core unlimited

# Maximum number of processes
$GPADMIN_USER soft nproc $NPROC_LIMIT
$GPADMIN_USER hard nproc $NPROC_LIMIT

# Maximum number of open files
$GPADMIN_USER soft nofile $NOFILE_LIMIT
$GPADMIN_USER hard nofile $NOFILE_LIMIT

# Memory lock (unlimited for shared memory)
$GPADMIN_USER soft memlock unlimited
$GPADMIN_USER hard memlock unlimited

# Stack size
$GPADMIN_USER soft stack unlimited
$GPADMIN_USER hard stack unlimited
EOF
    
    log_info "System limits configured"
}

setup_kernel_params() {
    log_info "Configuring kernel parameters..."
    
    local sysctl_file="/etc/sysctl.d/90-cloudberry.conf"
    
    cat > "$sysctl_file" << EOF
# Cloudberry Database kernel parameters
# Generated by install_cbdb.sh on $(date)

# Shared Memory Settings
kernel.shmmax = $SHMMAX_BYTES
kernel.shmall = $SHMALL_PAGES
kernel.shmmni = 4096

# Semaphore Settings (SEMMSL, SEMMNS, SEMOPM, SEMMNI)
kernel.sem = 500 2048000 200 4096

# Memory Management
vm.overcommit_memory = 2
vm.overcommit_ratio = 95
vm.dirty_background_ratio = 3
vm.dirty_ratio = 10
vm.swappiness = 10
vm.zone_reclaim_mode = 0

# Network Settings
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.ip_local_port_range = 10000 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15

# IPC Settings
net.core.rmem_max = 2097152
net.core.wmem_max = 2097152
EOF
    
    # Apply sysctl settings
    if [[ "$DRY_RUN" != true ]]; then
        sysctl -p "$sysctl_file" >> "$LOG_FILE" 2>&1 || log_warn "Some sysctl settings may not have been applied"
    fi
    
    log_info "Kernel parameters configured"
}

setup_ssh() {
    log_info "Configuring SSH..."
    
    local ssh_dir="/home/$GPADMIN_USER/.ssh"
    
    # Create .ssh directory
    if [[ ! -d "$ssh_dir" ]]; then
        mkdir -p "$ssh_dir"
        chmod 700 "$ssh_dir"
        chown "$GPADMIN_USER:$GPADMIN_USER" "$ssh_dir"
    fi
    
    # Generate SSH keys if not exist
    if [[ ! -f "$ssh_dir/id_rsa" ]]; then
        log_info "Generating SSH keys..."
        sudo -u "$GPADMIN_USER" ssh-keygen -t rsa -b 4096 -N '' -f "$ssh_dir/id_rsa" -q
        
        # Setup authorized_keys
        cat "$ssh_dir/id_rsa.pub" >> "$ssh_dir/authorized_keys"
        chmod 600 "$ssh_dir/authorized_keys"
        chown "$GPADMIN_USER:$GPADMIN_USER" "$ssh_dir/authorized_keys"
        
        # Add localhost to known_hosts
        sudo -u "$GPADMIN_USER" ssh-keyscan -H localhost 127.0.0.1 >> "$ssh_dir/known_hosts" 2>/dev/null || true
        chmod 600 "$ssh_dir/known_hosts"
    fi
    
    # Configure SSH daemon for key-based auth (more secure than password)
    local sshd_config="/etc/ssh/sshd_config"
    local sshd_cloudberry="/etc/ssh/sshd_config.d/cloudberry.conf"
    
    # Use drop-in config if supported
    if [[ -d "/etc/ssh/sshd_config.d" ]]; then
        cat > "$sshd_cloudberry" << EOF
# Cloudberry SSH configuration
# Key-based authentication is preferred over password authentication
PubkeyAuthentication yes
# Uncomment below ONLY if password auth is required for initial setup
# PasswordAuthentication yes
EOF
    else
        # Ensure PubkeyAuthentication is enabled
        if ! grep -q "^PubkeyAuthentication yes" "$sshd_config"; then
            echo "PubkeyAuthentication yes" >> "$sshd_config"
        fi
    fi
    
    # Reload SSH if running
    if systemctl is-active sshd >/dev/null 2>&1; then
        systemctl reload sshd || true
    fi
    
    log_info "SSH configured"
}

setup_environment() {
    log_info "Setting up environment variables..."
    
    local profile_file="/home/$GPADMIN_USER/.bashrc"
    local env_marker="# Cloudberry Database Environment"
    
    # Check if already configured
    if grep -q "$env_marker" "$profile_file" 2>/dev/null; then
        log_info "Environment already configured in $profile_file"
        return 0
    fi
    
    cat >> "$profile_file" << EOF

$env_marker
# Added by install_cbdb.sh on $(date)
if [ -f "$INSTALL_DIR/greenplum_path.sh" ]; then
    source "$INSTALL_DIR/greenplum_path.sh"
fi

# Cloudberry recommended settings
export COORDINATOR_DATA_DIRECTORY=/data/coordinator/gpseg-1
export PGPORT=5432
export PGUSER=$GPADMIN_USER
export PGDATABASE=postgres

# Locale settings
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
EOF
    
    chown "$GPADMIN_USER:$GPADMIN_USER" "$profile_file"
    
    log_info "Environment variables configured"
}


# ----------------------------------------------------------------------
# Step 3: Xerces-C Installation (Only if ORCA is enabled)
# ----------------------------------------------------------------------

verify_checksum() {
    local file="$1"
    local expected_sha256="$2"
    
    if [[ -z "$expected_sha256" ]] || [[ "$expected_sha256" == "UPDATE_WITH_ACTUAL_SHA256" ]]; then
        log_warn "SHA256 checksum not configured, skipping verification"
        return 0
    fi
    
    local actual_sha256
    actual_sha256=$(sha256sum "$file" | awk '{print $1}')
    
    if [[ "$actual_sha256" != "$expected_sha256" ]]; then
        log_error "Checksum verification failed!"
        log_error "Expected: $expected_sha256"
        log_error "Actual:   $actual_sha256"
        return 1
    fi
    
    log_info "Checksum verification passed"
    return 0
}

install_xerces() {
    if [[ "${FEATURES[ORCA]}" != "true" ]]; then
        log_debug "ORCA disabled, skipping Xerces-C installation"
        return 0
    fi
    
    if is_step_completed "xerces"; then
        log_info "Xerces-C already installed, skipping..."
        return 0
    fi

    # For Ubuntu, use system package
    if [[ "$OS_ID" == "ubuntu" ]]; then
        log_info "Ubuntu detected - using system libxerces-c-dev package"
        if ! dpkg -l | grep -q libxerces-c-dev; then
            run_with_header "Installing system Xerces-C" \
                apt-get install -y libxerces-c-dev || fail "Failed to install libxerces-c-dev"
        fi
        mark_step_complete "xerces"
        return 0
    fi

    # For RHEL/CentOS/Rocky, check if already installed
    if [[ -f "/usr/local/xerces-c/lib/libxerces-c.so" ]]; then
        log_info "Xerces-C already installed at /usr/local/xerces-c"
        mark_step_complete "xerces"
        return 0
    fi

    log_info "Installing Xerces-C ${XERCES_VERSION} (required for ORCA)..."
    
    local tmp_dir
    tmp_dir=$(mktemp -d)
    
    # Cleanup on exit from this function
    trap "rm -rf '$tmp_dir'" RETURN
    
    cd "$tmp_dir"
    
    run_with_header "Downloading Xerces-C ${XERCES_VERSION}" \
        curl -fSL "$XERCES_URL" -o xerces-c.tar.gz || fail "Failed to download Xerces-C"
    
    # Verify checksum (update XERCES_SHA256 with actual value)
    # verify_checksum "xerces-c.tar.gz" "$XERCES_SHA256" || fail "Xerces-C checksum verification failed"
    
    run_with_header "Extracting Xerces-C" \
        tar xf xerces-c.tar.gz || fail "Failed to extract Xerces-C"
    
    cd "xerces-c-${XERCES_VERSION}"
    
    run_with_header "Configuring Xerces-C" \
        ./configure --prefix=/usr/local/xerces-c --disable-network || fail "Xerces-C configure failed"
    
    run_with_header "Building Xerces-C" \
        make -j"$(nproc)" || fail "Xerces-C build failed"
    
    run_with_header "Installing Xerces-C" \
        make install || fail "Xerces-C install failed"
    
    # Create symlink for Rocky 9
    if [[ "$OS_ID" =~ ^(rocky|rhel|almalinux)$ ]] && [[ "$OS_VERSION" =~ ^9 ]]; then
        cp /usr/local/xerces-c/lib/libxerces-c.so /usr/local/xerces-c/lib/libxerces-c-3.3.so 2>/dev/null || true
    fi
    
    cd "$SCRIPT_DIR"
    
    mark_step_complete "xerces"
    log_info "Xerces-C installed successfully"
}

# ----------------------------------------------------------------------
# Step 3.1: Prepare PAX Submodules (Only if PAX is enabled)
# ----------------------------------------------------------------------

prepare_pax_submodules() {
    if [[ "${FEATURES[PAX]}" != "true" ]]; then
        return 0
    fi
    
    if is_step_completed "pax_submodules"; then
        log_info "PAX submodules already prepared, skipping..."
        return 0
    fi

    log_info "Preparing PAX submodules..."
    
    if [[ ! -d ".git" ]]; then
        log_warn "Not a git repository. Skipping submodule update."
        return 0
    fi
    
    local PAX_SUBMODULES=(
        "contrib/pax_storage/src/cpp/contrib/googletest"
        "contrib/pax_storage/src/cpp/contrib/tabulate"
        "contrib/pax_storage/src/cpp/contrib/googlebench"
        "dependency/yyjson"
    )
    
    for sub in "${PAX_SUBMODULES[@]}"; do
        if [[ -d "$sub" ]]; then
            run_with_header "Updating PAX Submodule: $(basename "$sub")" \
                git submodule update --init --recursive "$sub" || log_warn "Failed to update submodule $sub"
        fi
    done
    
    mark_step_complete "pax_submodules"
    log_info "PAX submodules prepared"
}


# ----------------------------------------------------------------------
# Step 4: Build & Install
# ----------------------------------------------------------------------

build_configure_options() {
    local CONFIG_OPTS=()
    CONFIG_OPTS+=("--prefix=$INSTALL_DIR")
    
    # Include/lib paths based on OS
    if [[ "$OS_ID" == "ubuntu" ]] && [[ "${FEATURES[ORCA]}" == "true" ]]; then
        CONFIG_OPTS+=("--with-includes=/usr/include/xercesc")
        CONFIG_OPTS+=("--with-libs=/usr/lib/x86_64-linux-gnu")
    else
        CONFIG_OPTS+=("--with-includes=/usr/local/include")
        CONFIG_OPTS+=("--with-libs=/usr/local/lib")
    fi
    
    # Feature flags mapping
    [[ "${FEATURES[ORCA]}" == "true" ]] && CONFIG_OPTS+=("--enable-orca") || CONFIG_OPTS+=("--disable-orca")
    [[ "${FEATURES[PXF]}" == "true" ]] && CONFIG_OPTS+=("--enable-pxf") || CONFIG_OPTS+=("--disable-pxf")
    [[ "${FEATURES[GSSAPI]}" == "true" ]] && CONFIG_OPTS+=("--with-gssapi") || CONFIG_OPTS+=("--without-gssapi")
    [[ "${FEATURES[LDAP]}" == "true" ]] && CONFIG_OPTS+=("--with-ldap") || CONFIG_OPTS+=("--without-ldap")
    [[ "${FEATURES[XML]}" == "true" ]] && CONFIG_OPTS+=("--with-libxml") || CONFIG_OPTS+=("--without-libxml")
    [[ "${FEATURES[LZ4]}" == "true" ]] && CONFIG_OPTS+=("--with-lz4") || CONFIG_OPTS+=("--without-lz4")
    [[ "${FEATURES[ZSTD]}" == "true" ]] && CONFIG_OPTS+=("--with-zstd") || CONFIG_OPTS+=("--without-zstd")
    [[ "${FEATURES[PAM]}" == "true" ]] && CONFIG_OPTS+=("--with-pam") || CONFIG_OPTS+=("--without-pam")
    [[ "${FEATURES[PERL]}" == "true" ]] && CONFIG_OPTS+=("--with-perl") || CONFIG_OPTS+=("--without-perl")
    [[ "${FEATURES[PYTHON]}" == "true" ]] && CONFIG_OPTS+=("--with-python") || CONFIG_OPTS+=("--without-python")
    [[ "${FEATURES[ICU]}" == "true" ]] && CONFIG_OPTS+=("--with-icu") || CONFIG_OPTS+=("--without-icu")
    [[ "${FEATURES[SELINUX]}" == "true" ]] && CONFIG_OPTS+=("--with-selinux") || CONFIG_OPTS+=("--without-selinux")
    [[ "${FEATURES[SECCOMP]}" == "true" ]] && CONFIG_OPTS+=("--with-libseccomp") || CONFIG_OPTS+=("--without-libseccomp")
    [[ "${FEATURES[SYSTEMD]}" == "true" ]] && CONFIG_OPTS+=("--with-systemd") || CONFIG_OPTS+=("--without-systemd")
    [[ "${FEATURES[UUID]}" == "true" ]] && CONFIG_OPTS+=("--with-uuid=e2fs") || CONFIG_OPTS+=("--without-uuid")
    [[ "${FEATURES[XSLT]}" == "true" ]] && CONFIG_OPTS+=("--with-libxslt") || CONFIG_OPTS+=("--without-libxslt")
    [[ "${FEATURES[PAX]}" == "true" ]] && CONFIG_OPTS+=("--enable-pax") || CONFIG_OPTS+=("--disable-pax")
    [[ "${FEATURES[GPFDIST]}" == "true" ]] && CONFIG_OPTS+=("--enable-gpfdist") || CONFIG_OPTS+=("--disable-gpfdist")
    [[ "${FEATURES[MAPREDUCE]}" == "true" ]] && CONFIG_OPTS+=("--enable-mapreduce") || CONFIG_OPTS+=("--disable-mapreduce")
    [[ "${FEATURES[IC_PROXY]}" == "true" ]] && CONFIG_OPTS+=("--enable-ic-proxy") || CONFIG_OPTS+=("--disable-ic-proxy")
    
    # Debug build
    if [[ "${FEATURES[DEBUG]}" == "true" ]]; then
        CONFIG_OPTS+=("--enable-debug" "--enable-cassert")
    fi
    
    # Additional features
    [[ "${FEATURES[PYTHONSRC_EXT]}" == "true" ]] && CONFIG_OPTS+=("--with-pythonsrc-ext") || CONFIG_OPTS+=("--without-pythonsrc-ext")
    [[ "${FEATURES[GPCLOUD]}" == "true" ]] && CONFIG_OPTS+=("--enable-gpcloud") || CONFIG_OPTS+=("--disable-gpcloud")
    [[ "${FEATURES[EXTERNAL_FTS]}" == "true" ]] && CONFIG_OPTS+=("--enable-external-fts") || CONFIG_OPTS+=("--disable-external-fts")
    [[ "${FEATURES[PRELOAD_IC_MODULE]}" == "true" ]] && CONFIG_OPTS+=("--enable-preload-ic-module") || CONFIG_OPTS+=("--disable-preload-ic-module")
    [[ "${FEATURES[COVERAGE]}" == "true" ]] && CONFIG_OPTS+=("--enable-coverage") || CONFIG_OPTS+=("--disable-coverage")
    
    # TCL with config path detection
    if [[ "${FEATURES[TCL]}" == "true" ]]; then
        CONFIG_OPTS+=("--with-tcl")
        local tcl_config_path
        tcl_config_path=$(find /usr/lib* /usr/share -name tclConfig.sh 2>/dev/null | head -n 1)
        if [[ -n "$tcl_config_path" ]]; then
            CONFIG_OPTS+=("--with-tclconfig=$(dirname "$tcl_config_path")")
        fi
    else
        CONFIG_OPTS+=("--without-tcl")
    fi

    [[ "${FEATURES[SSL]}" == "true" ]] && CONFIG_OPTS+=("--with-ssl=openssl") || CONFIG_OPTS+=("--without-ssl")
    [[ "${FEATURES[OPENSSL_REDIRECT]}" == "true" ]] && CONFIG_OPTS+=("--enable-openssl-redirect")
    [[ "${FEATURES[DEPEND]}" == "true" ]] && CONFIG_OPTS+=("--enable-depend")
    [[ "${FEATURES[CASSERT]}" == "true" ]] && CONFIG_OPTS+=("--enable-cassert")
    [[ "${FEATURES[PROFILING]}" == "true" ]] && CONFIG_OPTS+=("--enable-profiling")
    [[ "${FEATURES[DTRACE]}" == "true" ]] && CONFIG_OPTS+=("--enable-dtrace")
    [[ "${FEATURES[TAP_TESTS]}" == "true" ]] && CONFIG_OPTS+=("--enable-tap-tests")
    [[ "${FEATURES[SERVERLESS]}" == "true" ]] && CONFIG_OPTS+=("--enable-serverless")
    [[ "${FEATURES[SHARED_POSTGRES_BACKEND]}" == "true" ]] && CONFIG_OPTS+=("--enable-shared-postgres-backend") || CONFIG_OPTS+=("--disable-shared-postgres-backend")
    [[ "${FEATURES[LINK_POSTGRES_WITH_SHARED]}" == "true" ]] && CONFIG_OPTS+=("--enable-link-postgres-with-shared") || CONFIG_OPTS+=("--disable-link-postgres-with-shared")
    [[ "${FEATURES[CATALOG_EXT]}" == "true" ]] && CONFIG_OPTS+=("--enable-catalog-ext") || CONFIG_OPTS+=("--disable-catalog-ext")

    echo "${CONFIG_OPTS[@]}"
}

prepare_install_directory() {
    log_info "Preparing installation directory..."
    
    # Remove existing installation if present
    if [[ -d "$INSTALL_DIR" ]]; then
        rm -rf "$INSTALL_DIR"
    fi
    
    # Create install directory
    mkdir -p "$INSTALL_DIR/lib"
    
    # Copy Xerces-C libraries for RHEL-based systems
    if [[ "$OS_ID" =~ ^(centos|rhel|rocky|almalinux)$ ]] && [[ "${FEATURES[ORCA]}" == "true" ]]; then
        if [[ -d "/usr/local/xerces-c/lib" ]]; then
            log_info "Copying Xerces-C libraries..."
            cp -v /usr/local/xerces-c/lib/libxerces-c*.so* "$INSTALL_DIR/lib/" 2>/dev/null || true
        fi
    fi
    
    # Set ownership
    chown -R "$GPADMIN_USER:$GPADMIN_USER" "$INSTALL_DIR"
    
    # Ensure /usr/local is writable for build
    chmod a+w /usr/local
}

build_and_install() {
    if is_step_completed "build"; then
        log_info "Build already completed, skipping..."
        return 0
    fi
    
    log_info "Starting build process..."
    
    # Verify we're in source directory
    if [[ ! -f "configure" ]]; then
        fail "Cannot find 'configure' script. Please run from source root directory."
    fi

    # Set source ownership
    log_info "Setting source directory ownership..."
    chown -R "$GPADMIN_USER:$GPADMIN_USER" .

    # Prepare installation directory
    prepare_install_directory

    # Build configure options
    local config_opts
    config_opts=$(build_configure_options)
    
    # Environment setup
    export CC=gcc
    export CXX=g++
    export LD_LIBRARY_PATH="/usr/local/xerces-c/lib:$INSTALL_DIR/lib:${LD_LIBRARY_PATH:-}"
    
    log_info "Configure options: $config_opts"
    
    # Run configure
    # shellcheck disable=SC2086
    run_with_header "Configuring Cloudberry" \
        ./configure $config_opts || fail "Configure failed. Check $LOG_FILE for details."

    mark_step_complete "configure"
    
    # Run make
    local nproc_count
    nproc_count=$(nproc)
    
    run_with_header "Building Cloudberry (make -j$nproc_count)" \
        sudo -u "$GPADMIN_USER" make -j"$nproc_count" || fail "Build failed. Check $LOG_FILE for details."

    mark_step_complete "make"
    
    # Run make install
    run_with_header "Installing Cloudberry" \
        sudo -u "$GPADMIN_USER" make install || fail "Installation failed. Check $LOG_FILE for details."

    mark_step_complete "install"
    
    # Build and install contrib modules
    run_with_header "Building Contrib Modules" \
        sudo -u "$GPADMIN_USER" make -C contrib -j"$nproc_count" install || fail "Contrib installation failed."

    mark_step_complete "contrib"
    mark_step_complete "build"
    
    log_info "Build and installation completed successfully!"
}


# ----------------------------------------------------------------------
# Step 5: Post-Installation Setup
# ----------------------------------------------------------------------

generate_gpinitsystem_config() {
    log_info "Generating gpinitsystem configuration template..."
    
    local config_dir="$INSTALL_DIR/docs/sample"
    mkdir -p "$config_dir"
    
    cat > "$config_dir/gpinitsystem_singlenode" << EOF
# Cloudberry Database Single Node Configuration
# Generated by install_cbdb.sh on $(date)
#
# Usage: gpinitsystem -c this_file -h hostfile

# Array of segment hosts (for single node, use coordinator)
declare -a DATA_DIRECTORY=(/data/primary /data/primary)

# Coordinator configuration
COORDINATOR_HOSTNAME=\$(hostname)
COORDINATOR_DIRECTORY=/data/coordinator
COORDINATOR_PORT=5432

# Segment configuration
PORT_BASE=6000
MIRROR_PORT_BASE=7000

# Database settings
DATABASE_NAME=gpadmin
ENCODING=UNICODE
EOF

    cat > "$config_dir/gpinitsystem_multinode" << EOF
# Cloudberry Database Multi-Node Configuration Template
# Generated by install_cbdb.sh on $(date)
#
# Usage: gpinitsystem -c this_file -h hostfile

# Array of data directories on each segment host
declare -a DATA_DIRECTORY=(/data/primary1 /data/primary2 /data/primary3 /data/primary4)

# Mirror directories (optional, for high availability)
declare -a MIRROR_DATA_DIRECTORY=(/data/mirror1 /data/mirror2 /data/mirror3 /data/mirror4)

# Coordinator configuration
COORDINATOR_HOSTNAME=mdw
COORDINATOR_DIRECTORY=/data/coordinator
COORDINATOR_PORT=5432

# Segment configuration
PORT_BASE=6000
MIRROR_PORT_BASE=7000

# Replication settings
MIRROR_REPLICATION_PORT_BASE=8000
REPLICATION_PORT_BASE=9000

# Database settings
DATABASE_NAME=gpadmin
ENCODING=UNICODE

# Checksums (recommended for production)
HEAP_CHECKSUM=on
EOF

    cat > "$config_dir/hostfile_singlenode" << EOF
# Single node hostfile
\$(hostname)
EOF

    cat > "$config_dir/hostfile_multinode_example" << EOF
# Multi-node hostfile example
# List all segment hosts, one per line
# mdw      # coordinator (optional in hostfile)
sdw1
sdw2
sdw3
sdw4
EOF

    chown -R "$GPADMIN_USER:$GPADMIN_USER" "$config_dir"
    
    log_info "Configuration templates created in $config_dir"
}

generate_systemd_service() {
    if [[ "${FEATURES[SYSTEMD]}" != "true" ]]; then
        return 0
    fi
    
    log_info "Generating systemd service file..."
    
    cat > /etc/systemd/system/cloudberry.service << EOF
[Unit]
Description=Apache Cloudberry Database
After=network.target

[Service]
Type=forking
User=$GPADMIN_USER
Group=$GPADMIN_USER
Environment="GPHOME=$INSTALL_DIR"
Environment="PATH=$INSTALL_DIR/bin:\$PATH"
Environment="LD_LIBRARY_PATH=$INSTALL_DIR/lib"
Environment="COORDINATOR_DATA_DIRECTORY=/data/coordinator/gpseg-1"

ExecStart=$INSTALL_DIR/bin/gpstart -a
ExecStop=$INSTALL_DIR/bin/gpstop -a -M fast
ExecReload=$INSTALL_DIR/bin/gpstop -u

TimeoutStartSec=300
TimeoutStopSec=300
Restart=on-failure
RestartSec=30

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/data $INSTALL_DIR/share

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    log_info "Systemd service created: cloudberry.service"
    log_info "Enable with: systemctl enable cloudberry"
}

generate_pg_hba_template() {
    log_info "Generating pg_hba.conf template..."
    
    local template_dir="$INSTALL_DIR/docs/sample"
    mkdir -p "$template_dir"
    
    cat > "$template_dir/pg_hba.conf.sample" << EOF
# Cloudberry Database pg_hba.conf Template
# Generated by install_cbdb.sh on $(date)
#
# TYPE  DATABASE        USER            ADDRESS                 METHOD

# Local connections
local   all             $GPADMIN_USER                           trust
local   all             all                                     md5

# IPv4 local connections
host    all             $GPADMIN_USER   127.0.0.1/32            trust
host    all             all             127.0.0.1/32            md5

# IPv4 segment host connections (adjust subnet as needed)
host    all             $GPADMIN_USER   10.0.0.0/8              trust
host    all             $GPADMIN_USER   192.168.0.0/16          trust

# Replication connections (for mirrors)
host    replication     $GPADMIN_USER   10.0.0.0/8              trust
host    replication     $GPADMIN_USER   192.168.0.0/16          trust

# Application connections (adjust as needed)
# host    mydb            myuser          192.168.1.0/24          md5

# Reject all other connections
host    all             all             0.0.0.0/0               reject
EOF

    chown "$GPADMIN_USER:$GPADMIN_USER" "$template_dir/pg_hba.conf.sample"
    log_info "pg_hba.conf template created"
}

generate_postgresql_conf_template() {
    log_info "Generating postgresql.conf recommendations..."
    
    local template_dir="$INSTALL_DIR/docs/sample"
    mkdir -p "$template_dir"
    
    # Calculate recommended settings based on system resources
    local total_mem_kb
    total_mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    local total_mem_mb=$((total_mem_kb / 1024))
    local shared_buffers_mb=$((total_mem_mb / 4))  # 25% of RAM
    local effective_cache_mb=$((total_mem_mb * 3 / 4))  # 75% of RAM
    
    cat > "$template_dir/postgresql.conf.recommendations" << EOF
# Cloudberry Database postgresql.conf Recommendations
# Generated by install_cbdb.sh on $(date)
# System: $(nproc) CPUs, ${total_mem_mb}MB RAM
#
# These are recommendations - adjust based on workload

# Memory Settings
shared_buffers = ${shared_buffers_mb}MB
effective_cache_size = ${effective_cache_mb}MB
work_mem = 64MB
maintenance_work_mem = 512MB

# Checkpoint Settings
checkpoint_completion_target = 0.9
checkpoint_timeout = 15min
max_wal_size = 4GB
min_wal_size = 1GB

# Query Planning
random_page_cost = 1.1  # For SSD storage
effective_io_concurrency = 200  # For SSD storage

# Logging
log_destination = 'stderr'
logging_collector = on
log_directory = 'pg_log'
log_filename = 'gpdb-%Y-%m-%d_%H%M%S.log'
log_rotation_age = 1d
log_rotation_size = 100MB
log_min_duration_statement = 1000  # Log queries > 1 second
log_line_prefix = '%t [%p]: [%l-1] user=%u,db=%d,app=%a '

# Connection Settings
max_connections = 250
max_prepared_transactions = 250

# Resource Management
gp_vmem_protect_limit = $((total_mem_mb * 80 / 100))  # 80% of RAM per segment
gp_resource_manager = 'group'

# Compression (if enabled)
# gp_default_storage_options = 'compresstype=zstd,compresslevel=1'
EOF

    chown "$GPADMIN_USER:$GPADMIN_USER" "$template_dir/postgresql.conf.recommendations"
    log_info "postgresql.conf recommendations created"
}

post_install_setup() {
    if is_step_completed "post_install"; then
        log_info "Post-installation already completed, skipping..."
        return 0
    fi
    
    log_info "Running post-installation setup..."
    
    generate_gpinitsystem_config
    generate_systemd_service
    generate_pg_hba_template
    generate_postgresql_conf_template
    
    # Create data directories
    log_info "Creating data directories..."
    mkdir -p /data/{coordinator,primary,mirror}
    chown -R "$GPADMIN_USER:$GPADMIN_USER" /data
    chmod 700 /data/{coordinator,primary,mirror}
    
    mark_step_complete "post_install"
    log_info "Post-installation setup completed"
}


# ----------------------------------------------------------------------
# Uninstall Function
# ----------------------------------------------------------------------

uninstall_cloudberry() {
    log_info "Uninstalling Apache Cloudberry..."
    
    # Check if installation exists
    if [[ ! -d "$INSTALL_DIR" ]]; then
        log_warn "Installation directory not found: $INSTALL_DIR"
    fi
    
    # Stop database if running
    if [[ -f "$INSTALL_DIR/greenplum_path.sh" ]]; then
        log_info "Attempting to stop database..."
        sudo -u "$GPADMIN_USER" bash -c "source $INSTALL_DIR/greenplum_path.sh && gpstop -a -M fast" 2>/dev/null || true
    fi
    
    # Stop systemd service if exists
    if [[ -f /etc/systemd/system/cloudberry.service ]]; then
        systemctl stop cloudberry 2>/dev/null || true
        systemctl disable cloudberry 2>/dev/null || true
        rm -f /etc/systemd/system/cloudberry.service
        systemctl daemon-reload
    fi
    
    # Confirm removal
    if [[ "$INTERACTIVE" == true ]]; then
        echo ""
        echo "This will remove:"
        echo "  - Installation directory: $INSTALL_DIR"
        echo "  - System configuration files"
        echo ""
        echo "This will NOT remove:"
        echo "  - User '$GPADMIN_USER'"
        echo "  - Data directories (/data)"
        echo "  - Xerces-C installation"
        echo ""
        read -rp "Continue with uninstallation? [y/N] " choice
        if [[ ! "$choice" =~ ^[Yy]$ ]]; then
            log_info "Uninstallation cancelled"
            return 0
        fi
    fi
    
    # Remove installation directory
    if [[ -d "$INSTALL_DIR" ]]; then
        log_info "Removing installation directory..."
        rm -rf "$INSTALL_DIR"
    fi
    
    # Remove configuration files
    log_info "Removing configuration files..."
    rm -f /etc/security/limits.d/90-cloudberry.conf
    rm -f /etc/sysctl.d/90-cloudberry.conf
    rm -f /etc/sudoers.d/90-cloudberry
    rm -f /etc/ssh/sshd_config.d/cloudberry.conf 2>/dev/null || true
    
    # Remove environment from bashrc
    if [[ -f "/home/$GPADMIN_USER/.bashrc" ]]; then
        sed -i '/# Cloudberry Database Environment/,/^$/d' "/home/$GPADMIN_USER/.bashrc"
    fi
    
    log_info "Uninstallation completed"
    log_info "Note: User '$GPADMIN_USER' and data directories were preserved"
    log_info "To remove user: userdel -r $GPADMIN_USER"
    log_info "To remove data: rm -rf /data"
}

# ----------------------------------------------------------------------
# Usage & Help
# ----------------------------------------------------------------------

usage() {
    cat << EOF
Apache Cloudberry Build & Install Script v${SCRIPT_VERSION}

Usage: $0 [options] [mode]

Modes:
  build      (Default) Full source build and installation
  prepare    Only install dependencies and configure system
  uninstall  Remove Cloudberry installation

Options:
  -p, --path <path>       Installation path (default: $DEFAULT_INSTALL_DIR)
  -u, --user <user>       Admin username (default: $DEFAULT_GPADMIN_USER)
  -c, --config <file>     Load configuration from file
  -y, --yes               Non-interactive mode (accept defaults)
  -n, --dry-run           Show what would be done without making changes
  -v, --verbose           Verbose output
  -q, --quiet             Minimal output
  --resume <file>         Resume from previous interrupted installation
  --generate-config       Generate sample configuration file and exit
  -h, --help              Show this help message
  --version               Show version information

Feature Flags (can be set via config file or environment):
  FEATURE_ORCA=true|false           Query optimizer (default: true)
  FEATURE_PXF=true|false            Platform Extension Framework (default: true)
  FEATURE_DEBUG=true|false          Debug build (default: false)
  ... and many more (see generated config file)

Examples:
  # Interactive installation with defaults
  sudo $0 build

  # Non-interactive installation
  sudo $0 -y -p /opt/cloudberry build

  # Prepare nodes for multi-node cluster
  sudo $0 -y prepare

  # Generate configuration file
  $0 --generate-config

  # Install using configuration file
  sudo $0 -c cloudberry_config.yaml build

  # Resume interrupted installation
  sudo $0 --resume /tmp/cloudberry_install_steps.12345 build

For more information, visit: https://cloudberry.apache.org/docs
EOF
}

show_version() {
    echo "Apache Cloudberry Install Script v${SCRIPT_VERSION}"
}


# ----------------------------------------------------------------------
# Interactive Setup
# ----------------------------------------------------------------------

setup_variables_interactive() {
    if [[ "$INTERACTIVE" != true ]]; then
        return
    fi
    
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}     ${GREEN}Apache Cloudberry Installation Setup${NC}                                ${BLUE}║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Installation directory
    read -rp "Installation directory [$INSTALL_DIR]: " input
    if [[ -n "$input" ]]; then
        INSTALL_DIR=$(sanitize_path "$input")
    fi
    
    # Admin username
    read -rp "Admin username [$GPADMIN_USER]: " input
    if [[ -n "$input" ]]; then
        GPADMIN_USER=$(sanitize_username "$input")
    fi
    
    # Password (only if user doesn't exist)
    if ! id "$GPADMIN_USER" &>/dev/null; then
        while true; do
            read -rsp "Password for $GPADMIN_USER (min 8 chars, letters+numbers): " GPADMIN_PASS
            echo ""
            
            if [[ -z "$GPADMIN_PASS" ]]; then
                log_warn "No password provided. You will need to set it manually later."
                break
            fi
            
            if validate_password "$GPADMIN_PASS"; then
                read -rsp "Confirm password: " pass_confirm
                echo ""
                if [[ "$GPADMIN_PASS" == "$pass_confirm" ]]; then
                    break
                else
                    echo "Passwords do not match. Try again."
                fi
            else
                echo "Password must be at least 8 characters with letters and numbers."
            fi
        done
    fi
    
    echo ""
}

# ----------------------------------------------------------------------
# Main Execution
# ----------------------------------------------------------------------

main() {
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--path)
                INSTALL_DIR=$(sanitize_path "$2")
                shift 2
                ;;
            -u|--user)
                GPADMIN_USER=$(sanitize_username "$2")
                shift 2
                ;;
            -c|--config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            -y|--yes)
                INTERACTIVE=false
                shift
                ;;
            -n|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -q|--quiet)
                QUIET=true
                shift
                ;;
            --resume)
                RESUME_FROM="$2"
                shift 2
                ;;
            --generate-config)
                generate_sample_config
                exit 0
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --version)
                show_version
                exit 0
                ;;
            build|prepare|uninstall)
                MODE="$1"
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
    
    # Setup logging
    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/install_$(date +%Y%m%d_%H%M%S).log"
    
    log_info "Apache Cloudberry Install Script v${SCRIPT_VERSION}"
    log_info "Mode: $MODE"
    log_info "Log file: $LOG_FILE"
    
    # Load configuration file if specified
    if [[ -n "$CONFIG_FILE" ]]; then
        load_config_file "$CONFIG_FILE"
    fi
    
    # Load resume state if specified
    if [[ -n "$RESUME_FROM" ]]; then
        load_resume_state "$RESUME_FROM"
    fi
    
    # Setup traps for cleanup
    setup_traps
    
    # Acquire lock to prevent concurrent runs
    acquire_lock
    
    # Execute based on mode
    case "$MODE" in
        build)
            preflight_checks
            setup_variables_interactive
            select_features
            install_dependencies
            setup_user_and_system
            install_xerces
            prepare_pax_submodules
            build_and_install
            post_install_setup
            
            echo ""
            echo -e "${GREEN}╔════════════════════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${GREEN}║${NC}     Installation Completed Successfully!                                  ${GREEN}║${NC}"
            echo -e "${GREEN}╚════════════════════════════════════════════════════════════════════════════╝${NC}"
            echo ""
            echo "Installation path: $INSTALL_DIR"
            echo "Admin user: $GPADMIN_USER"
            echo "Log file: $LOG_FILE"
            echo ""
            echo "Next steps:"
            echo "  1. Switch to $GPADMIN_USER: su - $GPADMIN_USER"
            echo "  2. Source environment: source $INSTALL_DIR/greenplum_path.sh"
            echo "  3. Initialize cluster: gpinitsystem -c <config_file> -h <hostfile>"
            echo ""
            echo "Sample configurations available in: $INSTALL_DIR/docs/sample/"
            echo ""
            ;;
        prepare)
            preflight_checks
            setup_variables_interactive
            select_features
            install_dependencies
            setup_user_and_system
            
            echo ""
            log_info "Preparation completed successfully!"
            log_info "This node is ready for Cloudberry installation."
            echo ""
            ;;
        uninstall)
            uninstall_cloudberry
            ;;
        *)
            log_error "Invalid mode: $MODE"
            usage
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
