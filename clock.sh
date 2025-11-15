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
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/clock_sync.sh
Restart=always
RestartSec=10
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
