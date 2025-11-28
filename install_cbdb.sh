#!/bin/bash
#
# Apache Cloudberry (Incubating) Build & Install Script
#
# This script automates the process of building and installing Apache Cloudberry.
# It supports two modes:
#   1. build (default): Full source build and installation.
#   2. prepare: Only install system dependencies and configure user (for multi-node setups).
#
# Usage: ./install_cbdb.sh [options] [mode]
#

set -e

# ----------------------------------------------------------------------
# Constants & Variables
# ----------------------------------------------------------------------
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$SCRIPT_DIR"
LOG_FILE="install_cbdb.log"
INSTALL_DIR="/usr/local/cloudberry-db"
GPADMIN_USER="gpadmin"
GPADMIN_PASS="changeme" # Default password, should be changed
MODE="build"
INTERACTIVE=true

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Feature Flags (Defaults)
FEATURE_ORCA=true
FEATURE_PXF=true
FEATURE_GSSAPI=false
FEATURE_LDAP=false
FEATURE_XML=true
FEATURE_LZ4=true
FEATURE_ZSTD=true
FEATURE_PAM=true
FEATURE_PERL=true
FEATURE_PYTHON=true
FEATURE_ICU=false
FEATURE_SELINUX=false
FEATURE_SECCOMP=false
FEATURE_SYSTEMD=false
FEATURE_UUID=false
FEATURE_XSLT=false
FEATURE_PAX=false
FEATURE_GPFDIST=true
FEATURE_MAPREDUCE=false
FEATURE_IC_PROXY=false
FEATURE_DEBUG=false

# New Comprehensive Options
FEATURE_PYTHONSRC_EXT=false
FEATURE_GPCLOUD=false
FEATURE_EXTERNAL_FTS=false
FEATURE_PRELOAD_IC_MODULE=true
FEATURE_TCL=false
FEATURE_SSL=true
FEATURE_OPENSSL_REDIRECT=false
FEATURE_DEPEND=false
FEATURE_CASSERT=false
FEATURE_PROFILING=false
FEATURE_COVERAGE=false
FEATURE_DTRACE=false
FEATURE_TAP_TESTS=false
FEATURE_SERVERLESS=false
FEATURE_SHARED_POSTGRES_BACKEND=true
FEATURE_LINK_POSTGRES_WITH_SHARED=false
FEATURE_CATALOG_EXT=false

# ----------------------------------------------------------------------
# Helper Functions
# ----------------------------------------------------------------------
log() {
    echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

info() {
    log "${GREEN}INFO: $1${NC}"
}

warn() {
    log "${YELLOW}WARN: $1${NC}"
}

error() {
    log "${RED}ERROR: $1${NC}"
}

fail() {
    error "$1"
    exit 1
}

# Enhanced command execution with fixed header and scrolling output
run_with_header() {
    local step_name="$1"
    local cmd="$2"
    local log_to_file="${3:-true}"
    
    # Check if tput is available for advanced terminal control
    if ! command -v tput &> /dev/null; then
        echo "STEP: $step_name"
        echo "CMD: $cmd"
        if [ "$log_to_file" = true ]; then
            eval "$cmd" 2>&1 | tee -a "$LOG_FILE"
            return ${PIPESTATUS[0]}
        else
            eval "$cmd"
            return $?
        fi
    fi

    # Calculate dimensions
    local term_lines=$(tput lines)
    local header_height=6
    local scroll_start=$((header_height))
    local scroll_end=$((term_lines - 1))

    # Save cursor and clear screen
    tput smcup
    clear

    # Draw Fixed Header
    tput cup 0 0
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC} ${GREEN}STEP:${NC} $step_name"
    # Truncate command if too long
        local display_cmd="${cmd:0:60}"
        [ "${#cmd}" -gt 60 ] && display_cmd="${display_cmd}..."
        echo -e "${BLUE}║${NC} ${GREEN}CMD:${NC} $display_cmd"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Set scrolling region (from line 6 to bottom)
    tput csr $scroll_start $scroll_end
    
    # Move cursor to start of scrolling region
    tput cup $scroll_start 0

    # Ensure we reset terminal on exit/interrupt
    trap 'tput csr 0 $(($(tput lines) - 1)); tput rmcup; exit 1' INT TERM

    # Execute command
    local exit_code=0
    if [ "$log_to_file" = true ]; then
        # We don't use the prefix anymore as it might clutter the "docker-like" clean look,
        # or we can keep it. Let's keep it simple.
        eval "$cmd" 2>&1 | tee -a "$LOG_FILE"
        exit_code=${PIPESTATUS[0]}
    else
        eval "$cmd"
        exit_code=$?
    fi

    # Reset scrolling region
    tput csr 0 $(($(tput lines) - 1))
    
    # Restore screen (optional, maybe we want to keep the output?)
    # tput rmcup # This would clear the output, which user might not want.
    # Instead of rmcup, we just leave the output there but reset scrolling.
    # However, we used smcup at start, which switches to alternate screen.
    # If we want to keep output, we shouldn't use smcup/rmcup.
    # But if we don't use smcup, we overwrite previous history.
    # "Docker build" usually keeps history.
    
    # Let's NOT use smcup/rmcup to persist output, but we must be careful.
    # If we don't use smcup, we just clear screen.
    
    # Reset trap
    trap - INT TERM
    
    return $exit_code
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        fail "This script must be run as root or with sudo."
    fi
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID=$ID
        OS_VERSION=$VERSION_ID
    else
        fail "Cannot detect OS. /etc/os-release not found."
    fi
    info "Detected OS: $OS_ID $OS_VERSION"
}

usage() {
    echo "Usage: $0 [options] [mode]"
    echo ""
    echo "Modes:"
    echo "  build    (Default) Full source build and installation."
    echo "  prepare  Only install system dependencies and configure user."
    echo ""
    echo "Options:"
    echo "  -p, --path <path>    Installation path (default: /usr/local/cloudberry-db)"
    echo "  -y, --yes            Non-interactive mode (accept defaults)"
    echo "  -h, --help           Show this help message"
    echo ""
}

