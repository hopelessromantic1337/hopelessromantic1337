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
    pkill -f /usr/local/bin/clock_sync.sh || true
    systemctl stop clock-sync.service || true
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
for cmd in curl git make bc hwclock cron timedatectl; do
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

# Create clock_sync.sh
log "Creating clock_sync.sh..."
cat <<EOF > /usr/local/bin/clock_sync.sh
#!/bin/bash

# Configuration
NTP_SERVERS="pool.ntp.org time.google.com"
LOG_FILE="/var/log/clock_sync.log"
MAX_DRIFT=0.5  # Maximum allowed clock drift in seconds
RETRY_COUNT=3
RETRY_DELAY=10
CHECK_INTERVAL=300  # Check every 5 minutes

# Logging function
log_message() {
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - \$1" >> "\$LOG_FILE"
    logger -t clock_sync "\$1"  # Log to syslog
}

# Check if NTP servers are reachable
check_ntp() {
    for server in \$NTP_SERVERS; do
        if ping -c 1 \$server >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

# Sync clock using timedatectl or chronyd
sync_clock() {
    local attempt=1
    while [ \$attempt -le \$RETRY_COUNT ]; do
        log_message "Sync attempt \$attempt of \$RETRY_COUNT"

        # Try systemd-timesyncd or chrony
        if systemctl is-active --quiet systemd-timesyncd || systemctl is-active --quiet chronyd; then
            if check_ntp; then
                if timedatectl set-ntp true; then
                    log_message "Successfully synced with NTP via systemd-timesyncd/chronyd"
                    # Update hardware clock
                    timedatectl set-local-rtc 0 >/dev/null 2>&1
                    hwclock --systohc --utc >/dev/null 2>&1
                    return 0
                fi
            fi
        fi

        # Fallback to hardware clock
        log_message "NTP sync failed, falling back to hardware clock"
        if hwclock --hctosys --utc; then
            log_message "Successfully synced with hardware clock"
            return 0
        fi

        log_message "Sync attempt \$attempt failed"
        sleep \$RETRY_DELAY
        ((attempt++))
    done
    return 1
}

# Main loop
while true; do
    # Check system clock drift using timedatectl
    if timedatectl show | grep -q "NTPSynchronized=yes"; then
        drift=\$(timedatectl | grep "System clock synchronized" -A1 | grep "offset" | awk '{print \$3}' | tr -d '+-ms')
        drift=\$(echo "\$drift / 1000" | bc -l)  # Convert ms to seconds
        if [ -n "\$drift" ] && [ \$(echo "\$drift > \$MAX_DRIFT" | bc -l) -eq 1 ]; then
            log_message "Clock drift \$drift seconds exceeds threshold \$MAX_DRIFT"
            if sync_clock; then
                log_message "Clock synchronized successfully"
            else
                log_message "Failed to synchronize clock after \$RETRY_COUNT attempts"
            fi
        else
            log_message "Clock drift \$drift seconds within threshold"
        fi
    else
        log_message "NTP not synchronized, attempting sync"
        sync_clock
    fi
    sleep \$CHECK_INTERVAL
done
EOF

# Verify file creation
if [[ ! -f /usr/local/bin/clock_sync.sh ]]; then
    log "Failed to create /usr/local/bin/clock_sync.sh"
    exit 1
fi

# Make executable
log "Making clock_sync.sh executable..."
chmod +x /usr/local/bin/clock_sync.sh || { log "Failed to make clock_sync.sh executable"; exit 1; }

# Create systemd service
log "Creating systemd service for clock synchronization..."
cat <<EOF > /etc/systemd/system/clock-sync.service
[Unit]
Description=Advanced Clock Synchronization Service
After=network-online.target systemd-timesyncd.service chronyd.service
Wants=network-online.target systemd-timesyncd.service chronyd.service
ConditionFileIsExecutable=/usr/local/bin/clock_sync.sh

[Service]
Type=simple
ExecStart=/usr/local/bin/clock_sync.sh
Restart=on-failure
RestartSec=10
TimeoutStartSec=60
TimeoutStopSec=30
StartLimitIntervalSec=60
StartLimitBurst=3
User=nobody
Group=nogroup
Nice=19
CPUSchedulingPolicy=idle
MemoryLimit=50M
ProtectSystem=strict
ReadWritePaths=/var/log/clock_sync.log
ProtectHome=true
PrivateTmp=true
NoNewPrivileges=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
StandardOutput=journal
StandardError=journal
Environment="LOG_FILE=/var/log/clock_sync.log"

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd and enable service
log "Enabling and starting clock-sync service..."
systemctl daemon-reload || { log "Failed to reload systemd daemon"; exit 1; }
systemctl enable clock-sync.service || { log "Failed to enable clock-sync service"; exit 1; }
systemctl start clock-sync.service || { log "Failed to start clock-sync service"; exit 1; }

# Verify service is running
sleep 1
if ! systemctl is-active --quiet clock-sync.service; then
    log "Clock sync service failed to start. Check journalctl -u clock-sync.service for details."
    journalctl -u clock-sync.service -n 50 >> "$LOG_FILE"
    exit 1
fi

# Ensure chrony or systemd-timesyncd is installed
log "Checking NTP client installation..."
if ! systemctl is-active --quiet systemd-timesyncd && ! command -v chronyd >/dev/null 2>&1; then
    log "Installing chrony..."
    apt-get update && apt-get install -y chrony || { log "Failed to install chrony"; exit 1; }
    systemctl enable chronyd || { log "Failed to enable chronyd"; exit 1; }
    systemctl start chronyd || { log "Failed to start chronyd"; exit 1; }
fi

# Configure chrony if installed
if command -v chronyd >/dev/null 2>&1; then
    log "Configuring chrony NTP servers..."
    cat <<EOF > /etc/chrony/chrony.conf
server pool.ntp.org iburst
server time.google.com iburst
driftfile /var/lib/chrony/chrony.drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF
    systemctl restart chronyd || { log "Failed to restart chronyd"; exit 1; }
fi

# Reset trap
trap - ERR
log "Script completed successfully."
