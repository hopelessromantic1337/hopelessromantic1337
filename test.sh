#!/bin/bash

# Enable strict mode
set -euo pipefail

# Log file for debugging
LOG_FILE="/tmp/test.sh.log"
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE" >&2
}

# Cleanup function for errors
cleanup() {
    log "Error occurred. Cleaning up..."
    rm -rf ELF || true
    pkill -f /usr/local/bin/clock.sh || true
    exit 1
}

# Set trap for errors
trap cleanup ERR

# Source functions
FUNCTIONS_FILE="$(dirname "$0")/functions.sh"
if [[ ! -f "$FUNCTIONS_FILE" ]]; then
    log "Functions file $FUNCTIONS_FILE not found."
    exit 1
fi
source "$FUNCTIONS_FILE"

# Run unit tests if --test flag is provided
if [[ "${1:-}" == "--test" ]]; then
    log "Running unit tests..."
    apt update -y && apt install -y bats || { log "Failed to install bats"; exit 1; }
    if [[ ! -f "$(dirname "$0")/tests/test_functions.bats" ]]; then
        log "Test file not found."
        exit 1
    fi
    bats "$(dirname "$0")/tests/test_functions.bats" || { log "Unit tests failed"; exit 1; }
    log "Unit tests passed."
    exit 0
fi

# Root check
if [[ "$(id -u)" -ne 0 ]]; then
    log "Need to be root to execute this command."
    exit 1
fi

# Check network connectivity
log "Checking network connectivity..."
if ! ping -c 1 -W 2 8.8.8.8 &> /dev/null; then
    log "No network connectivity. Please check your connection."
    exit 1
fi

# Verify essential commands
log "Verifying essential commands..."
for cmd in curl git make bc hwclock cron; do
    if ! command -v "$cmd" &> /dev/null; then
        log "Required command '$cmd' not found. Installing dependencies..."
        apt update -y || { log "Failed to run apt update"; exit 1; }
        apt install -y curl git build-essential bc cron || { log "Failed to install dependencies"; exit 1; }
        break
    fi
done

# Ensure cron service is running
log "Ensuring cron service is running..."
service cron start || { log "Failed to start cron service"; exit 1; }

# Update/upgrade
log "Updating and upgrading packages..."
apt update -y || { log "Failed to run apt update"; exit 1; }
apt full-upgrade -y || { log "Failed to run apt full-upgrade"; exit 1; }

# Install required packages
log "Installing dependencies..."
apt install -y curl aria2 build-essential git bc cron || { log "Failed to install dependencies"; exit 1; }

