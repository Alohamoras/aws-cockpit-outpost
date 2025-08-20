#!/bin/bash
# AWS EC2 User Data Script for Cockpit Installation on Amazon Linux 2023
# This script installs and configures Cockpit with various modules

# Exit on any error
set -e

# Log all output to file for debugging
exec > >(tee -a /var/log/user-data.log)
exec 2>&1
echo "Starting Cockpit installation at $(date)"

# Update the system
echo "Updating system packages..."
dnf update -y

# Install Cockpit and required modules
echo "Installing Cockpit and modules..."
dnf install -y \
    cockpit \
    cockpit-machines \
    cockpit-podman \
    cockpit-networkmanager \
    cockpit-storaged \
    cockpit-system \
    cockpit-ws \
    cockpit-packagekit \
    cockpit-pcp \
    cockpit-sosreport

# Install additional dependencies for virtualization (for cockpit-machines)
echo "Installing virtualization dependencies..."
dnf install -y \
    libvirt \
    libvirt-client \
    virt-install \
    virt-manager \
    qemu-kvm

# Install Podman (for cockpit-podman)
echo "Installing Podman..."
dnf install -y podman

# Install performance monitoring tools (for cockpit-pcp)
echo "Installing PCP for performance monitoring..."
dnf install -y pcp pcp-system-tools

# Install third-party modules (optional but recommended)
echo "Installing third-party Cockpit modules..."

# Install file sharing module from 45Drives
if ! rpm -q cockpit-file-sharing &>/dev/null; then
    dnf install -y https://github.com/45Drives/cockpit-file-sharing/releases/download/v3.3.4/cockpit-file-sharing-3.3.4-1.el9.noarch.rpm || \
    echo "Warning: Could not install cockpit-file-sharing"
fi

# Install file navigator from 45Drives
if ! rpm -q cockpit-navigator &>/dev/null; then
    dnf install -y https://github.com/45Drives/cockpit-navigator/releases/download/v0.5.10/cockpit-navigator-0.5.10-1.el9.noarch.rpm || \
    echo "Warning: Could not install cockpit-navigator"
fi

# Check if running on bare metal instance and install sensor monitoring
echo "Checking instance type for sensor support..."
INSTANCE_TYPE=$(curl -s http://169.254.169.254/latest/meta-data/instance-type || echo "unknown")
if [[ "$INSTANCE_TYPE" == *".metal"* ]]; then
    echo "Bare metal instance detected ($INSTANCE_TYPE), installing sensor monitoring..."
    dnf install -y lm_sensors || echo "Warning: Could not install lm_sensors"
    
    # Try to install cockpit-sensors from 45Drives
    if ! rpm -q cockpit-sensors &>/dev/null; then
        dnf install -y https://github.com/45Drives/cockpit-sensors/releases/download/v2.0.0/cockpit-sensors-2.0.0-1.el9.noarch.rpm || \
        echo "Warning: Could not install cockpit-sensors"
    fi
    
    # Auto-detect sensors
    echo "Detecting available hardware sensors..."
    sensors-detect --auto &>/dev/null || echo "Warning: Sensor detection failed"
    
    # Display detected sensors
    echo "Available sensors:"
    sensors 2>/dev/null || echo "No sensors detected"
else
    echo "Virtual instance detected ($INSTANCE_TYPE), skipping sensor monitoring"
fi

# Enable and start required services
echo "Enabling and starting services..."

# Enable Cockpit socket (will start on demand)
systemctl enable --now cockpit.socket

# Enable and start libvirtd for VM management
systemctl enable --now libvirtd

# Enable and start Podman socket for container management
systemctl enable --now podman.socket

# Enable NetworkManager (usually already enabled on Amazon Linux)
systemctl enable --now NetworkManager

# Enable PCP for performance monitoring
systemctl enable --now pmcd
systemctl enable --now pmlogger

# Configure firewall to allow Cockpit access
echo "Configuring firewall..."
# Check if firewalld is installed and running
if systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-service=cockpit
    firewall-cmd --reload
else
    echo "Firewalld not active, skipping firewall configuration"
    echo "Make sure to configure your EC2 Security Group to allow port 9090"
fi

# Create a systemd service to ensure Cockpit starts on boot
echo "Creating Cockpit startup service..."
cat > /etc/systemd/system/cockpit-startup.service << 'EOF'
[Unit]
Description=Ensure Cockpit is running
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl start cockpit.socket
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Enable the startup service
systemctl daemon-reload
systemctl enable cockpit-startup.service

# Configure Cockpit settings
echo "Configuring Cockpit settings..."
mkdir -p /etc/cockpit
cat > /etc/cockpit/cockpit.conf << 'EOF'
[WebService]
AllowUnencrypted=false
LoginTitle=EC2 Cockpit Interface

[Session]
IdleTimeout=15
EOF

# Set up ec2-user for Cockpit access (if needed)
echo "Configuring ec2-user for Cockpit access..."
if id "ec2-user" &>/dev/null; then
    # Add ec2-user to required groups for full functionality
    usermod -a -G libvirt ec2-user
    usermod -a -G wheel ec2-user
    echo "ec2-user configured for Cockpit access"
fi

# Display access information
INSTANCE_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 || echo "IP_NOT_AVAILABLE")
echo ""
echo "==========================================="
echo "Cockpit Installation Complete!"
echo "==========================================="
echo "Access Cockpit at: https://${INSTANCE_IP}:9090"
echo "Login with: ec2-user and your SSH key or password"
echo ""
echo "Installed modules:"
echo "  - cockpit-machines (VM management)"
echo "  - cockpit-podman (Container management)"
echo "  - cockpit-networkmanager (Network configuration)"
echo "  - cockpit-storaged (Storage management)"
echo "  - cockpit-packagekit (Package management)"
echo "  - cockpit-pcp (Performance monitoring)"
echo "  - cockpit-sosreport (Diagnostic reports)"
echo "  - cockpit-file-sharing (NFS/Samba management) [if available]"
echo "  - cockpit-navigator (File browser) [if available]"
if [[ "$INSTANCE_TYPE" == *".metal"* ]]; then
    echo "  - cockpit-sensors (Hardware sensors) [bare metal instance]"
fi
echo ""
echo "IMPORTANT: Ensure your EC2 Security Group allows:"
echo "  - Inbound TCP port 9090 from your IP"
echo "==========================================="

# Create a welcome message file
cat > /etc/motd.d/cockpit-info << EOF
=========================================
Cockpit is installed and running!
Access: https://${INSTANCE_IP}:9090
=========================================
EOF

echo "User data script completed at $(date)"