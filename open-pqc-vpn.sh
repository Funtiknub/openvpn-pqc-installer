#!/bin/bash

# Set script options for immediate exit on errors
set -e           # Exit immediately if a command exits with a non-zero status.
set -o pipefail  # Return value of a pipeline is the status of the last command to exit with a non-zero status, or zero if no command exited with a non-zero status.
set -u           # Treat unset variables as an error when substituting.

# --- Helper Functions ---

# Function to check if the script is run as root
isRoot() {
    if [ "$EUID" -ne 0 ]; then
        return 1 # Not root
    else
        return 0 # Is root
    fi
}

# Function to check if the TUN device is available
tunAvailable() {
    if [ ! -e /dev/net/tun ]; then
        log "INFO" "TUN device /dev/net/tun not found. Attempting to load module..."
        modprobe tun >/dev/null 2>&1
    fi
    # Check again after attempting to load
    if [ -e /dev/net/tun ]; then
        return 0 # TUN is available
    else
        return 1 # TUN is not available
    fi
}

# --- Cleanup Function Definition ---
copy_logs_to_root() {
    # Check if log files exist before copying
    if [[ -f "$LOG_FILE" ]]; then
        cp -f "$LOG_FILE" /root/install.log
        echo "[INFO] Copied $LOG_FILE to /root/install.log"
    fi
    if [[ -f "$CMD_LOG_FILE" ]]; then
        cp -f "$CMD_LOG_FILE" /root/commands.log
        echo "[INFO] Copied $CMD_LOG_FILE to /root/commands.log"
    fi
}

# --- Trap EXIT signal ---
# Register the copy_logs_to_root function to run on script exit (normal or error)
trap 'copy_logs_to_root' EXIT

# --- Global Constants ---
readonly OPENSSL_VERSION="openssl-3.5.0"
readonly OPENVPN_VERSION="master" # Теперь используется master-ветка



readonly BUILD_DIR="/opt/pqc-vpn-build"
readonly INSTALL_PREFIX="/usr/local/pqc-ssl"
readonly OPENSSL_INSTALL_DIR="$INSTALL_PREFIX"
readonly OPENSSL_CONF_FILE="$OPENSSL_INSTALL_DIR/ssl/openssl.cnf"
# Define OPENSSL_BIN based on install dir
readonly OPENSSL_BIN="$OPENSSL_INSTALL_DIR/bin/openssl"

# OpenVPN Paths & Config
readonly OPENVPN_CONFIG_DIR="/etc/openvpn"
readonly SERVER_CONF="$OPENVPN_CONFIG_DIR/server.conf"
readonly PKI_DIR="$OPENVPN_CONFIG_DIR/pqc-ca" # Directory for CA and keys
# Add OPENVPN_BIN here as well for consistency, although it's often derived
readonly OPENVPN_BIN="/usr/local/sbin/openvpn"


# --- Logging Configuration ---
LOG_DIR="/var/log/pqc-vpn"
LOG_FILE="$LOG_DIR/install.log"
CMD_LOG_FILE="$LOG_DIR/commands.log"

# Create log directories and files
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
touch "$CMD_LOG_FILE"
chmod 600 "$LOG_FILE"
chmod 600 "$CMD_LOG_FILE"

# Color Definitions
COLOR_RED='\033[31m' # Simplified ANSI code
COLOR_GREEN='\033[32m'
COLOR_YELLOW='\033[33m'
COLOR_CYAN='\033[36m'
COLOR_MAGENTA='\033[35m'
COLOR_RESET='\033[0m'

# --- Logging Setup Function ---
setup_logging() {
    # Create log directory if it doesn't exist
    if [ ! -d "$LOG_DIR" ]; then
        mkdir -p "$LOG_DIR"
        if [ $? -ne 0 ]; then
             echo "[ERROR] Failed to create log directory: $LOG_DIR. Cannot continue." >&2
             exit 1
        fi
    fi
    # Create log files if they don't exist
    touch "$LOG_FILE" "$CMD_LOG_FILE"
    if [ $? -ne 0 ]; then
        echo "[ERROR] Failed to create log files in $LOG_DIR. Cannot continue." >&2
        exit 1
    fi
    # Set permissions
    chmod 600 "$LOG_FILE" "$CMD_LOG_FILE"
}

# Logging function
log() {
    local level="$1"
    local message="$2"
    # Remove timestamp generation: local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    local log_message="[$level] $message" # Removed timestamp from file log message
    local color=""
    local console_message=""

    case "$level" in
        "INFO")    color="$COLOR_CYAN";;
        "ERROR")   color="$COLOR_RED";;
        "WARNING") color="$COLOR_YELLOW";;
        "SUCCESS") color="$COLOR_GREEN";;
        "CMD")     color="$COLOR_MAGENTA";;
        *)         color="$COLOR_RESET";;
    esac

    # Format console message: color the whole line for SUCCESS, only the tag otherwise
    if [[ "$level" == "SUCCESS" ]]; then
        console_message="${color}[$level] $message${COLOR_RESET}"
    else
        console_message="${color}[$level]${COLOR_RESET} $message"
    fi

    echo "$log_message" >> "$LOG_FILE" # Log without timestamp to file
    echo -e "$console_message" # Output to console without timestamp
    if [[ "$level" == "ERROR" ]]; then
        echo -e "$console_message" >&2 # Output error to stderr without timestamp
    fi
}

# Function to log and execute commands
log_cmd() {
    local cmd="$1"
    local error_exit="${2:-true}" # Exit on error by default
    local calling_function="${3:-$(caller 0 | awk '{print $2}')}" # Auto-detect calling function

    log "CMD" "Executing: $cmd (from $calling_function)"
    echo "--- CMD START [$calling_function]: $cmd ---" >> "$CMD_LOG_FILE"

    # Execute command, tee stdout to console and log file, redirect stderr to log file
    # Use process substitution and pipefail to capture the correct exit code
    set +e # Temporarily disable exit on error to capture the status
    eval "$cmd" 2>> "$CMD_LOG_FILE" | tee -a "$CMD_LOG_FILE"
    local result=${PIPESTATUS[0]} # Get exit status of the eval'd command
    set -e # Re-enable exit on error

    if [[ $result -eq 0 ]]; then
        log "SUCCESS" "Command executed successfully: $cmd"
        echo "--- CMD END [$calling_function]: SUCCESS ---" >> "$CMD_LOG_FILE"
        return 0
    else
        # Add the command itself to the console error message
        log "ERROR" "Command failed with exit code $result. Command: $cmd"
        echo "--- CMD END [$calling_function]: ERROR (Code: $result) ---" >> "$CMD_LOG_FILE"
        if [ "$error_exit" = "true" ]; then
            log "ERROR" "Critical error in function '$calling_function'. Script aborted."
            exit $result
        fi
        return $result
    fi
}

# --- OS Detection Function ---
check_os() {
    # This function relies on the OS detection logic being present in the global scope
    # (where OS, OS_FAMILY are set). We just need to ensure it runs.
    log "INFO" "Running OS detection logic..."
    if [[ -z "$OS" || -z "$OS_FAMILY" ]]; then
        log "ERROR" "OS detection failed or OS variables not set globally."
        # Attempt to re-run global detection logic if needed, or exit
        # The global part should handle the actual detection and setting OS/OS_FAMILY
        log "ERROR" "Critical error: OS could not be determined."
        exit 1
    fi
    # Setup package manager commands based on detected OS_FAMILY
    case "$OS_FAMILY" in
        "debian")
            PKG_MANAGER="apt-get"
            UPDATE_CMD="apt-get update"
            INSTALL_CMD="apt-get install -y"
            REMOVE_CMD="apt-get remove -y"
            # PKG_LIST_CMD="dpkg -l" # Example
            ;;
        "rhel")
            if [[ "$OS" == "fedora" ]]; then
                 PKG_MANAGER="dnf"
                 UPDATE_CMD="dnf -y update"
                 INSTALL_CMD="dnf install -y"
                 REMOVE_CMD="dnf remove -y"
            else # RHEL, CentOS, Oracle etc.
                 PKG_MANAGER="yum"
                 UPDATE_CMD="yum -y update"
                 INSTALL_CMD="yum install -y"
                 REMOVE_CMD="yum remove -y"
            fi
            # PKG_LIST_CMD="rpm -qa" # Example
            ;;
        "arch")
            PKG_MANAGER="pacman"
            UPDATE_CMD="pacman -Syu --noconfirm"
            INSTALL_CMD="pacman -S --noconfirm --needed"
            REMOVE_CMD="pacman -Rns --noconfirm"
            # PKG_LIST_CMD="pacman -Q" # Example
            ;;
        *) # Should not happen if global detection worked
            log "ERROR" "Unknown OS_FAMILY '$OS_FAMILY' in check_os function."
            exit 1
            ;;
    esac
    log "INFO" "Package manager configured for $OS_FAMILY: $PKG_MANAGER"
}

# --- OS Detection ---
log "INFO" "Detecting operating system..."
OS=""
OS_FAMILY="" # Added for clarity
if [[ -e /etc/debian_version ]]; then
    OS_FAMILY="debian"
    if grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
        OS="ubuntu"
    elif grep -qi "debian" /etc/os-release 2>/dev/null; then
        OS="debian"
    else
        OS="debian_other" # Unknown Debian-based
    fi
elif [[ -e /etc/redhat-release ]]; then
    OS_FAMILY="rhel"
    if grep -qi "centos" /etc/os-release 2>/dev/null; then
        OS="centos"
    elif grep -qi "fedora" /etc/os-release 2>/dev/null; then
        OS="fedora"
    elif grep -qi "red hat enterprise linux" /etc/os-release 2>/dev/null; then
         OS="rhel"
    elif grep -qi "oracle linux" /etc/os-release 2>/dev/null; then
         OS="oracle"
    else
        OS="rhel_other" # Unknown RedHat-based
    fi
elif [[ -e /etc/arch-release ]]; then
    OS_FAMILY="arch"
    OS="arch"
else
    log "ERROR" "Unsupported operating system."
    exit 1
fi
log "INFO" "Detected OS: $OS (Family: $OS_FAMILY)"