# Install apt-fast if missing
if ! command -v apt-fast &> /dev/null; then
    log "Installing apt-fast..."
    for attempt in {1..3}; do
        installer=$(curl -sL --retry 3 --retry-delay 5 https://git.io/vokNn) && break
        log "Failed to fetch apt-fast installer (attempt $attempt/3)"
        [[ $attempt -eq 3 ]] && { log "Failed to fetch apt-fast installer"; exit 1; }
    done
    if [[ -z "$installer" ]]; then
        log "Empty apt-fast installer script downloaded."
        exit 1
    fi
    bash -c "$installer" || { log "Failed to install apt-fast"; exit 1; }
    command -v apt-fast &> /dev/null || { log "apt-fast not installed correctly"; exit 1; }
fi

# Install pkgs with apt-fast
log "Installing packages with apt-fast..."
apt-fast install -y curl aria2 build-essential git bc cron || { log "Failed to install packages with apt-fast"; exit 1; }

# Install apt-mirror
log "Installing apt-mirror..."
apt-fast install -y apt-mirror || { log "Failed to install apt-mirror"; exit 1; }

# Download and configure mirror.list
log "Downloading mirror.list from GitHub..."
curl -sL https://raw.githubusercontent.com/apt-mirror/apt-mirror/refs/heads/master/mirror.list -o /etc/apt/mirror.list || { log "Failed to download mirror.list"; exit 1; }

# Create /var/spool/apt-mirror directory if not exists
log "Preparing apt-mirror directory..."
mkdir -p /var/spool/apt-mirror || { log "Failed to create /var/spool/apt-mirror"; exit 1; }

# Run apt-mirror to set up the local mirror
log "Running apt-mirror to initialize local repository..."
apt-mirror || { log "Failed to run apt-mirror"; exit 1; }

# Add local mirror to sources.list
log "Adding local mirror to /etc/apt/sources.list..."
echo "deb file:/var/spool/apt-mirror/mirror/archive.ubuntu.com/ubuntu/ focal main restricted" >> /etc/apt/sources.list || { log "Failed to update sources.list"; exit 1; }
echo "deb file:/var/spool/apt-mirror/mirror/archive.ubuntu.com/ubuntu/ focal-updates main restricted" >> /etc/apt/sources.list || { log "Failed to update sources.list"; exit 1; }
echo "deb file:/var/spool/apt-mirror/mirror/archive.ubuntu.com/ubuntu/ focal-security main restricted" >> /etc/apt/sources.list || { log "Failed to update sources.list"; exit 1; }

# Update package lists from local mirror
log "Updating package lists from local mirror..."
apt update -y || { log "Failed to update from local mirror"; exit 1; }

# Set up cron job for apt-mirror updates
log "Setting up cron job for apt-mirror updates..."
CRON_JOB="0 2 * * 0 /usr/bin/apt-mirror"
if ! crontab -l 2>/dev/null | grep -q "/usr/bin/apt-mirror"; then
    (crontab -l 2>/dev/null || true; echo "$CRON_JOB") | crontab - || { log "Failed to set up cron job"; exit 1; }
else
    log "Cron job for apt-mirror already exists. Skipping."
fi
if ! crontab -l 2>/dev/null | grep -q "/usr/bin/apt-mirror"; then
    log "Cron job verification failed."
    exit 1
fi

# Add user 'oper' if not exists
if ! id -u oper &> /dev/null; then
    log "Creating user 'oper'..."
    useradd -m oper || { log "Failed to create user 'oper'"; exit 1; }
    # Use environment variable or generate password
    if [[ -n "${OPER_PASSWORD:-}" ]]; then
        log "Using provided OPER_PASSWORD..."
        check_password_strength "$OPER_PASSWORD" || { log "Provided password is weak"; exit 1; }
        echo "oper:$OPER_PASSWORD" | chpasswd || { log "Failed to set password"; exit 1; }
    else
        log "Generating random password for oper..."
        password=$(head /dev/urandom | tr -dc A-Za-z0-9@#\$% | head -c 16) || { log "Failed to generate password"; exit 1; }
        check_password_strength "$password" || { log "Generated password is weak"; exit 1; }
        echo "oper:$password" | chpasswd || { log "Failed to set password"; exit 1; }
        log "Generated password for oper: $password"
    fi
    unset password OPER_PASSWORD
else
    log "User 'oper' already exists. Skipping creation."
fi

# Clone/build/install
log "Cloning ELFkickers..."
for attempt in {1..3}; do
    git clone https://github.com/BR903/ELFkickers ELF && break
    log "Failed to clone ELFkickers (attempt $attempt/3)"
    [[ $attempt -eq 3 ]] && { log "Failed to clone ELFkickers"; exit 1; }
    sleep 5
done
if [[ ! -d ELF ]]; then
    log "ELF directory not created after git clone."
    exit 1
fi
pushd ELF || { log "Failed to enter ELF directory"; exit 1; }
log "Building and installing ELFkickers..."
make || { log "Failed to run make"; exit 1; }
make install || { log "Failed to run make install"; exit 1; }
popd || { log "Failed to exit ELF directory"; exit 1; }

# Copy sysctl if exists
if [[ -f ELF/sysctl.conf ]]; then
    log "Copying sysctl.conf..."
    cp ELF/sysctl.conf /etc/sysctl.conf || { log "Failed to copy sysctl.conf"; exit 1; }
    sysctl -p || { log "Failed to apply sysctl settings"; exit 1; }
else
    log "No sysctl.conf found in ELF directory. Skipping."
fi

# Remove cloned dir
log "Cleaning up ELF directory..."
rm -rf ELF || { log "Failed to remove ELF directory"; exit 1; }

# Create clock.sh
log "Creating clock.sh..."
cat <<EOF > /usr/local/bin/clock.sh
#!/bin/bash
while true; do
    sleep 5
    /sbin/hwclock --hctosys
done
EOF
if [[ ! -f /usr/local/bin/clock.sh ]]; then
    log "Failed to create /usr/local/bin/clock.sh"
    exit 1
fi

# Make exec
log "Making clock.sh executable..."
chmod +x /usr/local/bin/clock.sh || { log "Failed to make clock.sh executable"; exit 1; }

# Run clock.sh in background (container-friendly)
log "Starting clock.sh in background..."
pkill -f /usr/local/bin/clock.sh || true
nohup /usr/local/bin/clock.sh >/tmp/clock.log 2>&1 &
sleep 1
if ! pgrep -f /usr/local/bin/clock.sh &> /dev/null; then
    log "Failed to start clock.sh in background. Check /tmp/clock.log for details."
    cat /tmp/clock.log >> "$LOG_FILE"
    exit 1
fi

# Reset trap
trap - ERR
log "Script completed successfully."
