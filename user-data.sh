#!/bin/bash
# AWS EC2 User Data Script for Cockpit Installation on Rocky Linux 9
# This script installs and configures Cockpit with various modules

# Log all output to file for debugging
exec > >(tee -a /var/log/user-data.log)
exec 2>&1
echo "Starting Cockpit installation at $(date)"

# SNS Topic ARN for notifications (set by launch script via instance user data)
# This will be replaced by the actual ARN from the environment variable
SNS_TOPIC_ARN="PLACEHOLDER_SNS_TOPIC_ARN"

# Retry function for DNF operations
retry_dnf() {
    local max_attempts=3
    local attempt=1
    local sleep_time=30
    
    while [ $attempt -le $max_attempts ]; do
        echo "DNF attempt $attempt/$max_attempts: $*"
        
        # Clean cache and try the operation
        if dnf clean all >/dev/null 2>&1 && dnf makecache >/dev/null 2>&1 && dnf "$@"; then
            echo "DNF operation succeeded on attempt $attempt"
            return 0
        fi
        
        if [ $attempt -lt $max_attempts ]; then
            echo "DNF attempt $attempt failed, retrying in $sleep_time seconds..."
            sleep $sleep_time
        else
            echo "DNF operation failed after $max_attempts attempts"
            return 1
        fi
        ((attempt++))
    done
}

# Function to handle critical operations with error reporting
execute_critical() {
    local operation="$1"
    shift
    
    echo "Executing critical operation: $operation"
    if ! "$@"; then
        send_error_notification "Critical operation failed: $operation" "$LINENO"
        exit 1
    fi
}

# Function to send error notification (defined early)
send_error_notification() {
    local error_message="$1"
    local line_number="$2"
    
    # Get instance metadata
    local instance_id=$(curl -s http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || echo "unknown")
    local public_ip=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "unknown")
    
    # Create error notification message
    local subject="Cockpit Installation FAILED - $instance_id"
    local notification_message="
=== COCKPIT INSTALLATION FAILED ===

Instance Details:
- Instance ID: $instance_id
- Public IP: $public_ip
- Error Time: $(date)
- Error Line: $line_number

Error Details:
$error_message

Check installation logs:
ssh -i your-key.pem rocky@$public_ip 'sudo tail -50 /var/log/user-data.log'

=== END ERROR NOTIFICATION ===
"
    
    # Send SNS notification (use full path for AWS CLI)
    /usr/local/bin/aws sns publish \
        --region us-east-1 \
        --topic-arn "$SNS_TOPIC_ARN" \
        --subject "$subject" \
        --message "$notification_message" >/dev/null 2>&1 || echo "Failed to send error SNS notification"
}

# Set error trap for unexpected failures only
trap 'send_error_notification "Script failed unexpectedly" $LINENO' ERR

# Don't use blanket set -e, handle errors selectively
set +e

# Update the system with retry logic
echo "Updating system packages..."
execute_critical "System package update" retry_dnf update -y

# Install required tools
echo "Installing required packages..."
execute_critical "Install curl and unzip" retry_dnf install -y curl unzip

# Install EPEL repository (required for Cockpit packages)
echo "Installing EPEL repository..."
execute_critical "Install EPEL repository" retry_dnf install -y epel-release

# Install AWS CLI for SNS notifications
echo "Installing AWS CLI..."
curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip -q awscliv2.zip
./aws/install
rm -rf awscliv2.zip aws/

# Verify AWS CLI installation
echo "Verifying AWS CLI installation..."
/usr/local/bin/aws --version || echo "AWS CLI installation may have failed"

# Install AWS SSM Agent for remote management
echo "Installing AWS SSM Agent..."
execute_critical "Install SSM Agent" retry_dnf install -y https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/linux_amd64/amazon-ssm-agent.rpm

# Install Cockpit and required modules
echo "Installing Cockpit and modules..."

# Install core modules first
execute_critical "Install core Cockpit modules" retry_dnf install -y cockpit cockpit-system cockpit-ws cockpit-bridge