# --- Install Base Dependencies ---
install_base_dependencies() {
    log "INFO" "Installing base dependencies and build tools (including OpenVPN dependencies)..."
    
    case "$OS_FAMILY" in
        "debian")
            log_cmd "apt-get update"
            # Pre-configure debconf to avoid interactive prompts for iptables-persistent
            log "INFO" "Pre-configuring debconf for iptables-persistent to auto-save rules..."
            log_cmd "echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections" "false"
            log_cmd "echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections" "false"

            # libssl-dev needed for OpenVPN build against system libs, not strictly required here but common
            # Added: libpam0g-dev liblz4-dev liblzo2-dev libsystemd-dev autoconf automake libtool libcap-ng-dev iptables iptables-persistent python3-docutils
            # NEW: Добавлены libpkcs11-helper1-dev, libnl-3-dev, libnl-genl-3-dev
            log_cmd "apt-get install -y build-essential git cmake gcc g++ make pkg-config libssl-dev rng-tools haveged curl jq libpam0g-dev liblz4-dev liblzo2-dev libsystemd-dev autoconf automake libtool libcap-ng-dev iptables iptables-persistent python3-docutils libpkcs11-helper1-dev libnl-3-dev libnl-genl-3-dev"
            ;;
        "rhel")
            if [[ "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "oracle" || "$OS" == "rhel_other" ]]; then
                 log_cmd "yum -y update"
                 log_cmd "yum -y install epel-release || true"
                 log_cmd "yum -y groupinstall 'Development Tools'"
                 # Added: iptables-services (provides iptables and persistence) python3-docutils
                 # NEW: Добавлены pkcs11-helper-devel, libnl3-devel
                 log_cmd "yum -y install git cmake3 openssl-devel pkgconfig rng-tools haveged curl jq pam-devel lz4-devel lzo-devel systemd-devel autoconf automake libtool libcap-ng-devel iptables-services python3-docutils pkcs11-helper-devel libnl3-devel"
                 if ! command -v cmake &> /dev/null && command -v cmake3 &> /dev/null; then
                     log_cmd "ln -sf /usr/bin/cmake3 /usr/bin/cmake" "false"
                 fi
            elif [[ "$OS" == "fedora" ]]; then
                 log_cmd "dnf -y update"
                 log_cmd "dnf -y groupinstall 'Development Tools'"
                 # Added: iptables-services python3-docutils
                 # NEW: Добавлены pkcs11-helper-devel, libnl3-devel
                 log_cmd "dnf -y install git cmake openssl-devel pkgconfig rng-tools haveged curl jq pam-devel lz4-devel lzo-devel systemd-devel autoconf automake libtool libcap-ng-devel iptables-services python3-docutils pkcs11-helper-devel libnl3-devel"
            fi
            ;;
        "arch")
            # Added: iptables (persistence needs manual setup or other packages) python-docutils
            # NEW: Добавлены pkcs11-helper, libnl
            log_cmd "pacman -Syu --noconfirm --needed base-devel git cmake gcc make pkgconf openssl rng-tools haveged curl jq pam lz4 lzo autoconf automake libtool libcap-ng iptables python-docutils pkcs11-helper libnl"
            ;;
        *)
            log "ERROR" "Unknown OS family: $OS_FAMILY"
            exit 1
            ;;
    esac

    # Start and enable entropy services (ignore errors if not installed or fail to start)
    log "INFO" "Attempting to start entropy services (rngd/haveged)..."
    if command -v systemctl &> /dev/null; then
        systemctl enable haveged &> /dev/null || log "WARNING" "Failed to enable haveged."
        systemctl start haveged &> /dev/null || log "WARNING" "Failed to start haveged."
        
        local rng_service_name=""
        if [[ "$OS_FAMILY" == "debian" ]]; then
             rng_service_name="rng-tools-debian"
        elif [[ "$OS_FAMILY" == "rhel" || "$OS_FAMILY" == "arch" ]]; then
             rng_service_name="rngd"
        fi

        if [[ -n "$rng_service_name" ]]; then
             systemctl enable "$rng_service_name" &> /dev/null || log "WARNING" "Failed to enable $rng_service_name."
             systemctl start "$rng_service_name" &> /dev/null || log "WARNING" "Failed to start $rng_service_name."
        fi
    else
         log "WARNING" "systemctl not found. Could not manage entropy services."
    fi

    log "SUCCESS" "Base dependencies installed."
}

# --- Install OpenSSL ---
install_openssl() {
    log "SUCCESS" "-------------------- START OpenSSL Installation --------------------"
    log "SUCCESS" "Starting OpenSSL installation ($OPENSSL_VERSION) to $OPENSSL_INSTALL_DIR"
    local src_dir="$BUILD_DIR/openssl"
    mkdir -p "$src_dir"
    cd "$BUILD_DIR"

    if [ ! -d "$src_dir/.git" ]; then
        log_cmd "git clone --depth 1 --branch $OPENSSL_VERSION https://github.com/openssl/openssl.git $src_dir"
    else
        log "INFO" "OpenSSL directory already exists, updating..."
        cd "$src_dir"
        log_cmd "git fetch --depth 1 origin $OPENSSL_VERSION && git checkout $OPENSSL_VERSION"
        cd "$BUILD_DIR" # Go back
    fi

    cd "$src_dir"
    log "INFO" "Configuring OpenSSL..."
    # --openssldir specifies where to look for openssl.cnf
    log_cmd "./config --prefix=$OPENSSL_INSTALL_DIR --openssldir=$OPENSSL_INSTALL_DIR/ssl shared"

    log "INFO" "Building OpenSSL (this may take a while)..."
    log_cmd "make -j$(nproc)"

    log "INFO" "Installing OpenSSL..."
    log_cmd "make install_sw" # install_sw does not install documentation

    # Configure dynamic linker
    log "INFO" "Configuring ldconfig for $OPENSSL_INSTALL_DIR/lib64 or $OPENSSL_INSTALL_DIR/lib"
    local ssl_lib_dir=""
    if [ -d "$OPENSSL_INSTALL_DIR/lib64" ]; then
        ssl_lib_dir="$OPENSSL_INSTALL_DIR/lib64"
    elif [ -d "$OPENSSL_INSTALL_DIR/lib" ]; then
         ssl_lib_dir="$OPENSSL_INSTALL_DIR/lib"
    else
         log "ERROR" "OpenSSL library directory not found in $OPENSSL_INSTALL_DIR"
         exit 1
    fi

    # Create/overwrite ldconfig configuration file
    echo "$ssl_lib_dir" > /etc/ld.so.conf.d/pqc-openssl.conf
    log_cmd "ldconfig"

    # Verification
    log "INFO" "Verifying installed OpenSSL version..."
    # Use a more flexible check for 3.5.0
    if ! "$OPENSSL_INSTALL_DIR/bin/openssl" version | grep -q "OpenSSL 3\.5\.0"; then
         log "ERROR" "Installed OpenSSL version does not match expected ($OPENSSL_VERSION)."
         "$OPENSSL_INSTALL_DIR/bin/openssl" version # Show actual version
         exit 1
    fi
    log "SUCCESS" "OpenSSL $OPENSSL_VERSION successfully installed in $OPENSSL_INSTALL_DIR"
    cd "$BUILD_DIR" # Return to build directory
    log "SUCCESS" "-------------------- END OpenSSL Installation ----------------------"
}

# --- Install oqs-provider --- (Function Removed)
# Entire install_oqs_provider function removed

# --- Configure OpenSSL for PQC ---
configure_openssl_pqc() {
    log "SUCCESS" "-------------------- START OpenSSL PQC Configuration -----------------"
    log "SUCCESS" "Configuring OpenSSL ($OPENSSL_CONF_FILE) for built-in PQC algorithms" # Updated log message

    # oqsprovider.so is no longer needed or searched for

    # Create config directory if it doesn't exist
    mkdir -p "$(dirname "$OPENSSL_CONF_FILE")"

    # Create the configuration file without oqsprovider section
    cat > "$OPENSSL_CONF_FILE" << EOF
# OpenSSL Configuration for PQC VPN (using default provider)
openssl_conf = openssl_init

[openssl_init]
providers = provider_sect

[provider_sect]
default = default_sect
# oqsprovider section removed

[default_sect]
activate = 1
# Algorithms are enabled by default in the provider

# Base sections for key/certificate generation
[ req ]
default_bits        = 2048 # Not used for PQC, but might be required
distinguished_name  = req_distinguished_name
prompt              = no   # Do not prompt interactively

[ req_distinguished_name ]
C                   = ZZ   # Use your country code
ST                  = State
L                   = City
O                   = PQC-VPN Org
OU                  = PQC-VPN Unit
CN                  = example.com # Replace with actual CN
emailAddress        = admin@example.com

[ v3_ca ]
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always,issuer
basicConstraints = critical,CA:true
keyUsage = critical, digitalSignature, cRLSign, keyCertSign

[ v3_req ] # For server and client certificates
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth # Add clientAuth for clients
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = example.com       # Replace with actual DNS/IP
IP.1 = 192.168.1.1
EOF

    log "INFO" "OpenSSL configuration file created: ${COLOR_MAGENTA}$OPENSSL_CONF_FILE${COLOR_RESET}"

    # Check PQC algorithm availability (only in default provider)
    log "INFO" "Checking availability of PQC KEMs (built-in default provider)..."
    if ! "$OPENSSL_INSTALL_DIR/bin/openssl" list -kem-algorithms -provider default | grep -qiE 'ML-KEM|mlkem'; then
        log "WARNING" "Expected KEM algorithms (e.g., ML-KEM) not found in default provider."
        "$OPENSSL_INSTALL_DIR/bin/openssl" list -kem-algorithms -provider default >> "$CMD_LOG_FILE" 2>&1 || true
    else
        log "SUCCESS" "Found PQC KEM algorithms in default provider."
        "$OPENSSL_INSTALL_DIR/bin/openssl" list -kem-algorithms -provider default | grep -iE 'ML-KEM|mlkem' # Show found ones
    fi

    log "INFO" "Checking availability of PQC SIGs (built-in default provider)..."
    if ! "$OPENSSL_INSTALL_DIR/bin/openssl" list -signature-algorithms -provider default | grep -qiE 'ML-DSA|mldsa'; then
        log "WARNING" "Expected signature algorithms (e.g., ML-DSA) not found in default provider."
        "$OPENSSL_INSTALL_DIR/bin/openssl" list -signature-algorithms -provider default >> "$CMD_LOG_FILE" 2>&1 || true
    else
        log "SUCCESS" "Found PQC signature algorithms in default provider."
        "$OPENSSL_INSTALL_DIR/bin/openssl" list -signature-algorithms -provider default | grep -iE 'ML-DSA|mldsa' # Show found ones
    fi
    log "SUCCESS" "-------------------- END OpenSSL PQC Configuration -------------------"
}