# ----------------------------------------------------------------------
# Feature Selection Menu
# ----------------------------------------------------------------------
select_features() {
    if [ "$INTERACTIVE" = false ]; then
        return
    fi

    # Check if whiptail is available
    if ! command -v whiptail &> /dev/null; then
        echo ""
        echo -e "${YELLOW}Whiptail is not installed. It provides a better graphical menu experience.${NC}"
        read -p "Do you want to install it now? [Y/n] " choice
        choice=${choice:-Y}
        
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            info "Installing whiptail..."
            if [[ "$OS_ID" =~ ^(centos|rhel|rocky|almalinux)$ ]]; then
                run_with_header "Installing whiptail" "dnf install -y newt" false
            elif [[ "$OS_ID" == "ubuntu" ]]; then
                run_with_header "Installing whiptail" "apt-get update && apt-get install -y whiptail" false
            fi
            
            # After installation, check again and use whiptail if available
            if command -v whiptail &> /dev/null; then
                select_features_whiptail
                return
            else
                warn "Whiptail installation failed, falling back to text menu"
            fi
        fi
    fi

    # Try to use whiptail if available
    if command -v whiptail &> /dev/null; then
        select_features_whiptail
    else
        info "Whiptail not available. Using standard menu."
        select_features_numeric
    fi
}