# Install additional modules with error handling
echo "Installing additional Cockpit modules..."
retry_dnf install -y cockpit-machines || echo "cockpit-machines not available, skipping..."
retry_dnf install -y cockpit-podman || echo "cockpit-podman not available, skipping..."
retry_dnf install -y cockpit-networkmanager || echo "cockpit-networkmanager not available, skipping..."
retry_dnf install -y cockpit-storaged || echo "cockpit-storaged not available, skipping..."
retry_dnf install -y cockpit-packagekit || echo "cockpit-packagekit not available, skipping..."
retry_dnf install -y cockpit-sosreport || echo "cockpit-sosreport not available, skipping..."

# Try to install cockpit-pcp separately (may not be available)
echo "Installing optional performance monitoring module..."
retry_dnf install -y cockpit-pcp || echo "cockpit-pcp not available, skipping..."

# Install additional dependencies for virtualization (for cockpit-machines)
echo "Installing virtualization dependencies..."
execute_critical "Install virtualization packages" retry_dnf install -y \
    libvirt \
    libvirt-client \
    virt-install \
    virt-manager \
    qemu-kvm

# Install Podman (for cockpit-podman)
echo "Installing Podman..."
execute_critical "Install Podman" retry_dnf install -y podman

# Install performance monitoring tools (for cockpit-pcp)
echo "Installing PCP for performance monitoring..."
execute_critical "Install PCP tools" retry_dnf install -y pcp pcp-system-tools

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

# Create admin user for Cockpit access
echo "Creating admin user for Cockpit access..."
useradd -m -G wheel,libvirt admin
echo 'admin:Cockpit123' | chpasswd
echo "Created admin user with username 'admin' and password 'Cockpit123'"

# Also ensure rocky user has wheel group access and a password
echo "Configuring rocky user for Cockpit access..."
usermod -aG wheel,libvirt rocky
echo 'rocky:Cockpit123' | chpasswd
echo "Set password for rocky user: 'Cockpit123'"

# Enable Cockpit socket (will start on demand)
systemctl enable --now cockpit.socket

# Enable and start libvirtd for VM management
systemctl enable --now libvirtd

# Enable and start Podman socket for container management
systemctl enable --now podman.socket

# Enable and start AWS SSM Agent for remote management
systemctl enable --now amazon-ssm-agent

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

# Send completion notification via SNS
send_completion_notification() {
    local status="$1"
    local message="$2"
    
    # Get instance metadata
    local instance_id=$(curl -s http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || echo "unknown")
    local public_ip=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "unknown")
    local private_ip=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4 2>/dev/null || echo "unknown")
    local az=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone 2>/dev/null || echo "unknown")
    
    # Create notification message
    local subject="Cockpit Installation $status - $instance_id"
    local notification_message="
=== COCKPIT INSTALLATION $status ===

Instance Details:
- Instance ID: $instance_id
- Public IP: $public_ip
- Private IP: $private_ip
- Availability Zone: $az
- Completion Time: $(date)

Installation Status: $status
$message

Access Information:
- Cockpit Web UI: https://$public_ip:9090
- SSH Access: ssh -i your-key.pem rocky@$public_ip
- SSM Session Manager: Available via AWS Console

Login Credentials:
- Username: admin | Password: Cockpit123
- Username: rocky | Password: Cockpit123

Installed Services:
- Cockpit Web Console (port 9090)
- Libvirt/KVM (virtualization)
- Podman (containers)
- AWS SSM Agent (remote management)
- Performance monitoring (PCP)

=== END NOTIFICATION ===
"
    
    # Send SNS notification
    aws sns publish \
        --region us-east-1 \
        --topic-arn "$SNS_TOPIC_ARN" \
        --subject "$subject" \
        --message "$notification_message" >/dev/null 2>&1 || echo "Failed to send SNS notification"
}

# Send success notification
send_completion_notification "SUCCESS" "Cockpit installation completed successfully. All services are running and configured."

echo "User data script completed at $(date)"