# --- Verify PQC Installation ---
verify_pqc_installation(){
    log "SUCCESS" "==================== START PQC Stack Verification ===================="
    log "SUCCESS" "Starting PQC stack installation verification..."

    local openssl_bin="$OPENSSL_INSTALL_DIR/bin/openssl"
    # openssl_conf is still needed for genpkey implicit loading
    local openssl_conf="$OPENSSL_CONF_FILE"

    # 1. Verify OpenSSL version
    log "INFO" "[Verification] Checking OpenSSL version..."
    if ! "$openssl_bin" version | grep -q "OpenSSL 3\.5\.0"; then
        log "ERROR" "[Verification] Error: Incorrect OpenSSL version."
        "$openssl_bin" version
        return 1
    else
        log "SUCCESS" "[Verification] OpenSSL version is correct: $("$openssl_bin" version)"
    fi

    # 2. Verify library visibility (Only OpenSSL libs now)
    log "INFO" "[Verification] Checking OpenSSL library visibility via ldconfig..."
    if ldconfig -p | grep -q "pqc-ssl.*libcrypto"; then # Check specifically for libcrypto
        log "SUCCESS" "[Verification] OpenSSL Libraries from $INSTALL_PREFIX found in ldconfig cache."
        ldconfig -p | grep "pqc-ssl" # Show found paths
    else
        log "WARNING" "[Verification] OpenSSL Libraries from $INSTALL_PREFIX not found in ldconfig cache. Potential issues."
        log_cmd "ldconfig" "false"
        if ! ldconfig -p | grep -q "pqc-ssl.*libcrypto"; then
             log "ERROR" "[Verification] Re-running ldconfig did not help."
             return 1
        fi
    fi

    # 3. Verify provider loading (Only default)
    log "INFO" "[Verification] Checking OpenSSL provider loading..."
    if ! "$openssl_bin" list -providers | grep -q "default"; then
        log "ERROR" "[Verification] Default provider not loaded! Check OpenSSL setup and logs."
        "$openssl_bin" list -providers >> "$CMD_LOG_FILE" 2>&1 || true # Log output for debugging
        return 1
    fi
    log "SUCCESS" "[Verification] Default provider loaded."
    # Removed check for oqsprovider
    "$openssl_bin" list -providers >> "$CMD_LOG_FILE" 2>&1 # Log full list to command log

    # 4. Verify PQC algorithm availability (in default provider)
    log "INFO" "[Verification] Checking PQC algorithm availability (in default provider)..."
    local kem_found=false
    local sig_found=false
    if "$openssl_bin" list -kem-algorithms -provider default | grep -qiE 'ML-KEM|mlkem'; then
        kem_found=true
        log "SUCCESS" "[Verification] Found PQC KEM algorithms in default provider."
    else
        log "WARNING" "[Verification] Expected KEM algorithms (ML-KEM) not found in default provider."
        "$openssl_bin" list -kem-algorithms -provider default >> "$CMD_LOG_FILE" 2>&1 || true # Log output
    fi
     if "$openssl_bin" list -signature-algorithms -provider default | grep -qiE 'ML-DSA|mldsa'; then
        sig_found=true
        log "SUCCESS" "[Verification] Found PQC signature algorithms in default provider."
    else
        log "WARNING" "[Verification] Expected signature algorithms (ML-DSA) not found in default provider."
        "$openssl_bin" list -signature-algorithms -provider default >> "$CMD_LOG_FILE" 2>&1 || true # Log output
    fi
    if ! $kem_found || ! $sig_found; then
        log "ERROR" "[Verification] Not all expected PQC algorithms were found in the default provider."
        return 1
    fi

    # 5. Test PQC key generation (using default provider implicitly)
    log "INFO" "[Verification] Attempting to generate a test PQC key (ML-DSA-87)..."
    local test_key_file="$BUILD_DIR/test_pqc_key.pem"
    local test_sig_alg="ML-DSA-87" # Using one of the built-in algs
    log "INFO" "Using signature algorithm for test: $test_sig_alg"

    # Remove provider specification, rely on default provider via config
    if timeout 30s "$openssl_bin" genpkey -algorithm "$test_sig_alg" -out "$test_key_file" >> "$CMD_LOG_FILE" 2>&1; then
        log "SUCCESS" "[Verification] Test PQC key generated successfully: ${COLOR_MAGENTA}${test_key_file}${COLOR_RESET}"
        rm -f "$test_key_file" # Remove test key
    else
        local result=$?
        if [[ $result -eq 124 ]]; then # timeout exit code
             log "ERROR" "[Verification] Error: Key generation timed out (>30 sec). Potential entropy issues."
        else
             log "ERROR" "[Verification] Error generating test PQC key (code $result). Check $CMD_LOG_FILE."
        fi
        return 1
    fi

    log "SUCCESS" "===== PQC stack verification completed successfully ====="
    log "SUCCESS" "==================== END PQC Stack Verification ======================"
    return 0
}

# --- Install OpenVPN ---
install_openvpn() {
    log "SUCCESS" "-------------------- START OpenVPN Installation --------------------"
    log "SUCCESS" "Starting OpenVPN installation (branch: $OPENVPN_VERSION)"
    local src_dir="$BUILD_DIR/openvpn"
    mkdir -p "$src_dir"
    cd "$BUILD_DIR"

    if [ ! -d "$src_dir/.git" ]; then
        log_cmd "git clone --depth 1 --branch $OPENVPN_VERSION https://github.com/OpenVPN/openvpn.git $src_dir"
    else
        log "INFO" "OpenVPN directory already exists, updating..."
        cd "$src_dir"
        log_cmd "git fetch origin"
        log_cmd "git checkout $OPENVPN_VERSION"
        log_cmd "git pull"
        cd "$BUILD_DIR"
    fi

    cd "$src_dir"
    log "INFO" "Configuring OpenVPN..."
    log_cmd "autoreconf -vi"
    log_cmd "./configure --prefix=/usr/local"
    log "INFO" "Building OpenVPN (this may take a while)..."
    log_cmd "make -j$(nproc)"
    log "INFO" "Installing OpenVPN..."
    log_cmd "make install"
    log "SUCCESS" "OpenVPN (branch: $OPENVPN_VERSION) successfully installed."
    cd "$BUILD_DIR"
    log "SUCCESS" "-------------------- END OpenVPN Installation ----------------------"
}

# --- Configure Networking (IP Forwarding and Firewall) ---
configure_network() {
    log "SUCCESS" "-------------------- START Network Configuration ---------------------"
    log "SUCCESS" "Configuring IP forwarding and basic firewall rules..."

    # 1. Enable IP Forwarding
    local sysctl_conf_file="/etc/sysctl.d/99-pqc-vpn-forward.conf"
    log "INFO" "Enabling IPv4 forwarding in $sysctl_conf_file..."
    echo "net.ipv4.ip_forward = 1" > "$sysctl_conf_file"
    # Apply sysctl changes
    log_cmd "sysctl -p $sysctl_conf_file"

    # 2. Configure Firewall (iptables)
    log "INFO" "Configuring basic iptables rules..."

    # Try to determine the main network interface
    # This is a best guess, might need manual adjustment on complex setups
    local main_interface=$(ip route | grep '^default' | awk '{print $5}' | head -n 1)
    if [ -z "$main_interface" ]; then
        log "WARNING" "Could not automatically determine the main network interface. Using eth0 as a fallback for NAT rule."
        main_interface="eth0" # Fallback, adjust if needed
    else
        log "INFO" "Detected main network interface: $main_interface"
    fi

    # Use global PORT and PROTOCOL variables set by ask_install_questions
    # local ovpn_port="1194" # Removed hardcoded default
    # local ovpn_proto="udp"  # Removed hardcoded default
    local ovpn_network="10.8.0.0/24" # Default OpenVPN subnet

    log "INFO" "Allowing incoming OpenVPN connections on ${PORT}/${PROTOCOL}..." # Use variables
    if ! iptables -C INPUT -p $PROTOCOL --dport $PORT -j ACCEPT 2>/dev/null; then
        log_cmd "iptables -A INPUT -p $PROTOCOL --dport $PORT -j ACCEPT"
    else
        log "INFO" "INPUT rule for $PROTOCOL/$PORT already exists, skipping."
    fi

    log "INFO" "Allowing traffic forwarding from OpenVPN subnet ($ovpn_network)..."
    if ! iptables -C FORWARD -s $ovpn_network -j ACCEPT 2>/dev/null; then
        log_cmd "iptables -A FORWARD -s $ovpn_network -j ACCEPT"
    else
        log "INFO" "FORWARD rule for $ovpn_network already exists, skipping."
    fi
    if ! iptables -C FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
        log_cmd "iptables -A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT"
    else
        log "INFO" "FORWARD RELATED,ESTABLISHED rule already exists, skipping."
    fi

    log "INFO" "Enabling NAT (Masquerade) for OpenVPN subnet ($ovpn_network) via interface $main_interface..."
    # Проверка на дублирование правила MASQUERADE
    if ! iptables -t nat -C POSTROUTING -s $ovpn_network -o $main_interface -j MASQUERADE 2>/dev/null; then
        log_cmd "iptables -t nat -A POSTROUTING -s $ovpn_network -o $main_interface -j MASQUERADE"
    else
        log "INFO" "MASQUERADE rule for $ovpn_network via $main_interface already exists, skipping."
    fi

    # 3. Save iptables rules
    log "INFO" "Attempting to save iptables rules..."
    case "$OS_FAMILY" in
        "debian")
            # iptables-persistent should prompt on install, save might already be done.
            # This command saves current rules, overwriting existing saved rules.
            log_cmd "netfilter-persistent save" "false" || log "WARNING" "netfilter-persistent save command failed. Rules might not persist reboot."
            ;;
        "rhel" | "fedora")
            # Enable and start the service, then save rules
            log_cmd "systemctl enable iptables.service" "false"
            log_cmd "systemctl start iptables.service" "false"
            log_cmd "service iptables save" "false" || log "WARNING" "service iptables save command failed. Rules might not persist reboot."
            ;;
        "arch")
            log "WARNING" "Persistence for iptables on Arch Linux requires manual setup (e.g., using iptables-nft or systemd unit). Rules were not automatically saved."
            # Example command (user needs iptables-nft package and enabled service):
            # log_cmd "iptables-save > /etc/iptables/iptables.rules" "false"
            ;;
        *)
            log "WARNING" "Unknown OS family ($OS_FAMILY). Could not attempt to save iptables rules."
            ;;
    esac

    log "SUCCESS" "Basic network configuration (forwarding, firewall) applied."
    log "SUCCESS" "-------------------- END Network Configuration -----------------------"
    return 0
}

# --- Menu for Existing Installations ---
manage_menu() {
    log "INFO" "It looks like OpenVPN with PQC-enabled OpenSSL is already installed."
    echo ""
    # Green header
    echo -e "           ${COLOR_GREEN}------OpenVPN PQC------${COLOR_RESET}"
    # Yellow options
    echo -e "   ${COLOR_YELLOW}1) Add a new PQC client configuration${COLOR_RESET}"
    echo -e "   ${COLOR_YELLOW}2) Revoke an existing PQC client${COLOR_RESET}"
    echo -e "   ${COLOR_YELLOW}3) Remove OpenVPN PQC${COLOR_RESET}"
    echo -e "   ${COLOR_YELLOW}4) Exit${COLOR_RESET}"
    # Initialize MENU_OPTION to prevent unbound variable error with set -u
    local MENU_OPTION=""
    until [[ $MENU_OPTION =~ ^[1-4]$ ]]; do
        # Prompt remains default color
        read -rp "Select an option [1-4]: " MENU_OPTION
    done

    case $MENU_OPTION in
    1)
        # Call the function to create a new client
        new_pqc_client
        exit 0
        ;;
    2)
        # Call the function to revoke a client
        revoke_pqc_client
        exit 0
        ;;
    3)
        # Call the removal function
        remove_pqc_vpn
        exit 0
        ;;
    4)
        exit 0
        ;;
    esac
}

