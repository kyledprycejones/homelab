#!/bin/bash

# Script to install common Synology packages via CLI
# Run as admin user with SSH access enabled on Synology DSM

# List of common packages to install (modify as needed)
PACKAGES=(
    "HyperBackup"        # Backup and restore tool
    "FileStation"        # File management
    "DownloadStation"    # Download manager
    "MediaServer"        # DLNA/UPnP media streaming
    "AudioStation"       # Music streaming
    "VideoStation"       # Video streaming
    "SynologyDrive"      # Cloud sync and file sharing
    "WebStation"         # Web server hosting
    "SynologyPhotos"     # Photo management
)

# Log file for installation output
LOG_FILE="/tmp/synology_setup_$(date +%F_%H-%M-%S).log"

# Function to log messages
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Function to check if a package is installed
is_package_installed() {
    local pkg_name="$1"
    /usr/syno/bin/synopkg list | grep -q "^$pkg_name"
    return $?
}

# Function to install a package
install_package() {
    local pkg_name="$1"
    log_message "Checking if $pkg_name is already installed..."
    if is_package_installed "$pkg_name"; then
        log_message "$pkg_name is already installed. Skipping."
        return 0
    fi

    log_message "Installing $pkg_name..."
    if /usr/syno/bin/synopkg install_from_center "$pkg_name" >> "$LOG_FILE" 2>&1; then
        log_message "$pkg_name installed successfully."
        return 0
    else
        log_message "Failed to install $pkg_name. Check $LOG_FILE for details."
        return 1
    fi
}

# Main script
log_message "Starting Synology package setup..."

# Check if running as root or admin
if [[ $EUID -ne 0 ]]; then
    log_message "ERROR: This script must be run as root or admin. Exiting."
    exit 1
fi

# Check if synopkg is available
if ! command -v /usr/syno/bin/synopkg &> /dev/null; then
    log_message "ERROR: synopkg not found. Ensure DSM is properly configured. Exiting."
    exit 1
fi

# Install each package
failures=0
for pkg in "${PACKAGES[@]}"; do
    install_package "$pkg"
    if [[ $? -ne 0 ]]; then
        ((failures++))
    fi
done

# Summary
log_message "Setup complete!"
if [[ $failures -eq 0 ]]; then
    log_message "All packages installed successfully."
else
    log_message "$failures package(s) failed to install. Check $LOG_FILE for details."
fi

log_message "Log file: $LOG_FILE"
exit $failures