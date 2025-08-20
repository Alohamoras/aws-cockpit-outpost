# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository contains AWS EC2 user data automation for installing and configuring Red Hat Cockpit web console on Amazon Linux 2023. The script provides a comprehensive Cockpit deployment with extensive module support, virtualization capabilities, container management, and performance monitoring.

## Common Commands

### Deploy User Data Script
```bash
# Use as EC2 user data during instance launch
aws ec2 run-instances \
    --image-id ami-12345678 \
    --instance-type c6id.8xlarge \
    --key-name IAD-Key-2 \
    --security-group-ids sg-00d78386844b03850 \
    --subnet-id subnet-1b6ebe47 \
    --user-data file://user-data.sh

# Monitor user data execution after instance launch
ssh -i ~/.ssh/IAD-Key-2.pem ec2-user@<PUBLIC_IP> "sudo tail -f /var/log/user-data.log"
```

### Testing and Validation
```bash
# Test script syntax
bash -n user-data.sh

# Validate specific sections (useful during development)
bash -x user-data.sh 2>&1 | grep "Installing"
```

### Access Cockpit Interface
```bash
# Web interface access
https://<EC2_PUBLIC_IP>:9090

# Check service status via SSH
systemctl status cockpit.socket
systemctl status libvirtd
systemctl status podman.socket
```

## Architecture

The user data script follows a modular installation approach with comprehensive error handling and conditional deployments:

### Core Installation Phases

1. **System Preparation**: Updates Amazon Linux 2023 packages using dnf
2. **Base Cockpit Installation**: Installs core Cockpit modules (machines, podman, networkmanager, storaged, system, ws, packagekit, pcp, sosreport)
3. **Virtualization Stack**: Configures libvirt, QEMU-KVM, and virt-manager for VM management
4. **Container Platform**: Installs and configures Podman with socket activation
5. **Performance Monitoring**: Enables PCP (Performance Co-Pilot) for system metrics
6. **Third-party Modules**: Conditionally installs 45Drives modules (file-sharing, navigator, sensors)
7. **Hardware Detection**: Identifies bare metal instances and configures sensor monitoring
8. **Service Configuration**: Enables all required systemd services with proper dependencies

### Conditional Logic Patterns

- **Instance Type Detection**: Uses EC2 metadata to identify bare metal instances for sensor support
- **Service Availability**: Checks if services exist before configuration (firewalld handling)
- **Package Installation**: Graceful failure handling for optional third-party RPMs
- **Hardware Sensors**: Auto-detection only on bare metal instances using lm_sensors

### Security Configuration

- **TLS-Only Access**: Cockpit configured to disallow unencrypted connections
- **Firewall Integration**: Automatic firewall rule creation when firewalld is active
- **User Permissions**: Configures ec2-user with appropriate group memberships (libvirt, wheel)
- **Session Management**: 15-minute idle timeout for security

### Service Dependencies

The script establishes proper service startup order:
- NetworkManager → libvirtd → Podman socket
- PCP daemons (pmcd, pmlogger) for performance monitoring
- Custom cockpit-startup.service ensures Cockpit availability on boot

### Third-party Module Integration

Uses direct RPM installation from GitHub releases:
- **cockpit-file-sharing**: NFS/Samba management interface
- **cockpit-navigator**: Advanced file browser with upload/download
- **cockpit-sensors**: Hardware monitoring for bare metal instances

All third-party installations include error handling to prevent script failure if modules are unavailable.

### Instance Type Awareness

The script adapts based on EC2 instance characteristics:
- Virtual instances: Standard Cockpit deployment
- Bare metal instances: Additional sensor monitoring and hardware management tools

### Logging and Diagnostics

- All output redirected to `/var/log/user-data.log` with timestamps
- Installation completion summary with access URLs and module inventory
- MOTD integration for login notifications
- Built-in error handling prevents partial installations