# --- Remove PQC VPN Installation ---
remove_pqc_vpn() {
    log "SUCCESS" "-------------------- START OpenVPN PQC Removal --------------------"
    
    # Ask for confirmation
    echo -e "${COLOR_RED}WARNING: This will completely remove OpenVPN PQC installation and all related files!${COLOR_RESET}"
    echo -e "${COLOR_RED}All certificates, keys, and configurations will be permanently deleted.${COLOR_RESET}"
    local CONFIRM=""
    until [[ $CONFIRM =~ ^(y|n)$ ]]; do
        read -rp "Are you sure you want to proceed? [y/n]: " -e CONFIRM
    done
    
    if [[ $CONFIRM != "y" ]]; then
        log "INFO" "Removal canceled by user."
        return 0
    fi
    
    log "INFO" "Starting removal process..."
    
    # 1. Stop and disable OpenVPN service
    log "INFO" "Stopping and disabling OpenVPN service..."
    systemctl stop openvpn-server@server.service 2>/dev/null || true
    systemctl disable openvpn-server@server.service 2>/dev/null || true
    
    # 2. Remove OpenVPN configuration files and PKI
    log "INFO" "Removing OpenVPN configuration files and PKI..."
    rm -rf "$OPENVPN_CONFIG_DIR/pqc-ca" 2>/dev/null || true  # Remove PKI directory
    rm -f "$OPENVPN_CONFIG_DIR/server.conf" 2>/dev/null || true  # Remove server config
    rm -f "$OPENVPN_CONFIG_DIR/server/server.conf" 2>/dev/null || true  # Remove server config (alternative location)
    rm -f "$OPENVPN_CONFIG_DIR/ipp.txt" 2>/dev/null || true  # Remove IP pool persistence file
    rm -rf /root/client/ 2>/dev/null || true  # Remove client configs directory
    rm -f /root/*.ovpn 2>/dev/null || true  # Remove any client configs in root
    
    # 3. Remove custom OpenSSL installation
    log "INFO" "Removing custom OpenSSL installation..."
    rm -rf "$INSTALL_PREFIX" 2>/dev/null || true  # Remove OpenSSL installation directory
    
    # 4. Remove custom OpenVPN binaries
    log "INFO" "Removing custom OpenVPN binaries..."
    rm -f /usr/local/sbin/openvpn 2>/dev/null || true
    rm -f /usr/local/bin/openvpn* 2>/dev/null || true
    
    # 5. Remove ldconfig configuration
    log "INFO" "Removing ldconfig configuration..."
    rm -f /etc/ld.so.conf.d/pqc-openssl.conf 2>/dev/null || true
    ldconfig 2>/dev/null || true
    
    # 6. Remove systemd service file
    log "INFO" "Removing systemd service file..."
    rm -f /usr/local/lib/systemd/system/openvpn-server@.service 2>/dev/null || true
    rm -f /usr/local/lib/systemd/system/openvpn-server@.service.bak 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    
    # 7. Revert network configuration
    log "INFO" "Reverting network configuration..."
    # Disable IP forwarding
    rm -f /etc/sysctl.d/99-pqc-vpn-forward.conf 2>/dev/null || true
    # Apply sysctl changes
    sysctl -p 2>/dev/null || true
    
    # 8. Clean up build directory
    log "INFO" "Removing build directory..."
    rm -rf "$BUILD_DIR" 2>/dev/null || true
    
    # 9. Remove log files
    log "INFO" "Removing log files..."
    rm -rf "$LOG_DIR" 2>/dev/null || true
    
    # 10. Clean up iptables rules (careful approach to avoid breaking other rules)
    log "INFO" "Cleaning up iptables rules..."
    # Find and remove only our VPN-related rules
    local VPN_SUBNET="10.8.0.0/24"
    
    # Check if iptables command exists
    if command -v iptables >/dev/null 2>&1; then
        # Clean up INPUT rules for OpenVPN port
        iptables -D INPUT -p tcp --dport "${PORT:-1194}" -j ACCEPT 2>/dev/null || true
        iptables -D INPUT -p udp --dport "${PORT:-1194}" -j ACCEPT 2>/dev/null || true
        
        # Clean up FORWARD rules for OpenVPN subnet
        iptables -D FORWARD -s "$VPN_SUBNET" -j ACCEPT 2>/dev/null || true
        
        # Clean up NAT (MASQUERADE) rules
        iptables -t nat -D POSTROUTING -s "$VPN_SUBNET" -j MASQUERADE 2>/dev/null || true
        
        # Save iptables rules depending on OS
        case "$OS_FAMILY" in
            "debian")
                netfilter-persistent save 2>/dev/null || true
                ;;
            "rhel" | "fedora")
                service iptables save 2>/dev/null || true
                ;;
            "arch")
                log "INFO" "Manual save of iptables rules may be needed on Arch Linux."
                ;;
        esac
    fi
    
    log "SUCCESS" "OpenVPN PQC has been completely removed from your system."
    log "INFO" "You may need to reboot your system for all changes to take effect."
    log "SUCCESS" "-------------------- END OpenVPN PQC Removal --------------------"
}

# --- Initial Setup Questions ---
ask_install_questions(){
    log "SUCCESS" "-------------------- START Initial Configuration Questions --------------------"
    echo "Welcome to the OpenVPN PQC installer!"

    # --- Profile Name --- #
    # Устанавливаем фиксированное имя профиля вместо запроса
    PROFILE_NAME="PQC-VPN"
    log "INFO" "Using default VPN profile name: $PROFILE_NAME"

    echo "I need to ask you a few questions before starting the setup."
    echo "You can leave the default options and just press enter if you are ok with them."
    echo ""

    # --- IP Address --- #
    log "INFO" "Detecting network configuration..."
    # Detect public IPv4 address and pre-fill for the user
    local default_ip
    default_ip=$(ip -4 addr | sed -ne 's|^.* inet \([^/]*\)/.* scope global.*$|\1|p' | head -1)
    if [[ -z $default_ip ]]; then
        # Detect public IPv6 address if no IPv4 found on global scope
        default_ip=$(ip -6 addr | sed -ne 's|^.* inet6 \([^/]*\)/.* scope global.*$|\1|p' | head -1)
    fi
    APPROVE_IP=${APPROVE_IP:-n}
    if [[ $APPROVE_IP =~ n ]]; then
        read -rp "IP address OpenVPN should listen on: " -e -i "$default_ip" IP
    else
         IP="$default_ip"
    fi

    # If $IP is a private IP address, the server must be behind NAT
    if echo "$IP" | grep -qE '^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168)'; then
        echo ""
        log "WARNING" "It seems this server is behind NAT. What is its public IPv4 address or hostname?"
        log "INFO" "We need it for the clients to connect to the server."

        local default_endpoint
        # Try to resolve public IP using external services
        default_endpoint=$(curl -4 -f -m 5 -sS --retry 2 https://api.seeip.org 2>/dev/null || curl -4 -f -m 5 -sS --retry 2 https://ifconfig.me 2>/dev/null || curl -4 -f -m 5 -sS --retry 2 https://api.ipify.org 2>/dev/null)

        ENDPOINT=""
        until [[ $ENDPOINT != "" ]]; do
            read -rp "Public IPv4 address or hostname: " -e -i "$default_endpoint" ENDPOINT
        done
    fi

    # --- IPv6 Support --- #
    echo ""
    log "INFO" "Checking for IPv6 connectivity..."
    local ping6_cmd=""
    if type ping6 >/dev/null 2>&1; then ping6_cmd="ping6 -c3 ipv6.google.com > /dev/null 2>&1";
    elif type ping >/dev/null 2>&1; then ping6_cmd="ping -6 -c3 ipv6.google.com > /dev/null 2>&1"; fi

    local suggestion="n"
    if [[ -n "$ping6_cmd" ]] && eval "$ping6_cmd"; then
        log "INFO" "Your host appears to have IPv6 connectivity."
        suggestion="y"
    else
        log "INFO" "Your host does not appear to have IPv6 connectivity."
    fi
    echo ""
    IPV6_SUPPORT=""
    until [[ $IPV6_SUPPORT =~ ^(y|n)$ ]]; do
        read -rp "Enable IPv6 support (NAT)? [y/n]: " -e -i "$suggestion" IPV6_SUPPORT
    done

    # --- Port --- #
    echo ""
    log "INFO" "What port do you want OpenVPN to listen to?"
    echo "   1) Default: 1194"
    echo "   2) Custom"
    echo "   3) Random [49152-65535]"
    local PORT_CHOICE=""
    until [[ $PORT_CHOICE =~ ^[1-3]$ ]]; do
        read -rp "Port choice [1-3]: " -e -i 1 PORT_CHOICE
    done
    case $PORT_CHOICE in
    1)
        PORT="1194"
        ;;
    2)
        PORT=""
        until [[ $PORT =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; do
            read -rp "Custom port [1-65535]: " -e -i 1194 PORT
        done
        ;;
    3)
        PORT=$(shuf -i49152-65535 -n1)
        log "INFO" "Random Port selected: $PORT"
        ;;
    esac

    # --- Protocol --- #
    echo ""
    log "INFO" "What protocol do you want OpenVPN to use? (UDP recommended)"
    echo "   1) UDP"
    echo "   2) TCP"
    local PROTOCOL_CHOICE=""
    until [[ $PROTOCOL_CHOICE =~ ^[1-2]$ ]]; do
        read -rp "Protocol [1-2]: " -e -i 1 PROTOCOL_CHOICE
    done
    case $PROTOCOL_CHOICE in
    1)
        PROTOCOL="udp"
        ;;
    2)
        PROTOCOL="tcp"
        ;;
    esac

    # --- DNS Resolvers --- #
    echo ""
    log "INFO" "What DNS resolvers do you want to use with the VPN?"
    echo "   1) Current system resolvers (from /etc/resolv.conf)"
    echo "   2) Cloudflare (1.1.1.1, 1.0.0.1)"
    echo "   3) Quad9 (9.9.9.9, 149.112.112.112)"
    echo "   4) Google (8.8.8.8, 8.8.4.4)"
    echo "   5) OpenDNS (208.67.222.222, 208.67.220.220)"
    echo "   6) Yandex Basic (77.88.8.8, 77.88.8.1)"
    echo "   7) AdGuard DNS (94.140.14.140, 94.140.14.141)"
    echo "   8) UltraDNS Fast (156.154.71.2, 156.154.71.3)"
    echo "   9) Norton ConnectSafe (198.153.192.1, 198.153.194.1)"
    echo "  10) Custom"
    DNS=""
    until [[ $DNS =~ ^([1-9]|1[01])$ ]]; do
        read -rp "DNS choice [1-11]: " -e -i 2 DNS
    done
    # Handle custom DNS input if chosen
    DNS1=""
    DNS2=""
    if [[ $DNS == "10" ]]; then
        until [[ $DNS1 =~ ^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$ ]]; do
            read -rp "Primary DNS: " -e DNS1
        done
        until [[ $DNS2 =~ ^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$ || -z $DNS2 ]]; do
            read -rp "Secondary DNS (optional, press Enter to skip): " -e DNS2
        done
    fi

    # --- PQC KEM Algorithm --- #
    echo ""
    log "INFO" "Which PQC KEM algorithm group should be preferred for TLS 1.3?"
    log "INFO" "This sets the preferred group for negotiation. Others may be used if unavailable."
    # Note: Ensure these names match OpenSSL 3.5 group names (check 'openssl list -groups')
    echo "   ML-KEM (Pure PQC):"
    echo "  1) ML-KEM-512 (Kyber512)"
    echo "  2) ML-KEM-768 (Kyber768)"
    echo "  3) ML-KEM-1024 (Kyber1024)"
    echo "  4) Hybrid X25519+ML-KEM-768"
    echo "  5) Hybrid X25519+ML-KEM-1024"     # Using underscore format
   
    PQC_KEM_ALG_CHOICE=""
    until [[ "$PQC_KEM_ALG_CHOICE" =~ ^[1-5]$ ]]; do
        read -rp "Preferred KEM Group [1-5]: " -e -i 2 PQC_KEM_ALG_CHOICE
    done

    case $PQC_KEM_ALG_CHOICE in
        1) PQC_KEM_ALG="ML-KEM-512" ;;
        2) PQC_KEM_ALG="ML-KEM-768" ;;
        3) PQC_KEM_ALG="ML-KEM-1024" ;;
        4) PQC_KEM_ALG="X25519+ML-KEM-768" ;;
        5) PQC_KEM_ALG="X25519+ML-KEM-1024" ;;
  
    esac
    log "INFO" "Using Preferred PQC KEM Group: $PQC_KEM_ALG"

    # --- PQC Signature Algorithm --- #
    echo ""
    log "INFO" "Which PQC signature algorithm do you want to use for CA and certificates?"
    log "WARNING" "SLH-DSA algorithms are generally slower and produce larger signatures/keys than ML-DSA."
    echo "Choose PQC signature algorithm for CA and certificates:"
    echo "  1) ML-DSA-44"
    echo "  2) ML-DSA-65"
    echo "  3) ML-DSA-87"
    echo "  4) SLH-DSA-SHA2-128f"
    echo "  5) SLH-DSA-SHA2-192f"

    PQC_SIG_ALG_CHOICE=""
    until [[ "$PQC_SIG_ALG_CHOICE" =~ ^[1-5]$ ]]; do
        read -rp "Signature Algorithm [1-5]: " -e -i 2 PQC_SIG_ALG_CHOICE
    done

    case $PQC_SIG_ALG_CHOICE in
        1) PQC_SIG_ALG="ML-DSA-44";;
        2) PQC_SIG_ALG="ML-DSA-65";;
        3) PQC_SIG_ALG="ML-DSA-87";;
        4) PQC_SIG_ALG="SLH-DSA-SHA2-128f";;
        5) PQC_SIG_ALG="SLH-DSA-SHA2-192f";;
    esac
    log "INFO" "Using PQC Signature Algorithm: $PQC_SIG_ALG"

    # --- TLS 1.3 Cipher Suites --- #
    echo ""
    log "INFO" "Which TLS 1.3 cipher suites should be allowed?"
    echo "   1) TLS_AES_256_GCM_SHA384 (Recommended baseline)"
    echo "   2) TLS_CHACHA20_POLY1305_SHA256 (Good alternative, potentially faster on some hardware)"
    echo "   3) Both (Recommended for compatibility - Default)"
    TLS_CIPHER_CHOICE=""
    until [[ $TLS_CIPHER_CHOICE =~ ^[1-3]$ ]]; do
        read -rp "TLS 1.3 Cipher Suites [1-3]: " -e -i 3 TLS_CIPHER_CHOICE
    done
    case $TLS_CIPHER_CHOICE in
    1)
        TLS_CIPHERSUITES="TLS_AES_256_GCM_SHA384"
        ;;
    2)
        TLS_CIPHERSUITES="TLS_CHACHA20_POLY1305_SHA256"
        ;;
    3)
        TLS_CIPHERSUITES="TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256"
        ;;
    esac
    log "INFO" "Using TLS 1.3 Cipher Suites: $TLS_CIPHERSUITES"

    # --- Data Channel Cipher --- #
    echo ""
    log "INFO" "Which cipher should be used for the data channel (tunnel encryption)?"
    echo "   1) AES-256-GCM (Recommended, default, fast with hardware AES support)"
    echo "   2) CHACHA20-POLY1305 (Recommended for devices without hardware AES or as alternative)"
    DATA_CIPHER_CHOICE=""
    until [[ $DATA_CIPHER_CHOICE =~ ^[1-2]$ ]]; do
        read -rp "Data channel cipher [1-2]: " -e -i 1 DATA_CIPHER_CHOICE
    done
    case $DATA_CIPHER_CHOICE in
    1)
        DATA_CIPHER="AES-256-GCM"
        ;;
    2)
        DATA_CIPHER="CHACHA20-POLY1305"
        ;;
    esac
    log "INFO" "Using Data Channel Cipher: $DATA_CIPHER"

    # --- Other settings (set automatically) ---
    # KEM will be negotiated via TLS 1.3
    # Control channel protection: tls-crypt is generally recommended with TLS 1.3
    TLS_PROTECTION="tls-crypt"
    # Compression disabled by default
    COMPRESSION_ENABLED="n"

    # --- Configuration Summary ---
    echo ""
    log "SUCCESS" "-------------------- Configuration Summary --------------------"
    log "INFO" "Profile Name:              ${COLOR_MAGENTA}${PROFILE_NAME}${COLOR_RESET}"
    log "INFO" "Listen IP Address:         ${COLOR_MAGENTA}${IP}${COLOR_RESET}"
    # Use parameter expansion with :- to handle potentially unset ENDPOINT
    if [ -n "${ENDPOINT-}" ]; then
        log "INFO" "Public Endpoint:           ${COLOR_MAGENTA}${ENDPOINT}${COLOR_RESET}"
    fi
    log "INFO" "IPv6 Support:            ${COLOR_MAGENTA}${IPV6_SUPPORT}${COLOR_RESET}"
    log "INFO" "Port:                      ${COLOR_MAGENTA}${PORT}${COLOR_RESET}"
    log "INFO" "Protocol:                  ${COLOR_MAGENTA}${PROTOCOL}${COLOR_RESET}"
    # Display DNS choice details
    case "$DNS" in
        1) dns_display="Current system resolvers";;
        2) dns_display="Cloudflare (1.1.1.1, 1.0.0.1)";;
        3) dns_display="Quad9 (9.9.9.9, 149.112.112.112)";;
        4) dns_display="Google (8.8.8.8, 8.8.4.4)";;
        5) dns_display="OpenDNS (208.67.222.222, 208.67.220.220)";;
        6) dns_display="Yandex Basic (77.88.8.8, 77.88.8.1)";;
        7) dns_display="AdGuard DNS (94.140.14.140, 94.140.14.141)";;
        8) dns_display="UltraDNS Fast (156.154.71.2, 156.154.71.3)";;
        9) dns_display="Norton ConnectSafe (198.153.192.1, 198.153.194.1)";;
       10) dns_display="Custom (${DNS1}${DNS2:+, $DNS2})";; # Show secondary only if set
        *) dns_display="Unknown (Error)";;
    esac
    log "INFO" "DNS Choice:                ${COLOR_MAGENTA}${dns_display}${COLOR_RESET}"
    log "INFO" "PQC KEM Algorithm:         ${COLOR_MAGENTA}${PQC_KEM_ALG}${COLOR_RESET}"
    log "INFO" "PQC Signature Algorithm:   ${COLOR_MAGENTA}${PQC_SIG_ALG}${COLOR_RESET}"
    log "INFO" "TLS 1.3 Cipher Suites:     ${COLOR_MAGENTA}${TLS_CIPHERSUITES}${COLOR_RESET}"
    # Add safe check for DATA_CIPHER in case it's not set
    if [ -n "${DATA_CIPHER-}" ]; then
        log "INFO" "Data Channel Cipher:       ${COLOR_MAGENTA}${DATA_CIPHER}${COLOR_RESET}"
    fi
    log "SUCCESS" "-------------------- End Configuration Summary --------------------"

    echo ""
    log "INFO" "Okay, basic configuration is set."
    log "SUCCESS" "-------------------- END Initial Configuration Questions ----------------------"
    read -n1 -r -p "Press any key to continue with the installation..."
}

# --- PKI Generation ---
generate_pki() {
    log "SUCCESS" "-------------------- START PKI Generation --------------------"

    # Define PKI directory and OpenVPN binary path locally for clarity
    # local PKI_DIR="/etc/openvpn/pqc-ca" # Uses global readonly PKI_DIR
    # local OPENVPN_BIN="/usr/local/sbin/openvpn" # Uses global readonly OPENVPN_BIN
    # local OPENSSL_BIN="$OPENSSL_INSTALL_DIR/bin/openssl" # Uses global readonly OPENSSL_BIN

    log "INFO" "Creating PKI directory: $PKI_DIR"
    mkdir -p "$PKI_DIR"
    if [ $? -ne 0 ]; then
        log "ERROR" "Failed to create PKI directory: $PKI_DIR"
        exit 1
    fi
    chmod 700 "$PKI_DIR"

    local ca_key="$PKI_DIR/ca.key"
    local ca_crt="$PKI_DIR/ca.crt"
    local server_key="$PKI_DIR/server.key"
    local server_csr="$PKI_DIR/server.csr"
    local server_crt="$PKI_DIR/server.crt"
    local ta_key="$PKI_DIR/ta.key"
    # Use PROFILE_NAME for Common Names
    local common_name="${PROFILE_NAME}-CA"
    local server_common_name="${PROFILE_NAME}-Server"

    # Check if OpenSSL binary exists
    if [ ! -f "$OPENSSL_BIN" ]; then
        log "ERROR" "OpenSSL binary not found at $OPENSSL_BIN. Cannot generate PKI."
        exit 1
    fi

    # 1. Generate CA Key & Self-Signed Certificate
    log "INFO" "Generating CA private key and certificate ($PQC_SIG_ALG)..."
    log_cmd "$OPENSSL_BIN req -x509 \
                    -newkey \"$PQC_SIG_ALG\" \
                    -keyout \"$ca_key\" \
                    -out \"$ca_crt\" \
                    -nodes \
                    -subj \"/CN=$common_name\" \
                    -days 3650 \
                    -extensions v3_ca \
                    -config \"$OPENSSL_CONF_FILE\""
    if [ $? -ne 0 ]; then log "ERROR" "Failed to generate CA key/certificate."; exit 1; fi
    chmod 400 "$ca_key"

    # 2. Generate Server Key
    log "INFO" "Generating Server private key ($PQC_SIG_ALG)..."
    # Relying on default provider
    log_cmd "$OPENSSL_BIN genpkey -algorithm \"$PQC_SIG_ALG\" -out \"$server_key\""
    if [ $? -ne 0 ]; then log "ERROR" "Failed to generate server key."; exit 1; fi
    chmod 400 "$server_key"

    # 3. Generate Server CSR
    log "INFO" "Generating Server certificate signing request (CSR)..."
    # Relying on default provider
    log_cmd "$OPENSSL_BIN req -new \
                    -key \"$server_key\" \
                    -out \"$server_csr\" \
                    -nodes \
                    -subj \"/CN=$server_common_name\""
    if [ $? -ne 0 ]; then log "ERROR" "Failed to generate server CSR."; exit 1; fi

    # 4. Sign Server Certificate with CA
    log "INFO" "Signing Server certificate with CA..."
    # Relying on default provider for signing operation based on CA key type
    # Add necessary extensions for a server certificate
    log_cmd "$OPENSSL_BIN x509 -req \
                    -in \"$server_csr\" \
                    -CA \"$ca_crt\" \
                    -CAkey \"$ca_key\" \
                    -CAcreateserial \
                    -out \"$server_crt\" \
                    -days 3650 \
                    -sha256 \
                    -extfile <(printf \"basicConstraints=critical,CA:FALSE\\nkeyUsage=critical,digitalSignature,keyEncipherment\\nextendedKeyUsage=serverAuth\") \
                    -copy_extensions none"

    if [ $? -ne 0 ]; then log "ERROR" "Failed to sign server certificate."; exit 1; fi
    # Remove temporary files
    rm -f "$PKI_DIR/ca.srl"
    rm -f "$server_csr"

    # 5. Generate tls-crypt Key
    log "INFO" "Generating tls-crypt key ($ta_key)..."
    if [ ! -f "$OPENVPN_BIN" ]; then
        log "ERROR" "OpenVPN binary not found at $OPENVPN_BIN. Cannot generate tls-crypt key."
        # Try to locate it if the global variable wasn't set correctly
        OPENVPN_BIN=$(command -v openvpn || echo '/usr/local/sbin/openvpn')
        if [ ! -f "$OPENVPN_BIN" ]; then
            log "ERROR" "Still cannot find OpenVPN binary. Exiting."
             exit 1
        fi
        log "INFO" "Found OpenVPN binary at: $OPENVPN_BIN"
    fi
    log_cmd "$OPENVPN_BIN --genkey tls-crypt \"$ta_key\""
    if [ $? -ne 0 ]; then log "ERROR" "Failed to generate tls-crypt key."; exit 1; fi
    chmod 400 "$ta_key"

    log "SUCCESS" "PKI Generation Complete. Keys and certificates stored in $PKI_DIR"
    log "SUCCESS" "-------------------- END PKI Generation ----------------------"
}

# --- Generate Server Configuration ---
generate_server_config() {
    log "SUCCESS" "-------------------- START Server Config Generation ---------------"
    log "INFO" "Generating OpenVPN server configuration: $SERVER_CONF"

    # Ensure config directory exists
    mkdir -p "$(dirname "$SERVER_CONF")"

    # Determine DNS servers based on user choice
    local dns1=""
    local dns2=""
    case "$DNS" in
        1) # Current system resolvers
           local current_dns=$(grep -v '^#\|^;' /etc/resolv.conf | grep nameserver | awk '{print $2}' | head -n 2)
           dns1=$(echo "$current_dns" | sed -n '1p')
           dns2=$(echo "$current_dns" | sed -n '2p')
           if [ -z "$dns1" ]; then
               log "WARNING" "Could not read system DNS resolvers. Falling back to Cloudflare."
               dns1="1.1.1.1"; dns2="1.0.0.1"
           fi
           ;;
        2) dns1="1.1.1.1"; dns2="1.0.0.1";; # Cloudflare
        3) dns1="9.9.9.9"; dns2="149.112.112.112";; # Quad9
        4) dns1="8.8.8.8"; dns2="8.8.4.4";; # Google
        5) dns1="208.67.222.222"; dns2="208.67.220.220";; # OpenDNS
        6) dns1="77.88.8.8"; dns2="77.88.8.1";; # Yandex Basic
        7) dns1="94.140.14.140"; dns2="94.140.14.141";; # AdGuard DNS
        8) dns1="156.154.71.2"; dns2="156.154.71.3";; # UltraDNS Fast
        9) dns1="198.153.192.1"; dns2="198.153.194.1";; # Norton ConnectSafe
       10) # Custom DNS provided by user
           dns1="$DNS1"
           dns2="$DNS2"
           if [ -z "$dns1" ]; then
                log "WARNING" "Custom DNS chosen but no primary DNS provided. Falling back to Cloudflare."
                dns1="1.1.1.1"; dns2="1.0.0.1"
           fi
           ;;
        *) log "WARNING" "Invalid DNS choice '$DNS'. Falling back to Cloudflare."; dns1="1.1.1.1"; dns2="1.0.0.1";;
    esac

    # Determine user/group based on OS
    local ovpn_user="nobody"
    local ovpn_group="nogroup" # Default for Debian/Ubuntu
    if [[ "$OS_FAMILY" == "rhel" || "$OS_FAMILY" == "arch" ]]; then
        ovpn_group="nobody"
    fi

    # Convert PQC_KEM_ALG format for OpenSSL API compatibility
    # Remove dashes and underscores from the algorithm name
    local openvpn_kem_alg=$(echo "$PQC_KEM_ALG" | sed 's/[-_+]//g')

    # --- Create server.conf --- #
    cat > "$SERVER_CONF" << EOF
# OpenVPN PQC Server Configuration
# Generated by open-pqc-vpn.sh script

# -- Basic Settings --
port $PORT
proto $PROTOCOL
dev tun
ca "$PKI_DIR/ca.crt"
cert "$PKI_DIR/server.crt"
key "$PKI_DIR/server.key"

# -- TLS Settings (TLS 1.3 Mandatory) --
# Use tls-crypt for control channel protection (generated in generate_pki)
tls-crypt "$PKI_DIR/ta.key" 0 # 0 indicates server mode

# Specify preferred TLS 1.3 groups (KEMs), user choice first
# Removed fallback groups as per user request
tls-groups "$openvpn_kem_alg"

# Specify allowed TLS 1.3 cipher suites (chosen by user)
tls-ciphersuites $TLS_CIPHERSUITES

# Specify data channel cipher (separate from TLS handshake)
# AES-256-GCM is a strong, modern default
cipher $DATA_CIPHER

# DH parameters are not needed for TLS 1.3 KEMs
dh none

# -- Network Settings --
# Default VPN subnet
server 10.8.0.0 255.255.255.0

# Push DNS servers to clients
push "dhcp-option DNS $dns1"
push "redirect-gateway def1 bypass-dhcp"
EOF

    # Add secondary DNS if available
    if [ -n "$dns2" ]; then
        echo "push \"dhcp-option DNS $dns2\"" >> "$SERVER_CONF"
    fi

    # Add IPv6 settings if enabled
    if [[ $IPV6_SUPPORT == "y" ]]; then
        log "INFO" "Adding IPv6 configuration to server.conf"
        # Assign a unique /64 block for VPN clients
        echo "server-ipv6 fd42:42:42:1::/64" >> "$SERVER_CONF"
        # Route all IPv6 traffic through the VPN
        echo "push \"route-ipv6 ::/0\"" >> "$SERVER_CONF"
        # Provide a DNS resolver for IPv6 (e.g., Google's)
        echo "push \"dhcp-option DNS6 2001:4860:4860::8888\"" >> "$SERVER_CONF"
    fi

    # --- Additional Recommended Settings --- #
    cat >> "$SERVER_CONF" << EOF

# Maintain association between client virtual IP and
# Common Name. Avoids issues if clients reconnect.
ifconfig-pool-persist ipp.txt

# Keepalive settings (ping client every 10s, assume dead after 120s)
keepalive 10 120

# Drop privileges after initialization
# user $ovpn_user
# group $ovpn_group

# Ensure key and TUN device persistence across restarts
persist-key
persist-tun

# Status log file
status $LOG_DIR/openvpn-status.log

# Log verbosity (3 is standard)
verb 3

# Ensure clients have the server certificate purpose set
# remote-cert-tls server

# Optional: Disable compression (recommended to avoid VORACLE attack)
# compress lz4 # Can be enabled if needed and compatible clients are used
EOF

    if [ $? -eq 0 ]; then
        log "SUCCESS" "Server configuration successfully generated: ${COLOR_MAGENTA}$SERVER_CONF${COLOR_RESET}"
    else
        log "ERROR" "Failed to write server configuration file: $SERVER_CONF"
        exit 1
    fi

    # Add note about checking configuration
    log "INFO" "Review the generated configuration: ${COLOR_MAGENTA}$SERVER_CONF${COLOR_RESET}"
    log "SUCCESS" "-------------------- END Server Config Generation ----------------"
}

# --- Setup systemd service ---
setup_systemd_service() {
    log "SUCCESS" "-------------------- START Systemd Service Setup --------------------"
    log "INFO" "Configuring OpenVPN systemd service..."
    
    local systemd_dir="/usr/local/lib/systemd/system"
    local service_file="$systemd_dir/openvpn-server@.service"
    
    # Check if service file exists
    if [ ! -f "$service_file" ]; then
        log "WARNING" "OpenVPN systemd service file not found. Creating a minimal unit file at /etc/systemd/system/openvpn-server@.service"
        cat > /etc/systemd/system/openvpn-server@.service <<EOF
[Unit]
Description=OpenVPN service for %I
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/openvpn --config /etc/openvpn/%i.conf
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
LimitNPROC=10
DeviceAllow=/dev/null
DeviceAllow=/dev/net/tun
ProtectSystem=true
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF
        service_file="/etc/systemd/system/openvpn-server@.service"
        systemctl daemon-reload
        log "SUCCESS" "Created minimal OpenVPN systemd unit file at /etc/systemd/system/openvpn-server@.service"
    fi
    
    log "INFO" "Checking WorkingDirectory in $service_file..."
    if grep -q "WorkingDirectory=/etc/openvpn/server" "$service_file"; then
        log "INFO" "Correcting WorkingDirectory path in systemd service file..."
        # Create backup of original file
        cp "$service_file" "$service_file.bak"
        
        # Replace the WorkingDirectory path
        sed -i 's|WorkingDirectory=/etc/openvpn/server|WorkingDirectory=/etc/openvpn|' "$service_file"
        
        if [ $? -eq 0 ]; then
            log "SUCCESS" "WorkingDirectory path corrected in $service_file"
            log "INFO" "Reloading systemd daemon..."
            systemctl daemon-reload
        else
            log "ERROR" "Failed to correct WorkingDirectory path. Service may not start correctly."
            return 1
        fi
    else
        log "INFO" "WorkingDirectory already correctly set or not found in service file."
    fi
    
    log "SUCCESS" "Systemd service configured successfully."
    log "SUCCESS" "-------------------- END Systemd Service Setup ----------------------"
    return 0
}

# --- Generate Client Configuration ---
# Arguments: $1 = Client Name
generate_client_config() {
    local client_name="$1"
    if [ -z "$client_name" ]; then
        log "ERROR" "Client name cannot be empty."
        return 1
    fi

    log "SUCCESS" "-------------------- START Client Config Generation ($client_name) --------------"

    local client_key="$PKI_DIR/${client_name}.key"
    local client_csr="$PKI_DIR/${client_name}.csr"
    local client_crt="$PKI_DIR/${client_name}.crt"
    local client_conf="/root/${client_name}.ovpn" # Default save location

    # Check if client already exists
    if [ -f "$client_conf" ] || [ -f "$client_key" ] || [ -f "$client_crt" ]; then
        log "ERROR" "Client '$client_name' seems to already exist. Choose a different name."
        return 1
    fi

    # Check dependencies
    if [ ! -f "$OPENSSL_BIN" ]; then log "ERROR" "OpenSSL binary missing."; return 1; fi
    if [ ! -f "$PKI_DIR/ca.crt" ] || [ ! -f "$PKI_DIR/ca.key" ]; then log "ERROR" "CA certificate or key missing."; return 1; fi
    if [ ! -f "$PKI_DIR/ta.key" ]; then log "ERROR" "tls-crypt key (ta.key) missing."; return 1; fi

    # 1. Generate Client Key
    log "INFO" "Generating Client private key ($client_name, $PQC_SIG_ALG)..."
    log_cmd "$OPENSSL_BIN genpkey -algorithm "$PQC_SIG_ALG" -out "$client_key""
    if [ $? -ne 0 ]; then log "ERROR" "Failed to generate client key for $client_name."; return 1; fi
    chmod 400 "$client_key"

    # 2. Generate Client CSR
    log "INFO" "Generating Client CSR ($client_name)..."
    log_cmd "$OPENSSL_BIN req -new \
                    -key "$client_key" \
                    -out "$client_csr" \
                    -nodes \
                    -subj "/CN=$client_name""
    if [ $? -ne 0 ]; then log "ERROR" "Failed to generate client CSR for $client_name."; return 1; fi

    # 3. Sign Client Certificate with CA
    log "INFO" "Signing Client certificate ($client_name)..."
    # Add correct escaping for newlines in printf
    log_cmd "$OPENSSL_BIN x509 -req \
                    -in \"$client_csr\" \
                    -CA \"$PKI_DIR/ca.crt\" \
                    -CAkey \"$PKI_DIR/ca.key\" \
                    -CAcreateserial \
                    -out \"$client_crt\" \
                    -days 3650 \
                    -sha256 \
                    -extfile <(printf \"basicConstraints=critical,CA:FALSE\\nkeyUsage=critical,digitalSignature\\nextendedKeyUsage=clientAuth\") \
                    -copy_extensions none"
    if [ $? -ne 0 ]; then log "ERROR" "Failed to sign client certificate for $client_name."; rm -f "$client_key" "$client_csr"; return 1; fi
    # Note: Reusing ca.srl is generally fine for sequential signing
    rm -f "$client_csr" # Remove CSR

    # 4. Create Client Configuration (.ovpn)
    log "INFO" "Generating client configuration file: ${COLOR_MAGENTA}$client_conf${COLOR_RESET}"

    # Determine remote endpoint
    local remote_host="$IP" # Default to server's listening IP
    # Use parameter expansion with hyphen to safely check if ENDPOINT is set
    if [ -n "${ENDPOINT-}" ]; then
        remote_host="$ENDPOINT" # Use public IP/hostname if provided (NAT scenario)
    fi

    # Convert PQC_KEM_ALG format for OpenSSL API compatibility
    # Remove dashes and underscores from the algorithm name
    local openvpn_kem_alg=$(echo "$PQC_KEM_ALG" | sed 's/[-_+]//g')

    # Start creating the .ovpn file
    cat > "$client_conf" << EOF
# OpenVPN PQC Client Configuration

client
dev tun
proto $PROTOCOL
remote $remote_host $PORT
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
verb 3

# TLS 1.3 Settings (match server)
# Specify preferred TLS 1.3 groups (KEMs) - Only the selected one
tls-groups "$openvpn_kem_alg"

tls-ciphersuites $TLS_CIPHERSUITES
cipher $DATA_CIPHER

# PQC Signature Algorithm used for keys/certs: $PQC_SIG_ALG

# Embedded Keys and Certificates
key-direction 1 # Required for tls-crypt

<ca>
$(cat "$PKI_DIR/ca.crt")
</ca>

<cert>
$(sed -ne '/BEGIN CERTIFICATE/,$ p' "$client_crt")
</cert>

<key>
$(cat "$client_key")
</key>

<tls-crypt>
$(cat "$PKI_DIR/ta.key")
</tls-crypt>
EOF

    # Optional: Add compression directive if enabled on server
    # if [[ $COMPRESSION_ENABLED == "y" ]]; then
    #     echo "compress lz4" >> "$client_conf"
    # fi

    chmod 600 "$client_conf" # Restrict permissions

    if [ $? -eq 0 ]; then
        log "SUCCESS" "Client configuration for '$client_name' generated: ${COLOR_MAGENTA}$client_conf${COLOR_RESET}"

        # --- Duplicate client config to /root/client/ ---
        local client_copy_dir="/root/client"
        log "INFO" "Attempting to duplicate client config to $client_copy_dir"
        mkdir -p "$client_copy_dir"
        if [ $? -ne 0 ]; then
            log "WARNING" "Failed to create directory $client_copy_dir. Skipping duplication."
        else
            cp "$client_conf" "$client_copy_dir/"
            if [ $? -eq 0 ]; then
                log "INFO" "Client config successfully duplicated to ${COLOR_MAGENTA}$client_copy_dir/${client_name}.ovpn${COLOR_RESET}"
            else
                log "WARNING" "Failed to copy client config to $client_copy_dir."
            fi
        fi
        # --- End duplication ---

    else
        log "ERROR" "Failed to write client configuration file for $client_name."
        # Attempt cleanup of keys/certs for this client
        rm -f "$client_key" "$client_crt" "$client_conf"
        return 1
    fi

    log "SUCCESS" "-------------------- END Client Config Generation ($client_name) ----------------"
    return 0
}

# --- Main Logic ---
main() {
    setup_logging
    trap copy_logs_to_root EXIT # CORRECTED: Use existing function copy_logs_to_root

    # Check prerequisites
    if ! isRoot; then log "ERROR" "This script must be run as root!"; exit 1; fi
    if ! tunAvailable; then log "ERROR" "TUN device is not available! Cannot proceed."; exit 1; fi

    # Detect OS and setup package manager commands
    check_os
    if [ -z "$OS_FAMILY" ]; then
        log "ERROR" "Unknown OS family. Cannot proceed with installation."
       exit 1
    fi

    # Check if OpenVPN (our target binary) is already installed
    local openvpn_bin="/usr/local/sbin/openvpn"
    if [[ -x "$openvpn_bin" ]]; then
        # If installed, show management menu
        manage_menu
    else
        # If not installed, proceed with installation
        log "INFO" "OpenVPN not found. Starting installation process..."

        # --- Installation Steps --- #
        log "INFO" "===== Starting PQC VPN Server Installation ===="

        # Create build directory
        mkdir -p "$BUILD_DIR"
        log "INFO" "Build directory: $BUILD_DIR"

        # 1. Install base dependencies
        install_base_dependencies

        # 2. Install OpenSSL
        install_openssl

        # 3. Set Environment Variables AFTER OpenSSL install
        log "INFO" "Setting environment variables for OpenSSL..."
        export PATH="$OPENSSL_INSTALL_DIR/bin:$PATH"
        export OPENSSL_CONF="$OPENSSL_CONF_FILE"
        log "INFO" "PATH updated: $PATH"
        log "INFO" "OPENSSL_CONF set to: $OPENSSL_CONF"
        log_cmd "ldconfig" "false" # Run ldconfig for OpenSSL libs

        # 4. Configure OpenSSL (PQC settings)
        configure_openssl_pqc

        # 5. Verify OpenSSL/PQC Installation
        if ! verify_pqc_installation; then
            log "ERROR" "PQC stack installation verification FAILED. Resolve issues before proceeding."
            exit 1
        fi
        log "SUCCESS" "OpenSSL Verification successful!"

        # 6. Install OpenVPN (linked against our OpenSSL)
        if ! install_openvpn; then
            log "ERROR" "OpenVPN installation FAILED. Check logs."
            exit 1
        fi
        log "SUCCESS" "OpenVPN Installation successful!"

        # --- Configuration Steps (after successful installation) --- #
        log "INFO" "Base components installed successfully. Proceeding with configuration..."

        # 7. Ask Configuration Questions FIRST
        ask_install_questions

        # 8. Configure Networking (Firewall, Forwarding) - Now uses user choices
        if ! configure_network; then
             log "WARNING" "Network configuration step encountered issues. VPN might not forward traffic correctly."
             # Continue script execution, but warn the user
        fi
        log "SUCCESS" "Network Configuration successful!"

        # 9. Generate PKI (CA, Server keys/certs, ta.key)
        generate_pki

        # 10. Generate Server Configuration (/etc/openvpn/server.conf)
        generate_server_config
        
        # 10.5 Setup systemd service file
        setup_systemd_service
        
        # 11. Generate First Client Configuration (.ovpn file)
        log "INFO" "Generating configuration for the first client..."
        
        # Запрашиваем имя для первого клиента
        local first_client_name=""
        read -rp "Enter a name for the client certificate: " -e first_client_name
        
        # Basic validation for client name
        if [[ -z "$first_client_name" || "$first_client_name" =~ [^a-zA-Z0-9_-] ]]; then
            log "WARNING" "Provided client name '$first_client_name' contains problematic characters. Using sanitized version."
            first_client_name=$(echo "$first_client_name" | sed 's/[^a-zA-Z0-9_-]//g')
            if [ -z "$first_client_name" ]; then
                first_client_name="Client1"
                log "WARNING" "Using generic name 'Client1' as fallback."
            fi
        fi

        if ! generate_client_config "$first_client_name"; then
            log "ERROR" "Failed to generate the first client configuration. Please check logs."
            exit 1 # Exit for now, as the first client is crucial
        fi

        log "SUCCESS" "===== OpenVPN PQC Server Installation Complete! ===="
        # Update log message to reflect the potentially derived client name
        log "INFO" "First client config: ${COLOR_MAGENTA}/root/${first_client_name}.ovpn${COLOR_RESET} (Transfer this to your client device)"
        log "INFO" "Consider starting the OpenVPN service now (e.g., using systemctl start openvpn@server or similar)."
        log "INFO" "Enabling and starting OpenVPN service..."
        log_cmd "systemctl enable openvpn-server@server.service"
        log_cmd "systemctl start openvpn-server@server.service"
        log "INFO" "Checking service status..."
        # Дать службе секунду на запуск перед проверкой статуса
        sleep 1 
        systemctl status openvpn-server@server.service --no-pager || log "WARNING" "Service status check reported issues. Please check with 'journalctl -xeu openvpn-server@server.service'."
        log "SUCCESS" "OpenVPN service enabled and started." 
    fi
}

# --- Function to select and revoke a client ---
revoke_pqc_client() {
    log "SUCCESS" "-------------------- START PQC Client Revocation --------------------"

    # Ensure PKI directory exists
    if [ ! -d "$PKI_DIR" ]; then
        log "ERROR" "PKI directory not found at $PKI_DIR. Cannot revoke clients."
        return 1
    fi

    # Ensure required PKI files exist
    touch "$PKI_DIR/index.txt"
    [ ! -f "$PKI_DIR/serial" ] && echo "01" > "$PKI_DIR/serial"
    [ ! -f "$PKI_DIR/crlnumber" ] && echo "01" > "$PKI_DIR/crlnumber"

    # List all client certificates (excluding CA and server)
    log "INFO" "Existing client certificates:"
    local client_list=()
    local count=1
    while read -r cert_file; do
        local client_name=$(basename "$cert_file" .crt)
        echo "   $count) $client_name"
        client_list+=("$client_name")
        ((count++))
    done < <(find "$PKI_DIR" -name "*.crt" -not -name "ca.crt" -not -name "server.crt" | sort)

    # User selects client to revoke
    local choice=0
    until [ "$choice" -ge 1 ] && [ "$choice" -le "${#client_list[@]}" ]; do
        read -rp "Select a client to revoke [1-${#client_list[@]}]: " choice
        if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
            choice=0
        fi
    done
    local selected_client="${client_list[$((choice-1))]}"
    log "INFO" "Selected client for revocation: $selected_client"

    # Confirm revocation
    local confirm=""
    read -rp "Are you sure you want to revoke client '$selected_client'? [y/n]: " -e confirm
    if [[ "$confirm" != "y" ]]; then
        log "INFO" "Revocation cancelled by user."
        return 0
    fi

    # Create OpenSSL CA config if not exists
    if [ ! -f "$PKI_DIR/openssl-ca.cnf" ]; then
        cat > "$PKI_DIR/openssl-ca.cnf" << EOT
[ ca ]
default_ca = CA_default

[ CA_default ]
dir               = $PKI_DIR
certs             = \$dir
new_certs_dir     = \$dir
database          = \$dir/index.txt
serial            = \$dir/serial
RANDFILE          = \$dir/.rand
private_key       = \$dir/ca.key
certificate       = \$dir/ca.crt
crlnumber         = \$dir/crlnumber
crl               = \$dir/crl.pem
crl_extensions    = crl_ext
default_md        = sha256
policy            = policy_anything
email_in_dn       = no
name_opt          = ca_default
cert_opt          = ca_default
copy_extensions   = copy

[ policy_anything ]
countryName            = optional
stateOrProvinceName    = optional
localityName           = optional
organizationName       = optional
organizationalUnitName = optional
commonName             = supplied
emailAddress           = optional

[ crl_ext ]
authorityKeyIdentifier=keyid:always
EOT
    fi

    # Rebuild index.txt with all valid certificates
    > "$PKI_DIR/index.txt"
    for cert in $(find "$PKI_DIR" -name "*.crt" -not -name "ca.crt"); do
        local cn=$("$OPENSSL_BIN" x509 -in "$cert" -noout -subject | sed -n 's/.*CN=\([^,]*\).*/\1/p')
        local serial=$("$OPENSSL_BIN" x509 -in "$cert" -noout -serial | cut -d= -f2)
        echo "V\t$(date -u +%y%m%d%H%M%SZ)\t\t$serial\tunknown\t/CN=$cn" >> "$PKI_DIR/index.txt"
    done

    # Revoke the selected certificate
    log "INFO" "Revoking certificate for client '$selected_client'..."
    "$OPENSSL_BIN" ca -config "$PKI_DIR/openssl-ca.cnf" -revoke "$PKI_DIR/$selected_client.crt" 2>/dev/null || \
        log "WARNING" "Error during certificate revocation. Continuing anyway..."

    # Generate a new CRL
    log "INFO" "Generating Certificate Revocation List (CRL)..."
    "$OPENSSL_BIN" ca -config "$PKI_DIR/openssl-ca.cnf" -gencrl -out "$PKI_DIR/crl.pem" 2>/dev/null
    if [ ! -f "$PKI_DIR/crl.pem" ]; then
        log "ERROR" "Failed to generate CRL. Client revocation may not work properly."
    else
        log "SUCCESS" "CRL generated successfully."
        chmod 644 "$PKI_DIR/crl.pem"
    fi

    # Ensure crl-verify is present in server.conf
    if ! grep -q "crl-verify" "$SERVER_CONF"; then
        log "INFO" "Updating server configuration to use CRL..."
        echo -e "\ncrl-verify $PKI_DIR/crl.pem" >> "$SERVER_CONF"
    fi

    # Restart OpenVPN server to apply changes
    log "INFO" "Restarting OpenVPN server to apply changes..."
    systemctl restart openvpn-server@server.service

    # Remove revoked client files
    log "INFO" "Removing revoked client files..."
    rm -f "$PKI_DIR/$selected_client.key" 2>/dev/null || true
    rm -f "$PKI_DIR/$selected_client.crt" 2>/dev/null || true
    rm -f "/root/$selected_client.ovpn" 2>/dev/null || true
    rm -f "/root/client/$selected_client.ovpn" 2>/dev/null || true

    log "SUCCESS" "Client '$selected_client' has been successfully revoked."
    log "SUCCESS" "-------------------- END PQC Client Revocation --------------------"
    return 0
}

