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
FEATURE_UUID=true
FEATURE_XSLT=false
FEATURE_PAX=false
FEATURE_GPFDIST=true
FEATURE_MAPREDUCE=true
FEATURE_IC_PROXY=true
FEATURE_DEBUG=false

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

# Enhanced command execution with fixed header display
run_with_header() {
    local step_name="$1"
    local cmd="$2"
    local log_to_file="${3:-true}"
    
    # Print header
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC} ${GREEN}STEP:${NC} $step_name"
    echo -e "${BLUE}║${NC} ${GREEN}CMD: ${NC}$cmd"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Execute command
    if [ "$log_to_file" = true ]; then
        eval "$cmd" 2>&1 | tee -a "$LOG_FILE"
        return ${PIPESTATUS[0]}
    else
        eval "$cmd"
        return $?
    fi
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
        warn "whiptail not found. Falling back to simple menu."
        select_features_simple
        return
    fi

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

    # Set selected features to true
    for feature in $selected; do
        # Remove quotes
        feature=$(echo "$feature" | tr -d '"')
        local var_name="FEATURE_$feature"
        eval "$var_name=true"
    done
}

# Fallback simple menu (original implementation)
select_features_simple() {
    while true; do
        clear
        echo -e "${BLUE}=== Apache Cloudberry Build Configuration ===${NC}"
        echo "Select features to enable/disable (Toggle with number, Enter to confirm):"
        echo ""
        
        # Display Menu
        local i=1
        local keys=("ORCA" "PXF" "GSSAPI" "LDAP" "XML" "LZ4" "ZSTD" "PAM" "PERL" "PYTHON" "ICU" "SELINUX" "SECCOMP" "SYSTEMD" "UUID" "XSLT" "PAX" "GPFDIST" "MAPREDUCE" "IC_PROXY" "DEBUG")
        
        for key in "${keys[@]}"; do
            # Get value using indirect reference
            local var_name="FEATURE_$key"
            local val="${!var_name}"
            
            if [ "$val" = true ]; then
                echo -e "$i) [${GREEN}x${NC}] $key"
            else
                echo -e "$i) [ ] $key"
            fi
            ((i++))
        done
        
        echo ""
        echo "Installation Path: $INSTALL_DIR"
        echo ""
        read -p "Enter number to toggle, or Press Enter to continue: " choice
        
        if [ -z "$choice" ]; then
            break
        fi
        
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#keys[@]} ]; then
            local key="${keys[$((choice-1))]}"
            local var_name="FEATURE_$key"
            local val="${!var_name}"
            
            if [ "$val" = true ]; then
                eval "$var_name=false"
            else
                eval "$var_name=true"
            fi
        fi
    done
    
    info "Configuration confirmed."
}

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
        [ "$FEATURE_PXF" = true ] && FEATURE_DEPS+=(libcurl-devel)
        [ "$FEATURE_GSSAPI" = true ] && FEATURE_DEPS+=(krb5-devel)
        [ "$FEATURE_LDAP" = true ] && FEATURE_DEPS+=(openldap-devel)
        [ "$FEATURE_XML" = true ] && FEATURE_DEPS+=(libxml2-devel)
        [ "$FEATURE_LZ4" = true ] && FEATURE_DEPS+=(lz4-devel)
        [ "$FEATURE_ZSTD" = true ] && FEATURE_DEPS+=(libzstd-devel)
        [ "$FEATURE_PAM" = true ] && FEATURE_DEPS+=(pam-devel)
        [ "$FEATURE_PYTHON" = true ] && FEATURE_DEPS+=(python3-devel python3-pip)
        [ "$FEATURE_ICU" = true ] && FEATURE_DEPS+=(libicu-devel)
        [ "$FEATURE_SELINUX" = true ] && FEATURE_DEPS+=(libselinux-devel)
        [ "$FEATURE_SECCOMP" = true ] && FEATURE_DEPS+=(libseccomp-devel)
        [ "$FEATURE_SYSTEMD" = true ] && FEATURE_DEPS+=(systemd-devel)
        [ "$FEATURE_UUID" = true ] && FEATURE_DEPS+=(libuuid-devel)
        [ "$FEATURE_XSLT" = true ] && FEATURE_DEPS+=(libxslt-devel)
        
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
        
        [ "$FEATURE_PXF" = true ] && FEATURE_DEPS+=(libcurl4-openssl-dev)
        [ "$FEATURE_GSSAPI" = true ] && FEATURE_DEPS+=(libkrb5-dev)
        [ "$FEATURE_LDAP" = true ] && FEATURE_DEPS+=(libldap2-dev)
        [ "$FEATURE_XML" = true ] && FEATURE_DEPS+=(libxml2-dev)
        [ "$FEATURE_LZ4" = true ] && FEATURE_DEPS+=(liblz4-dev)
        [ "$FEATURE_ZSTD" = true ] && FEATURE_DEPS+=(libzstd-dev)
        [ "$FEATURE_PAM" = true ] && FEATURE_DEPS+=(libpam0g-dev)
        [ "$FEATURE_PERL" = true ] && FEATURE_DEPS+=(libperl-dev)
        [ "$FEATURE_PYTHON" = true ] && FEATURE_DEPS+=(python3-dev python3-pip)
        [ "$FEATURE_ICU" = true ] && FEATURE_DEPS+=(libicu-dev)
        [ "$FEATURE_SELINUX" = true ] && FEATURE_DEPS+=(libselinux1-dev)
        [ "$FEATURE_SECCOMP" = true ] && FEATURE_DEPS+=(libseccomp-dev)
        [ "$FEATURE_SYSTEMD" = true ] && FEATURE_DEPS+=(libsystemd-dev)
        [ "$FEATURE_UUID" = true ] && FEATURE_DEPS+=(uuid-dev)
        [ "$FEATURE_XSLT" = true ] && FEATURE_DEPS+=(libxslt1-dev)
        
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
    local CONFIG_OPTS=("--prefix=$INSTALL_DIR")
    
    # Feature Flags
    [ "$FEATURE_ORCA" = true ] && CONFIG_OPTS+=("--enable-orca")
    [ "$FEATURE_PXF" = true ] && CONFIG_OPTS+=("--enable-pxf")
    [ "$FEATURE_GSSAPI" = true ] && CONFIG_OPTS+=("--with-gssapi")
    [ "$FEATURE_LDAP" = true ] && CONFIG_OPTS+=("--with-ldap")
    [ "$FEATURE_XML" = true ] && CONFIG_OPTS+=("--with-libxml")
    [ "$FEATURE_LZ4" = true ] && CONFIG_OPTS+=("--with-lz4")
    [ "$FEATURE_ZSTD" = true ] && CONFIG_OPTS+=("--with-zstd")
    [ "$FEATURE_PAM" = true ] && CONFIG_OPTS+=("--with-pam")
    [ "$FEATURE_PERL" = true ] && CONFIG_OPTS+=("--with-perl")
    [ "$FEATURE_PYTHON" = true ] && CONFIG_OPTS+=("--with-python")
    [ "$FEATURE_ICU" = true ] && CONFIG_OPTS+=("--with-icu")
    [ "$FEATURE_SELINUX" = true ] && CONFIG_OPTS+=("--with-selinux")
    [ "$FEATURE_SECCOMP" = true ] && CONFIG_OPTS+=("--with-libseccomp")
    [ "$FEATURE_SYSTEMD" = true ] && CONFIG_OPTS+=("--with-systemd")
    [ "$FEATURE_UUID" = true ] && CONFIG_OPTS+=("--with-uuid=e2fs")
    [ "$FEATURE_XSLT" = true ] && CONFIG_OPTS+=("--with-libxslt")
    [ "$FEATURE_PAX" = true ] && CONFIG_OPTS+=("--enable-pax")
    [ "$FEATURE_GPFDIST" = true ] && CONFIG_OPTS+=("--enable-gpfdist")
    [ "$FEATURE_MAPREDUCE" = true ] && CONFIG_OPTS+=("--enable-mapreduce")
    [ "$FEATURE_IC_PROXY" = true ] && CONFIG_OPTS+=("--enable-ic-proxy")
    [ "$FEATURE_DEBUG" = true ] && CONFIG_OPTS+=("--enable-debug" "--enable-cassert")
    
    # Always enable these for standard build
    CONFIG_OPTS+=("--with-openssl" "--with-libbz2" "--with-zlib")

    # Setup LD_LIBRARY_PATH for configure and build
    export LD_LIBRARY_PATH="/usr/local/cloudberry-db/lib:${LD_LIBRARY_PATH:-}"
    
    # Xerces paths if ORCA enabled
    if [ "$FEATURE_ORCA" = true ]; then
        CONFIG_OPTS+=("--with-includes=/usr/local/xerces-c/include" "--with-libraries=/usr/local/xerces-c/lib")
        # Add xerces-c to LD_LIBRARY_PATH so configure can find it during test program execution
        export LD_LIBRARY_PATH="/usr/local/xerces-c/lib:$LD_LIBRARY_PATH"
    fi

    # Run Configure
    local configure_cmd="sudo -u \"$GPADMIN_USER\" LD_LIBRARY_PATH=\"$LD_LIBRARY_PATH\" ./configure ${CONFIG_OPTS[*]}"
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

check_root
detect_os

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
