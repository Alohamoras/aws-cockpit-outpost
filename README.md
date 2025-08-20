# AWS Cockpit Outpost

Automated deployment and management of Red Hat Cockpit web console on AWS Outpost infrastructure. This toolkit provides one-click EC2 instance provisioning with comprehensive Cockpit installation, real-time monitoring, and management utilities.

## Features

- 🚀 **Automated Deployment** - Launch and configure Cockpit instances with a single command
- 📊 **Real-time Monitoring** - Track installation progress and detect issues automatically  
- 🔧 **Management Tools** - SSH access, log monitoring, service health checks
- 🌐 **Auto Browser Launch** - Opens Cockpit web interface when deployment completes
- 🏗️ **Outpost Optimized** - Configured specifically for AWS Outpost environments
- 🔒 **Secure by Default** - TLS-only access with proper firewall configuration

## What Gets Installed

The deployment includes a complete Cockpit environment with:

- **Core Cockpit Modules**: machines, podman, networkmanager, storaged, system, ws
- **Virtualization Stack**: libvirt, QEMU-KVM, virt-manager for VM management
- **Container Platform**: Podman with socket activation for container management
- **Performance Monitoring**: PCP (Performance Co-Pilot) for system metrics
- **Third-party Extensions**: 45Drives modules for file sharing, navigation, and sensors
- **Hardware Monitoring**: Automatic sensor detection on bare metal instances

## Quick Start

### Prerequisites
- AWS CLI configured with appropriate permissions
- SSH key pair for EC2 access
- Security group allowing inbound HTTPS on port 9090

### Launch Instance
```bash
./launch-cockpit-instance.sh
```

This will automatically:
1. Find the latest Amazon Linux 2023 AMI
2. Launch a c6id.metal instance on your Outpost
3. Execute the user-data installation script
4. Monitor progress with real-time status updates
5. Open Cockpit in your browser when ready

### Manage Instances
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

# Terminate instance (with confirmation)
./manage-instances.sh terminate
```

## Configuration

The scripts are pre-configured but can be easily customized by editing the variables at the top of `launch-cockpit-instance.sh`:

```bash
OUTPOST_ID="op-xxxxxxxxx"
SUBNET_ID="subnet-xxxxxxxxx" 
SECURITY_GROUP_ID="sg-xxxxxxxxx"
KEY_NAME="your-key-pair"
INSTANCE_TYPE="c6id.metal"
REGION="us-east-1"
```

## Access Your Instance

Once deployment completes, access Cockpit at:
- **Web Interface**: `https://[PUBLIC_IP]:9090`
- **SSH Access**: `ssh -i your-key.pem ec2-user@[PUBLIC_IP]`

Default login uses your EC2 key pair with `ec2-user` account.

## Monitoring & Troubleshooting

### Installation Progress
The launch script automatically monitors installation with:
- SSH connectivity verification
- User-data log parsing for completion status
- Error detection and progress reporting
- Service health verification

### Manual Monitoring
If you need to check progress manually:
```bash
# Watch installation logs
ssh -i your-key.pem ec2-user@[PUBLIC_IP] "sudo tail -f /var/log/user-data.log"

# Check service status
systemctl status cockpit.socket
systemctl status libvirtd
systemctl status podman.socket
```

### Common Issues
- **Installation timeout**: Check `/var/log/user-data.log` for errors
- **Cockpit not accessible**: Verify security group allows port 9090
- **SSH connection fails**: Ensure proper key permissions (`chmod 400`)

## Architecture

The deployment follows a phased installation approach:

1. **System Preparation** - Package updates and prerequisite installation
2. **Base Cockpit** - Core web console and essential modules
3. **Virtualization** - KVM/QEMU stack for virtual machine management
4. **Containers** - Podman configuration with socket activation
5. **Monitoring** - PCP daemon setup for performance metrics
6. **Extensions** - Third-party module installation with error handling
7. **Services** - Systemd service configuration and startup

## Files

- `launch-cockpit-instance.sh` - Main deployment script with monitoring
- `manage-instances.sh` - Instance management utility
- `user-data.sh` - EC2 user data script for Cockpit installation
- `USAGE.md` - Detailed usage instructions and examples
- `CLAUDE.md` - Project context and development guidelines

## Requirements

- **AWS CLI** v2.x with configured credentials
- **Bash** 4.0+ (standard on macOS/Linux)
- **SSH client** for instance access
- **AWS Outpost** with available capacity

## License

MIT License - see [LICENSE](LICENSE) for details.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Test your changes on a real Outpost environment
4. Submit a pull request with clear description

---

**Note**: This toolkit is designed specifically for AWS Outpost environments. For standard EC2 deployments, you may need to modify the configuration parameters.