# --- Function to create a new client ---
new_pqc_client() {
    log "SUCCESS" "-------------------- START PQC Client Creation --------------------"
    
    # Ask for client name
    local client_name=""
    read -rp "Enter a name for the client (letters, numbers, underscore and dash only): " -e client_name
    
    # Validate client name
    if [[ -z "$client_name" || "$client_name" =~ [^a-zA-Z0-9_-] ]]; then
        log "WARNING" "Provided client name '$client_name' contains problematic characters. Using sanitized version."
        client_name=$(echo "$client_name" | sed 's/[^a-zA-Z0-9_-]//g')
        if [ -z "$client_name" ]; then
            client_name="Client_$(date +%s)"
            log "WARNING" "Using generated name '$client_name' as fallback."
        fi
    fi
    
    # Check if client exists
    if [ -f "$PKI_DIR/$client_name.key" ] || [ -f "$PKI_DIR/$client_name.crt" ] || [ -f "/root/$client_name.ovpn" ]; then
        log "ERROR" "A client with name '$client_name' already exists. Choose a different name."
        return 1
    fi
    
    # Get server settings for client config
    # These should be read from the server.conf
    if [ -f "$SERVER_CONF" ]; then
        PORT=$(grep -E "^port " "$SERVER_CONF" | awk '{print $2}')
        PROTOCOL=$(grep -E "^proto " "$SERVER_CONF" | awk '{print $2}')
        DATA_CIPHER=$(grep -E "^cipher " "$SERVER_CONF" | awk '{print $2}')
        TLS_CIPHERSUITES=$(grep -E "^tls-ciphersuites " "$SERVER_CONF" | sed 's/^tls-ciphersuites //')
        PQC_KEM_ALG=$(grep -E "^tls-groups " "$SERVER_CONF" | sed 's/^tls-groups //;s/"//g')
        
        # Get server IP or hostname
        IP=$(ip -4 addr | sed -ne 's|^.* inet \([^/]*\)/.* scope global.*$|\1|p' | head -1)
        
        # Try to detect if server is behind NAT
        if echo "$IP" | grep -qE '^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168)'; then
            # Try to get public IP
            ENDPOINT=$(curl -4 -f -m 5 -sS --retry 2 https://api.seeip.org 2>/dev/null || curl -4 -f -m 5 -sS --retry 2 https://ifconfig.me 2>/dev/null || curl -4 -f -m 5 -sS --retry 2 https://api.ipify.org 2>/dev/null)
            if [ -z "$ENDPOINT" ]; then
                read -rp "Server is behind NAT. Enter public IP or hostname: " -e ENDPOINT
            fi
        fi
        
        # Try to detect PQC signature algorithm from CA or server key
        if [ -f "$PKI_DIR/ca.key" ]; then
            PQC_SIG_ALG=$("$OPENSSL_BIN" pkey -in "$PKI_DIR/ca.key" -text 2>/dev/null | grep -o "ML-DSA-[0-9]\\+\\|SLH-DSA-SHA2-[0-9]\\+f" | head -1)
        elif [ -f "$PKI_DIR/server.key" ]; then
            PQC_SIG_ALG=$("$OPENSSL_BIN" pkey -in "$PKI_DIR/server.key" -text 2>/dev/null | grep -o "ML-DSA-[0-9]\\+\\|SLH-DSA-SHA2-[0-9]\\+f" | head -1)
        fi

        if [ -z "$PQC_SIG_ALG" ]; then
            log "ERROR" "Could not detect PQC signature algorithm from CA or server key. Please check your PKI."
            return 1
        fi
    else
        log "ERROR" "Server configuration file not found at $SERVER_CONF. Cannot create client configuration."
        return 1
    fi
    
    # Generate client configuration
    log "INFO" "Generating client configuration for '$client_name'..."
    if generate_client_config "$client_name"; then
        log "SUCCESS" "Client configuration for '$client_name' has been successfully generated."
        log "INFO" "Configuration file is available at /root/$client_name.ovpn"
        log "INFO" "Copy this file to your client device to establish the VPN connection."
    else
        log "ERROR" "Failed to generate client configuration. Check logs for details."
        return 1
    fi
    
    log "SUCCESS" "-------------------- END PQC Client Creation --------------------"
    return 0
}

# Run main
main

# Environment variables are set within main() now
# ... (cleanup at end remains same) ...