select_features_whiptail() {
    # Build checklist options (tag "description" status)
    local options=()
    options+=("ORCA" "Query Optimizer" "$([ "$FEATURE_ORCA" = true ] && echo "ON" || echo "OFF")")
    options+=("PXF" "Platform Extension Framework" "$([ "$FEATURE_PXF" = true ] && echo "ON" || echo "OFF")")
    options+=("GSSAPI" "Kerberos Authentication" "$([ "$FEATURE_GSSAPI" = true ] && echo "ON" || echo "OFF")")
    options+=("LDAP" "LDAP Authentication" "$([ "$FEATURE_LDAP" = true ] && echo "ON" || echo "OFF")")
    options+=("XML" "XML Support" "$([ "$FEATURE_XML" = true ] && echo "ON" || echo "OFF")")
    options+=("LZ4" "LZ4 Compression" "$([ "$FEATURE_LZ4" = true ] && echo "ON" || echo "OFF")")
    options+=("ZSTD" "ZSTD Compression" "$([ "$FEATURE_ZSTD" = true ] && echo "ON" || echo "OFF")")
    options+=("PAM" "PAM Authentication" "$([ "$FEATURE_PAM" = true ] && echo "ON" || echo "OFF")")
    options+=("PERL" "Perl Language Support" "$([ "$FEATURE_PERL" = true ] && echo "ON" || echo "OFF")")
    options+=("PYTHON" "Python Language Support" "$([ "$FEATURE_PYTHON" = true ] && echo "ON" || echo "OFF")")
    options+=("ICU" "ICU (Unicode)" "$([ "$FEATURE_ICU" = true ] && echo "ON" || echo "OFF")")
    options+=("SELINUX" "SELinux Support" "$([ "$FEATURE_SELINUX" = true ] && echo "ON" || echo "OFF")")
    options+=("SECCOMP" "Seccomp Support" "$([ "$FEATURE_SECCOMP" = true ] && echo "ON" || echo "OFF")")
    options+=("SYSTEMD" "Systemd Support" "$([ "$FEATURE_SYSTEMD" = true ] && echo "ON" || echo "OFF")")
    options+=("UUID" "UUID Support" "$([ "$FEATURE_UUID" = true ] && echo "ON" || echo "OFF")")
    options+=("XSLT" "XSLT Support" "$([ "$FEATURE_XSLT" = true ] && echo "ON" || echo "OFF")")
    options+=("PAX" "PAX Storage Format" "$([ "$FEATURE_PAX" = true ] && echo "ON" || echo "OFF")")
    options+=("GPFDIST" "gpfdist Tool" "$([ "$FEATURE_GPFDIST" = true ] && echo "ON" || echo "OFF")")
    options+=("MAPREDUCE" "MapReduce Support" "$([ "$FEATURE_MAPREDUCE" = true ] && echo "ON" || echo "OFF")")
    options+=("IC_PROXY" "Interconnect Proxy" "$([ "$FEATURE_IC_PROXY" = true ] && echo "ON" || echo "OFF")")
    options+=("DEBUG" "Debug Build" "$([ "$FEATURE_DEBUG" = true ] && echo "ON" || echo "OFF")")
    options+=("PYTHONSRC_EXT" "Python Source Extensions" "$([ "$FEATURE_PYTHONSRC_EXT" = true ] && echo "ON" || echo "OFF")")
    options+=("GPCLOUD" "GPCloud Support" "$([ "$FEATURE_GPCLOUD" = true ] && echo "ON" || echo "OFF")")
    options+=("EXTERNAL_FTS" "External FTS" "$([ "$FEATURE_EXTERNAL_FTS" = true ] && echo "ON" || echo "OFF")")
    options+=("PRELOAD_IC_MODULE" "Preload Interconnect Module" "$([ "$FEATURE_PRELOAD_IC_MODULE" = true ] && echo "ON" || echo "OFF")")
    options+=("TCL" "Tcl Language Support" "$([ "$FEATURE_TCL" = true ] && echo "ON" || echo "OFF")")
    options+=("SSL" "SSL Support" "$([ "$FEATURE_SSL" = true ] && echo "ON" || echo "OFF")")
    options+=("OPENSSL_REDIRECT" "OpenSSL Redirect" "$([ "$FEATURE_OPENSSL_REDIRECT" = true ] && echo "ON" || echo "OFF")")
    options+=("DEPEND" "Dependency Tracking" "$([ "$FEATURE_DEPEND" = true ] && echo "ON" || echo "OFF")")
    options+=("CASSERT" "C Assertions" "$([ "$FEATURE_CASSERT" = true ] && echo "ON" || echo "OFF")")
    options+=("PROFILING" "Profiling" "$([ "$FEATURE_PROFILING" = true ] && echo "ON" || echo "OFF")")
    options+=("COVERAGE" "Coverage" "$([ "$FEATURE_COVERAGE" = true ] && echo "ON" || echo "OFF")")
    options+=("DTRACE" "DTrace Support" "$([ "$FEATURE_DTRACE" = true ] && echo "ON" || echo "OFF")")
    options+=("TAP_TESTS" "TAP Tests" "$([ "$FEATURE_TAP_TESTS" = true ] && echo "ON" || echo "OFF")")
    options+=("SERVERLESS" "Serverless Mode" "$([ "$FEATURE_SERVERLESS" = true ] && echo "ON" || echo "OFF")")
    options+=("SHARED_POSTGRES_BACKEND" "Shared Postgres Backend" "$([ "$FEATURE_SHARED_POSTGRES_BACKEND" = true ] && echo "ON" || echo "OFF")")
    options+=("LINK_POSTGRES_WITH_SHARED" "Link Postgres with Shared" "$([ "$FEATURE_LINK_POSTGRES_WITH_SHARED" = true ] && echo "ON" || echo "OFF")")
    options+=("CATALOG_EXT" "Catalog Extensions" "$([ "$FEATURE_CATALOG_EXT" = true ] && echo "ON" || echo "OFF")")

    # Show checklist
    local selected
    selected=$(whiptail --title "Apache Cloudberry Build Configuration" \
        --checklist "Use SPACE to toggle, ARROW keys to navigate, ENTER to confirm:" \
        25 78 21 \
        "${options[@]}" \
        3>&1 1>&2 2>&3)

    # Check if user cancelled
    if [ $? -ne 0 ]; then
        info "Using default configuration."
        return
    fi

    # Reset all features to false
    FEATURE_ORCA=false
    FEATURE_PXF=false
    FEATURE_GSSAPI=false
    FEATURE_LDAP=false
    FEATURE_XML=false
    FEATURE_LZ4=false
    FEATURE_ZSTD=false
    FEATURE_PAM=false
    FEATURE_PERL=false
    FEATURE_PYTHON=false
    FEATURE_ICU=false
    FEATURE_SELINUX=false
    FEATURE_SECCOMP=false
    FEATURE_SYSTEMD=false
    FEATURE_UUID=false
    FEATURE_XSLT=false
    FEATURE_PAX=false
    FEATURE_GPFDIST=false
    FEATURE_MAPREDUCE=false
    FEATURE_IC_PROXY=false
    FEATURE_DEBUG=false
    FEATURE_PYTHONSRC_EXT=false
    FEATURE_GPCLOUD=false
    FEATURE_EXTERNAL_FTS=false
    FEATURE_PRELOAD_IC_MODULE=false
    FEATURE_TCL=false
    FEATURE_SSL=false
    FEATURE_OPENSSL_REDIRECT=false
    FEATURE_DEPEND=false
    FEATURE_CASSERT=false
    FEATURE_PROFILING=false
    FEATURE_COVERAGE=false
    FEATURE_DTRACE=false
    FEATURE_TAP_TESTS=false
    FEATURE_SERVERLESS=false
    FEATURE_SHARED_POSTGRES_BACKEND=false
    FEATURE_LINK_POSTGRES_WITH_SHARED=false
    FEATURE_CATALOG_EXT=false

    # Set selected features to true
    for feature in $selected; do
        # Remove quotes
        feature=$(echo "$feature" | tr -d '"')
        local var_name="FEATURE_$feature"
        eval "$var_name=true"
    done
}
select_features_numeric() {
    if [ "$INTERACTIVE" = false ]; then
        return
    fi

    local features=(
        "ORCA:Query Optimizer:$FEATURE_ORCA"
        "PXF:Platform Extension Framework:$FEATURE_PXF"
        "GSSAPI:Kerberos Authentication:$FEATURE_GSSAPI"
        "LDAP:LDAP Authentication:$FEATURE_LDAP"
        "XML:XML Support:$FEATURE_XML"
        "LZ4:LZ4 Compression:$FEATURE_LZ4"
        "ZSTD:ZSTD Compression:$FEATURE_ZSTD"
        "PAM:PAM Authentication:$FEATURE_PAM"
        "PERL:Perl Language Support:$FEATURE_PERL"
        "PYTHON:Python Language Support:$FEATURE_PYTHON"
        "ICU:ICU (Unicode):$FEATURE_ICU"
        "SELINUX:SELinux Support:$FEATURE_SELINUX"
        "SECCOMP:Seccomp Support:$FEATURE_SECCOMP"
        "SYSTEMD:Systemd Support:$FEATURE_SYSTEMD"
        "UUID:UUID Support:$FEATURE_UUID"
        "XSLT:XSLT Support:$FEATURE_XSLT"
        "PAX:PAX Storage Format:$FEATURE_PAX"
        "GPFDIST:gpfdist Tool:$FEATURE_GPFDIST"
        "MAPREDUCE:MapReduce Support:$FEATURE_MAPREDUCE"
        "IC_PROXY:Interconnect Proxy:$FEATURE_IC_PROXY"
        "DEBUG:Debug Build:$FEATURE_DEBUG"
        "PYTHONSRC_EXT:Python Source Extensions:$FEATURE_PYTHONSRC_EXT"
        "GPCLOUD:GPCloud Support:$FEATURE_GPCLOUD"
        "EXTERNAL_FTS:External FTS:$FEATURE_EXTERNAL_FTS"
        "PRELOAD_IC_MODULE:Preload Interconnect Module:$FEATURE_PRELOAD_IC_MODULE"
        "TCL:Tcl Language Support:$FEATURE_TCL"
        "SSL:SSL Support:$FEATURE_SSL"
        "OPENSSL_REDIRECT:OpenSSL Redirect:$FEATURE_OPENSSL_REDIRECT"
        "DEPEND:Dependency Tracking:$FEATURE_DEPEND"
        "CASSERT:C Assertions:$FEATURE_CASSERT"
        "PROFILING:Profiling:$FEATURE_PROFILING"
        "COVERAGE:Coverage:$FEATURE_COVERAGE"
        "DTRACE:DTrace Support:$FEATURE_DTRACE"
        "TAP_TESTS:TAP Tests:$FEATURE_TAP_TESTS"
        "SERVERLESS:Serverless Mode:$FEATURE_SERVERLESS"
        "SHARED_POSTGRES_BACKEND:Shared Postgres Backend:$FEATURE_SHARED_POSTGRES_BACKEND"
        "LINK_POSTGRES_WITH_SHARED:Link Postgres with Shared:$FEATURE_LINK_POSTGRES_WITH_SHARED"
        "CATALOG_EXT:Catalog Extensions:$FEATURE_CATALOG_EXT"
    )
    
    while true; do
        clear
        echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║${NC}          ${GREEN}Apache Cloudberry Build Configuration${NC}                      ${BLUE}║${NC}"
        echo -e "${BLUE}╠════════════════════════════════════════════════════════════════════════════╣${NC}"
        echo -e "${BLUE}║${NC} Enter number to toggle feature, or command below:                       ${BLUE}║${NC}"
        echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        
        # Display features in two columns
        local half=$(( (${#features[@]} + 1) / 2 ))
        for ((i=0; i<half; i++)); do
            # Left column
            IFS=':' read -r name1 desc1 status1 <<< "${features[$i]}"
            local mark1="[ ]"
            [ "$status1" = "true" ] && mark1="[${GREEN}x${NC}]"
            local idx1=$((i+1))
            
            # Right column
            local j=$((i + half))
            local right_col=""
            if [ $j -lt ${#features[@]} ]; then
                IFS=':' read -r name2 desc2 status2 <<< "${features[$j]}"
                local mark2="[ ]"
                [ "$status2" = "true" ] && mark2="[${GREEN}x${NC}]"
                local idx2=$((j+1))
                right_col=$(printf "%2d) %s %-10s" "$idx2" "$mark2" "$name2")
            fi
            
            printf " %2d) %s %-12s  │  %s\n" "$idx1" "$mark1" "$name1" "$right_col"
        done
        
        echo ""
        echo -e "${BLUE}Installation Path:${NC} $INSTALL_DIR"
        echo "------------------------------------------------------------------------------"
        echo -e "Commands: ${GREEN}Enter${NC} to confirm, ${YELLOW}a${NC}ll to select all, ${YELLOW}n${NC}one to clear all"
        echo -ne "Select option: "
        
        read choice
        
        case "$choice" in
            "") # Enter
                break
                ;;
            [aA]*) # All
                for i in "${!features[@]}"; do
                    IFS=':' read -r n d s <<< "${features[$i]}"
                    features[$i]="$n:$d:true"
                done
                ;;
            [nN]*) # None
                for i in "${!features[@]}"; do
                    IFS=':' read -r n d s <<< "${features[$i]}"
                    features[$i]="$n:$d:false"
                done
                ;;
            *) # Number
                if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#features[@]} ]; then
                    local idx=$((choice - 1))
                    IFS=':' read -r name desc status <<< "${features[$idx]}"
                    if [ "$status" = "true" ]; then
                        features[$idx]="$name:$desc:false"
                    else
                        features[$idx]="$name:$desc:true"
                    fi
                fi
                ;;
        esac
    done
    
    # Apply selections
    for feature in "${features[@]}"; do
        IFS=':' read -r name desc status <<< "$feature"
        local var_name="FEATURE_$name"
        eval "$var_name=$status"
    done
    
    clear
}

# ----------------------------------------------------------------------
# OS Detection
# ----------------------------------------------------------------------


# ----------------------------------------------------------------------
# Step 1: Install Dependencies
# ----------------------------------------------------------------------
install_dependencies() {
    info "Installing system dependencies..."
    
    local BASE_DEPS=()
    local FEATURE_DEPS=()
    
    if [[ "$OS_ID" =~ ^(centos|rhel|rocky|almalinux)$ ]]; then
        # RHEL/Rocky/CentOS
        local MAJOR_VER=$(echo $OS_VERSION | cut -d. -f1)
        
        # Enable EPEL & CRB/PowerTools
        if ! rpm -q epel-release >/dev/null 2>&1; then
            dnf install -y epel-release
        fi
        if [[ "$MAJOR_VER" == "9" ]]; then
             dnf config-manager --set-enabled crb || true
        elif [[ "$MAJOR_VER" == "8" ]]; then
             dnf config-manager --set-enabled powertools || true
             dnf config-manager --set-enabled devel || true
        fi

        # Base Dependencies (Core build tools + Common libs)
        # Added: which, rsync, diffutils, file, iproute, net-tools
        BASE_DEPS=(
            git gcc gcc-c++ make flex bison
            openssl-devel bzip2-devel readline-devel zlib-devel
            libevent-devel apr-devel libyaml-devel libuv-devel
            iproute net-tools wget tar sudo passwd openssh-clients openssh-server
            perl-IPC-Run perl-Test-Simple perl-Env perl-ExtUtils-Embed perl-core
            which rsync diffutils file
        )
        
        # Jansson is needed for external-fts
        BASE_DEPS+=(jansson-devel)

        # Feature Dependencies
        [ "$FEATURE_ORCA" = true ] && FEATURE_DEPS+=(xerces-c-devel)
        [ "$FEATURE_PXF" = true ] && FEATURE_DEPS+=(libcurl-devel)
        [ "$FEATURE_GSSAPI" = true ] && FEATURE_DEPS+=(krb5-devel)
        [ "$FEATURE_LDAP" = true ] && FEATURE_DEPS+=(openldap-devel)
        [ "$FEATURE_XML" = true ] && FEATURE_DEPS+=(libxml2-devel)
        [ "$FEATURE_LZ4" = true ] && FEATURE_DEPS+=(lz4-devel)
        [ "$FEATURE_ZSTD" = true ] && FEATURE_DEPS+=(libzstd-devel)
        [ "$FEATURE_PAM" = true ] && FEATURE_DEPS+=(pam-devel)
        [ "$FEATURE_PERL" = true ] && FEATURE_DEPS+=(perl-ExtUtils-Embed perl-core)
        [ "$FEATURE_PYTHON" = true ] && FEATURE_DEPS+=(python3-devel)
        [ "$FEATURE_ICU" = true ] && FEATURE_DEPS+=(libicu-devel)
        [ "$FEATURE_SELINUX" = true ] && FEATURE_DEPS+=(libselinux-devel)
        [ "$FEATURE_SECCOMP" = true ] && FEATURE_DEPS+=(libseccomp-devel)
        [ "$FEATURE_SYSTEMD" = true ] && FEATURE_DEPS+=(systemd-devel)
        [ "$FEATURE_UUID" = true ] && FEATURE_DEPS+=(libuuid-devel)
        [ "$FEATURE_XSLT" = true ] && FEATURE_DEPS+=(libxslt-devel)
        [ "$FEATURE_GPFDIST" = true ] && FEATURE_DEPS+=(libevent-devel apr-devel libyaml-devel)
        
        # New Feature Dependencies
        [ "$FEATURE_PYTHONSRC_EXT" = true ] && FEATURE_DEPS+=(python3-pip libcurl-devel)
        [ "$FEATURE_GPCLOUD" = true ] && FEATURE_DEPS+=(libcurl-devel libxml2-devel)
        [ "$FEATURE_EXTERNAL_FTS" = true ] && FEATURE_DEPS+=(jansson-devel)
        [ "$FEATURE_IC_PROXY" = true ] && FEATURE_DEPS+=(libuv-devel)
        [ "$FEATURE_TCL" = true ] && FEATURE_DEPS+=(tcl-devel)
        [ "$FEATURE_SSL" = true ] && FEATURE_DEPS+=(openssl-devel)
        [ "$FEATURE_DTRACE" = true ] && FEATURE_DEPS+=(systemtap-sdt-devel)
        [ "$FEATURE_TAP_TESTS" = true ] && FEATURE_DEPS+=(perl-IPC-Run)
        
        # PAX Dependencies (OS Specific)
        if [ "$FEATURE_PAX" = true ]; then
            FEATURE_DEPS+=(cmake3 protobuf-devel)
        fi
        
        # Install
        local all_deps=("${BASE_DEPS[@]}" "${FEATURE_DEPS[@]}")
        run_with_header "Installing Dependencies (RHEL/Rocky/CentOS)" \
            "dnf install -y ${all_deps[*]}"

    elif [[ "$OS_ID" == "ubuntu" ]]; then
        # Ubuntu
        apt-get update
        
        BASE_DEPS=(
            build-essential git flex bison
            libssl-dev libbz2-dev libreadline-dev zlib1g-dev
            libevent-dev libapr1-dev libyaml-dev libuv1-dev libjansson-dev
            iproute2 net-tools wget tar sudo openssh-client openssh-server
            rsync curl
        )
        
        # Feature Dependencies
        [ "$FEATURE_ORCA" = true ] && FEATURE_DEPS+=(libxerces-c-dev)
        [ "$FEATURE_PXF" = true ] && FEATURE_DEPS+=(libcurl4-openssl-dev)
        [ "$FEATURE_GSSAPI" = true ] && FEATURE_DEPS+=(libkrb5-dev)
        [ "$FEATURE_LDAP" = true ] && FEATURE_DEPS+=(libldap2-dev)
        [ "$FEATURE_XML" = true ] && FEATURE_DEPS+=(libxml2-dev)
        [ "$FEATURE_LZ4" = true ] && FEATURE_DEPS+=(liblz4-dev)
        [ "$FEATURE_ZSTD" = true ] && FEATURE_DEPS+=(libzstd-dev)
        [ "$FEATURE_PAM" = true ] && FEATURE_DEPS+=(libpam0g-dev)
        [ "$FEATURE_PERL" = true ] && FEATURE_DEPS+=(libperl-dev)
        [ "$FEATURE_PYTHON" = true ] && FEATURE_DEPS+=(python3-dev)
        [ "$FEATURE_ICU" = true ] && FEATURE_DEPS+=(libicu-dev)
        [ "$FEATURE_SELINUX" = true ] && FEATURE_DEPS+=(libselinux1-dev)
        [ "$FEATURE_SECCOMP" = true ] && FEATURE_DEPS+=(libseccomp-dev)
        [ "$FEATURE_SYSTEMD" = true ] && FEATURE_DEPS+=(libsystemd-dev)
        [ "$FEATURE_UUID" = true ] && FEATURE_DEPS+=(uuid-dev)
        [ "$FEATURE_XSLT" = true ] && FEATURE_DEPS+=(libxslt1-dev)
        [ "$FEATURE_GPFDIST" = true ] && FEATURE_DEPS+=(libevent-dev libapr1-dev libyaml-dev)

        # New Feature Dependencies
        [ "$FEATURE_PYTHONSRC_EXT" = true ] && FEATURE_DEPS+=(python3-pip libcurl4-openssl-dev)
        [ "$FEATURE_GPCLOUD" = true ] && FEATURE_DEPS+=(libcurl4-openssl-dev libxml2-dev)
        [ "$FEATURE_EXTERNAL_FTS" = true ] && FEATURE_DEPS+=(libjansson-dev)
        [ "$FEATURE_IC_PROXY" = true ] && FEATURE_DEPS+=(libuv1-dev)
        [ "$FEATURE_TCL" = true ] && FEATURE_DEPS+=(tcl-dev)
        [ "$FEATURE_SSL" = true ] && FEATURE_DEPS+=(libssl-dev)
        [ "$FEATURE_DTRACE" = true ] && FEATURE_DEPS+=(systemtap-sdt-dev)
        [ "$FEATURE_TAP_TESTS" = true ] && FEATURE_DEPS+=(libipc-run-perl)
        
        # PAX Dependencies (OS Specific)
        if [ "$FEATURE_PAX" = true ]; then
            FEATURE_DEPS+=(cmake libprotobuf-dev protobuf-compiler)
        fi

        local all_deps=("${BASE_DEPS[@]}" "${FEATURE_DEPS[@]}")
        run_with_header "Installing Dependencies (Ubuntu)" \
            "apt-get install -y ${all_deps[*]}"
    else
        fail "Unsupported OS: $OS_ID"
    fi
    
    info "Dependencies installed."
}

# ----------------------------------------------------------------------
# Step 2: User & System Setup
# ----------------------------------------------------------------------
setup_user_and_system() {
    info "Setting up user '$GPADMIN_USER' and system configuration..."

    # Create user
    if ! id "$GPADMIN_USER" &>/dev/null; then
        useradd -m -s /bin/bash "$GPADMIN_USER"
        echo "$GPADMIN_USER:$GPADMIN_PASS" | chpasswd
        info "User $GPADMIN_USER created."
    fi

    # Sudoers
    if [ ! -f "/etc/sudoers.d/90-gpadmin" ]; then
        echo "$GPADMIN_USER ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/90-gpadmin
        chmod 440 /etc/sudoers.d/90-gpadmin
    fi

    # System Limits
    cat > /etc/security/limits.d/90-cbdb.conf <<EOF
$GPADMIN_USER soft core unlimited
$GPADMIN_USER soft nproc 131072
$GPADMIN_USER soft nofile 65536
$GPADMIN_USER soft memlock unlimited
EOF

    # SSH Setup
    if [ ! -f "/home/$GPADMIN_USER/.ssh/id_rsa" ]; then
        info "Generating SSH keys..."
        sudo -u "$GPADMIN_USER" ssh-keygen -t rsa -N "" -f "/home/$GPADMIN_USER/.ssh/id_rsa"
        sudo -u "$GPADMIN_USER" bash -c "cat /home/$GPADMIN_USER/.ssh/id_rsa.pub >> /home/$GPADMIN_USER/.ssh/authorized_keys"
        sudo -u "$GPADMIN_USER" chmod 600 "/home/$GPADMIN_USER/.ssh/authorized_keys"
        sudo -u "$GPADMIN_USER" bash -c "ssh-keyscan -H localhost 127.0.0.1 >> /home/$GPADMIN_USER/.ssh/known_hosts 2>/dev/null"
    fi
    
    # Enable Password Auth
    sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
    if systemctl is-active sshd >/dev/null 2>&1; then
        systemctl reload sshd
    fi

    info "User and system setup complete."
}

# ----------------------------------------------------------------------
# Step 3: Xerces-C (Only if ORCA is enabled)
# ----------------------------------------------------------------------
install_xerces() {
    if [ "$FEATURE_ORCA" = false ]; then
        return
    fi

    if [ -f "/usr/local/xerces-c/lib/libxerces-c.so" ]; then
        info "Xerces-C appears to be installed. Skipping."
        return
    fi

    info "Installing Xerces-C (required for ORCA)..."
    local XERCES_VER="3.3.0"
    local XERCES_URL="https://archive.apache.org/dist/xerces/c/3/sources/xerces-c-${XERCES_VER}.tar.gz"
    
    pushd /tmp > /dev/null
    
    run_with_header "Downloading Xerces-C ${XERCES_VER}" \
        "wget -nv '$XERCES_URL' -O xerces-c.tar.gz" || fail "Failed to download Xerces-C"
    
    run_with_header "Extracting Xerces-C" \
        "tar xf xerces-c.tar.gz" || fail "Failed to extract Xerces-C"
    
    cd "xerces-c-${XERCES_VER}"
    
    run_with_header "Configuring Xerces-C" \
        "./configure --prefix=/usr/local/xerces-c --disable-network" || fail "Xerces-C configure failed"
    
    run_with_header "Building Xerces-C" \
        "make -j\$(nproc)" || fail "Xerces-C build failed"
    
    run_with_header "Installing Xerces-C" \
        "make install" || fail "Xerces-C install failed"
    
    popd > /dev/null
    rm -rf "/tmp/xerces-c-${XERCES_VER}" "/tmp/xerces-c.tar.gz"
    
    if [[ "$OS_ID" =~ ^(rocky|rhel|almalinux)$ ]] && [[ "$OS_VERSION" =~ ^9 ]]; then
         cp /usr/local/xerces-c/lib/libxerces-c.so /usr/local/xerces-c/lib/libxerces-c-3.3.so || true
    fi
    
    info "Xerces-C installed."
}

# ----------------------------------------------------------------------
# Step 3.1: Prepare PAX Submodules (Only if PAX is enabled)
# ----------------------------------------------------------------------
prepare_pax_submodules() {
    if [ "$FEATURE_PAX" = false ]; then
        return
    fi

    info "Preparing PAX submodules..."
    
    # Check if we are in a git repository
    if [ -d ".git" ]; then
        local PAX_SUBMODULES=(
            "contrib/pax_storage/src/cpp/contrib/googletest"
            "contrib/pax_storage/src/cpp/contrib/tabulate"
            "contrib/pax_storage/src/cpp/contrib/googlebench"
            "dependency/yyjson"
        )
        
        for sub in "${PAX_SUBMODULES[@]}"; do
            run_with_header "Updating PAX Submodule: $(basename $sub)" \
                "git submodule update --init --recursive \"$sub\"" || warn "Failed to update submodule $sub. Build might fail."
        done
    else
        warn "Not a git repository. Skipping submodule update. Ensure source code is complete."
    fi
    
    info "PAX submodules prepared."
}

# ----------------------------------------------------------------------
# Step 4: Build & Install
# ----------------------------------------------------------------------
build_and_install() {
    info "Starting Build Process..."
    
    if [ ! -f "configure" ]; then
        fail "Cannot find 'configure' script. Please run from source root."
    fi

    # Ensure source directory is owned by gpadmin for build process
    info "Setting ownership of source directory to $GPADMIN_USER..."
    chown -R "$GPADMIN_USER:$GPADMIN_USER" .

    # Prepare install directory and copy required libraries
    info "Preparing installation directory..."
    rm -rf "$INSTALL_DIR"
    chmod a+w /usr/local
    
    if [[ "$OS_ID" =~ ^(centos|rhel|rocky|almalinux)$ ]]; then
        # Rocky/RHEL: Create lib directory and copy Xerces-C libraries if ORCA is enabled
        mkdir -p "$INSTALL_DIR/lib"
        if [ "$FEATURE_ORCA" = true ]; then
            info "Copying Xerces-C libraries to $INSTALL_DIR/lib..."
            cp -v /usr/local/xerces-c/lib/libxerces-c.so \
                  /usr/local/xerces-c/lib/libxerces-c-3.*.so \
                  "$INSTALL_DIR/lib"
        fi
    elif [[ "$OS_ID" == "ubuntu" ]]; then
        # Ubuntu: Just create the directory (uses system xerces-c)
        mkdir -p "$INSTALL_DIR"
    fi
    
    chown -R "$GPADMIN_USER:$GPADMIN_USER" "$INSTALL_DIR"

    # Construct Configure Options
    local CONFIG_OPTS=()
    CONFIG_OPTS+=(--prefix="$INSTALL_DIR")
    CONFIG_OPTS+=(--with-includes=/usr/local/include)
    CONFIG_OPTS+=(--with-libs=/usr/local/lib)
    # Feature Flags Mapping
    [ "$FEATURE_ORCA" = true ] && CONFIG_OPTS+=(--enable-orca) || CONFIG_OPTS+=(--disable-orca)
    [ "$FEATURE_PXF" = true ] && CONFIG_OPTS+=(--enable-pxf) || CONFIG_OPTS+=(--disable-pxf)
    [ "$FEATURE_GSSAPI" = true ] && CONFIG_OPTS+=(--with-gssapi) || CONFIG_OPTS+=(--without-gssapi)
    [ "$FEATURE_LDAP" = true ] && CONFIG_OPTS+=(--with-ldap) || CONFIG_OPTS+=(--without-ldap)
    [ "$FEATURE_XML" = true ] && CONFIG_OPTS+=(--with-libxml) || CONFIG_OPTS+=(--without-libxml)
    [ "$FEATURE_LZ4" = true ] && CONFIG_OPTS+=(--with-lz4) || CONFIG_OPTS+=(--without-lz4)
    [ "$FEATURE_ZSTD" = true ] && CONFIG_OPTS+=(--with-zstd) || CONFIG_OPTS+=(--without-zstd)
    [ "$FEATURE_PAM" = true ] && CONFIG_OPTS+=(--with-pam) || CONFIG_OPTS+=(--without-pam)
    [ "$FEATURE_PERL" = true ] && CONFIG_OPTS+=(--with-perl) || CONFIG_OPTS+=(--without-perl)
    [ "$FEATURE_PYTHON" = true ] && CONFIG_OPTS+=(--with-python) || CONFIG_OPTS+=(--without-python)
    [ "$FEATURE_ICU" = true ] && CONFIG_OPTS+=(--with-icu) || CONFIG_OPTS+=(--without-icu)
    [ "$FEATURE_SELINUX" = true ] && CONFIG_OPTS+=(--with-selinux) || CONFIG_OPTS+=(--without-selinux)
    [ "$FEATURE_SECCOMP" = true ] && CONFIG_OPTS+=(--with-libseccomp) || CONFIG_OPTS+=(--without-libseccomp)
    [ "$FEATURE_SYSTEMD" = true ] && CONFIG_OPTS+=(--with-systemd) || CONFIG_OPTS+=(--without-systemd)
    [ "$FEATURE_UUID" = true ] && CONFIG_OPTS+=(--with-uuid=e2fs) || CONFIG_OPTS+=(--without-uuid)
    [ "$FEATURE_XSLT" = true ] && CONFIG_OPTS+=(--with-libxslt) || CONFIG_OPTS+=(--without-libxslt)
    [ "$FEATURE_PAX" = true ] && CONFIG_OPTS+=(--enable-pax) || CONFIG_OPTS+=(--disable-pax)
    [ "$FEATURE_GPFDIST" = true ] && CONFIG_OPTS+=(--enable-gpfdist) || CONFIG_OPTS+=(--disable-gpfdist)
    [ "$FEATURE_MAPREDUCE" = true ] && CONFIG_OPTS+=(--enable-mapreduce) || CONFIG_OPTS+=(--disable-mapreduce)
    [ "$FEATURE_IC_PROXY" = true ] && CONFIG_OPTS+=(--enable-ic-proxy) || CONFIG_OPTS+=(--disable-ic-proxy)
    [ "$FEATURE_DEBUG" = true ] && CONFIG_OPTS+=(--enable-debug --enable-cassert)
    
    # New Comprehensive Options Mapping
    [ "$FEATURE_PYTHONSRC_EXT" = true ] && CONFIG_OPTS+=(--with-pythonsrc-ext) || CONFIG_OPTS+=(--without-pythonsrc-ext)
    [ "$FEATURE_GPCLOUD" = true ] && CONFIG_OPTS+=(--enable-gpcloud) || CONFIG_OPTS+=(--disable-gpcloud)
    [ "$FEATURE_EXTERNAL_FTS" = true ] && CONFIG_OPTS+=(--enable-external-fts) || CONFIG_OPTS+=(--disable-external-fts)
    [ "$FEATURE_PRELOAD_IC_MODULE" = true ] && CONFIG_OPTS+=(--enable-preload-ic-module) || CONFIG_OPTS+=(--disable-preload-ic-module)
    
    # Coverage testing - install lcov if requested but not available
    if [ "$FEATURE_COVERAGE" = true ]; then
        if ! command -v lcov >/dev/null 2>&1; then
            info "lcov not found, installing lcov for coverage testing..."
            if [[ "$OS_ID" =~ ^(centos|rhel|rocky|almalinux)$ ]]; then
                run_with_header "Installing lcov" "dnf install -y lcov" false
            elif [[ "$OS_ID" == "ubuntu" ]]; then
                run_with_header "Installing lcov" "apt-get install -y lcov" false
            fi
            
            # Check again after installation attempt
            if ! command -v lcov >/dev/null 2>&1; then
                fail "lcov installation failed. Please install lcov manually or disable coverage feature."
            fi
        fi
        CONFIG_OPTS+=(--enable-coverage)
    else
        CONFIG_OPTS+=(--disable-coverage)
    fi
    
    if [ "$FEATURE_TCL" = true ]; then
        CONFIG_OPTS+=(--with-tcl)
        # Try to find tclConfig.sh
        local tcl_config_path=$(find /usr/lib* /usr/share -name tclConfig.sh 2>/dev/null | head -n 1)
        if [ -n "$tcl_config_path" ]; then
            CONFIG_OPTS+=(--with-tclconfig=$(dirname "$tcl_config_path"))
        fi
    else
        CONFIG_OPTS+=(--without-tcl)
    fi

    [ "$FEATURE_SSL" = true ] && CONFIG_OPTS+=(--with-ssl=openssl) || CONFIG_OPTS+=(--without-ssl)
    [ "$FEATURE_OPENSSL_REDIRECT" = true ] && CONFIG_OPTS+=(--enable-openssl-redirect)
    [ "$FEATURE_DEPEND" = true ] && CONFIG_OPTS+=(--enable-depend)
    [ "$FEATURE_CASSERT" = true ] && CONFIG_OPTS+=(--enable-cassert)
    [ "$FEATURE_PROFILING" = true ] && CONFIG_OPTS+=(--enable-profiling)
    [ "$FEATURE_COVERAGE" = true ] && CONFIG_OPTS+=(--enable-coverage)
    [ "$FEATURE_DTRACE" = true ] && CONFIG_OPTS+=(--enable-dtrace)
    [ "$FEATURE_TAP_TESTS" = true ] && CONFIG_OPTS+=(--enable-tap-tests)
    [ "$FEATURE_SERVERLESS" = true ] && CONFIG_OPTS+=(--enable-serverless)
    [ "$FEATURE_SHARED_POSTGRES_BACKEND" = true ] && CONFIG_OPTS+=(--enable-shared-postgres-backend) || CONFIG_OPTS+=(--disable-shared-postgres-backend)
    [ "$FEATURE_LINK_POSTGRES_WITH_SHARED" = true ] && CONFIG_OPTS+=(--enable-link-postgres-with-shared) || CONFIG_OPTS+=(--disable-link-postgres-with-shared)
    [ "$FEATURE_CATALOG_EXT" = true ] && CONFIG_OPTS+=(--enable-catalog-ext) || CONFIG_OPTS+=(--disable-catalog-ext)

    # Environment Setup for Configure
    export CC=gcc
    export CXX=g++
    
    # Set LD_LIBRARY_PATH for Xerces-C and Cloudberry libraries
    export LD_LIBRARY_PATH="/usr/local/xerces-c/lib:/usr/local/cloudberry-db/lib:$LD_LIBRARY_PATH"
    
    # Run Configure
    local configure_cmd="./configure ${CONFIG_OPTS[*]}"
    run_with_header "Configuring Cloudberry" \
        "$configure_cmd" || fail "Configure failed. See $LOG_FILE"

    # Run Make
    run_with_header "Building Cloudberry (make -j\$(nproc))" \
        "sudo -u \"$GPADMIN_USER\" make -j\$(nproc)" || fail "Make failed. See $LOG_FILE"

    # Run Make Install
    run_with_header "Installing Cloudberry (make install)" \
        "sudo -u \"$GPADMIN_USER\" make install" || fail "Make install failed. See $LOG_FILE"
    
    # Contrib
    run_with_header "Building Contrib Modules (make -C contrib install)" \
        "sudo -u \"$GPADMIN_USER\" make -C contrib -j\$(nproc) install" || fail "Contrib install failed. See $LOG_FILE"

    info "Build and installation complete!"
}

# ----------------------------------------------------------------------
# Main Execution
# ----------------------------------------------------------------------

# Parse Args
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -p|--path)
            INSTALL_DIR="$2"
            shift 2
            ;;
        -y|--yes)
            INTERACTIVE=false
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        build|prepare)
            MODE="$1"
            shift
            ;;
        *)
            error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Prompt for user and installation directory if interactive
