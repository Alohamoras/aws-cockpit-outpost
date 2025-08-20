# Cockpit Outpost Instance Manager

This toolkit provides automated EC2 instance deployment and management for Red Hat Cockpit on AWS Outpost.

## Quick Start

### 1. Launch a New Instance
```bash
./launch-cockpit-instance.sh
```
This will:
- Find the latest Amazon Linux 2023 AMI
- Launch a c6id.metal instance on your Outpost
- Install and configure Cockpit with all modules
- Monitor the installation progress
- Automatically open Cockpit in your browser when ready

### 2. Manage Running Instances
```bash
# Check instance status
./manage-instances.sh status

# Connect via SSH
./manage-instances.sh ssh

# Monitor installation logs
./manage-instances.sh logs

# Open Cockpit web interface
./manage-instances.sh cockpit

# Check service health
./manage-instances.sh services

# Terminate instance
./manage-instances.sh terminate
```

## Configuration

The scripts are pre-configured for your environment:
- **Outpost ID:** op-0c81637caaa70bcb8
- **Subnet ID:** subnet-0ccfe76ef0f0071f6
- **Security Group:** sg-03e548d8a756262fb
- **Key Pair:** Ryanfill
- **Instance Type:** c6id.metal
- **Region:** us-east-1

## What Gets Installed

The `user-data.sh` script installs:
- Red Hat Cockpit web console
- Core modules: machines, podman, networkmanager, storaged, system
- Virtualization: libvirt, QEMU-KVM, virt-manager
- Container platform: Podman with socket activation
- Performance monitoring: PCP (Performance Co-Pilot)
- Third-party modules: 45Drives file-sharing, navigator, sensors
- Hardware monitoring (on bare metal instances)

## Monitoring

Installation progress is automatically monitored with:
- Real-time SSH connectivity checks
- User-data log parsing for completion status
- Error detection and alerts
- Service health verification
- Automatic browser launch when ready

## Access

Once deployment completes:
- **Cockpit Web UI:** https://[PUBLIC_IP]:9090
- **SSH Access:** `ssh -i ryanfill.pem rocky@[PUBLIC_IP]`
- **Installation Logs:** `/var/log/user-data.log` on the instance

### Login Credentials
- **Username:** `admin` or `rocky` 
- **Password:** `Cockpit123`
- Both users have sudo privileges

## Troubleshooting

If installation monitoring times out:
```bash
# Check logs manually
./manage-instances.sh logs

# Verify services
./manage-instances.sh services

# Connect and debug
./manage-instances.sh ssh
sudo systemctl status cockpit.socket
```

## Files Created
- `.last-instance-id` - Tracks the most recent instance for management commands