setup_variables() {
    if [ "$INTERACTIVE" = true ]; then
        echo -n "Enter installation directory [/usr/local/cloudberry-db]: "
        read INSTALL_DIR_INPUT
        INSTALL_DIR=${INSTALL_DIR_INPUT:-/usr/local/cloudberry-db}
        
        echo -n "Enter gpadmin username [gpadmin]: "
        read GPADMIN_USER_INPUT
        GPADMIN_USER=${GPADMIN_USER_INPUT:-gpadmin}
        
        echo -n "Enter password for $GPADMIN_USER [changeme]: "
        read -s GPADMIN_PASS_INPUT
        echo
        GPADMIN_PASS=${GPADMIN_PASS_INPUT:-changeme}
    fi
}

check_root
detect_os
setup_variables

# Execute Steps based on Mode
if [ "$MODE" == "prepare" ]; then
    select_features # Select features to know which deps to install
    install_dependencies
    setup_user_and_system
    info "Preparation complete."
elif [ "$MODE" == "build" ]; then
    select_features
    install_dependencies
    setup_user_and_system
    install_xerces
    prepare_pax_submodules
    build_and_install
    
    echo ""
    echo "----------------------------------------------------------------------"
    echo "Success! Apache Cloudberry has been installed to: $INSTALL_DIR"
    echo "----------------------------------------------------------------------"
else
    fail "Invalid mode: $MODE"
fi
