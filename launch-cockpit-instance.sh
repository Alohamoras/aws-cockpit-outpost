#!/bin/bash

# AWS Outpost Cockpit Instance Launch and Monitor Script
# Launches EC2 instance with user-data.sh and monitors installation

set -e

# Load environment variables from .env file if it exists
if [[ -f .env ]]; then
    source .env
fi

# Configuration (defaults - can be overridden by .env file)
OUTPOST_ID="${OUTPOST_ID:-op-0c81637caaa70bcb8}"
SUBNET_ID="${SUBNET_ID:-subnet-0ccfe76ef0f0071f6}"
SECURITY_GROUP_ID="${SECURITY_GROUP_ID:-sg-03e548d8a756262fb}"
KEY_NAME="${KEY_NAME:-ryanfill}"
INSTANCE_TYPE="${INSTANCE_TYPE:-c6id.metal}"
REGION="${REGION:-us-east-1}"
USER_DATA_FILE="./user-data.sh"

# SNS Topic ARN for notifications (required)
SNS_TOPIC_ARN="${SNS_TOPIC_ARN}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

success() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS:${NC} $1"
}

warning() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1"
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."
    
    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        error "AWS CLI not found. Please install it first."
        exit 1
    fi
    
    # Check SNS Topic ARN is provided
    if [[ -z "$SNS_TOPIC_ARN" ]]; then
        error "SNS_TOPIC_ARN environment variable is required for notifications."
        error "Set it with: export SNS_TOPIC_ARN=\"arn:aws:sns:region:account:topic-name\""
        exit 1
    fi
    
    # Validate SNS ARN format
    if [[ ! "$SNS_TOPIC_ARN" =~ ^arn:aws:sns:[^:]+:[^:]+:[^:]+$ ]]; then
        error "Invalid SNS Topic ARN format: $SNS_TOPIC_ARN"
        error "Expected format: arn:aws:sns:region:account-id:topic-name"
        exit 1
    fi
    
    # Check user-data.sh exists
    if [[ ! -f "$USER_DATA_FILE" ]]; then
        error "User data file not found: $USER_DATA_FILE"
        exit 1
    fi
    
    # Check key file exists
    if [[ ! -f "ryanfill.pem" ]]; then
        error "Key file not found: ryanfill.pem"
        exit 1
    fi
    
    # Set proper permissions on key file
    chmod 400 ryanfill.pem
    
    success "Prerequisites check passed"
    success "SNS notifications will be sent to: $SNS_TOPIC_ARN"
}

# Get latest Rocky Linux 9 AMI
get_latest_ami() {
    log "Finding latest Rocky Linux 9 AMI..."
    
    AMI_ID=$(aws ec2 describe-images \
        --region "$REGION" \
        --owners 679593333241 \
        --filters "Name=name,Values=Rocky-9-EC2-LVM-*" \
                  "Name=architecture,Values=x86_64" \
                  "Name=virtualization-type,Values=hvm" \
        --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
        --output text)
    
    if [[ "$AMI_ID" == "None" ]] || [[ -z "$AMI_ID" ]]; then
        error "Failed to find Rocky Linux 9 AMI"
        exit 1
    fi
    
    success "Found AMI: $AMI_ID"
}

# Ensure SSM instance profile exists
ensure_ssm_instance_profile() {
    log "Checking for SSM instance profile..."
    
    local profile_created=false
    
    # Check if instance profile exists
    if aws iam get-instance-profile --instance-profile-name "CockpitSSMInstanceProfile" >/dev/null 2>&1; then
        success "SSM instance profile already exists"
    else
        profile_created=true
        log "Creating SSM instance profile..."
        
        # Create the instance profile
    aws iam create-instance-profile \
        --instance-profile-name "CockpitSSMInstanceProfile" \
        --path "/" >/dev/null
    
    # Add the SSM managed role to the instance profile
    aws iam add-role-to-instance-profile \
        --instance-profile-name "CockpitSSMInstanceProfile" \
        --role-name "AmazonSSMManagedInstanceCore" 2>/dev/null || {
        
        # If role doesn't exist, create it
        log "Creating SSM role..."
        aws iam create-role \
            --role-name "AmazonSSMManagedInstanceCore" \
            --assume-role-policy-document '{
                "Version": "2012-10-17",
                "Statement": [
                    {
                        "Effect": "Allow",
                        "Principal": {
                            "Service": "ec2.amazonaws.com"
                        },
                        "Action": "sts:AssumeRole"
                    }
                ]
            }' >/dev/null
        
        # Attach the SSM managed policy
        aws iam attach-role-policy \
            --role-name "AmazonSSMManagedInstanceCore" \
            --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" >/dev/null
        
        # Create and attach SNS policy for notifications
        aws iam put-role-policy \
            --role-name "AmazonSSMManagedInstanceCore" \
            --policy-name "CockpitSNSNotifications" \
            --policy-document "{
                \"Version\": \"2012-10-17\",
                \"Statement\": [
                    {
                        \"Effect\": \"Allow\",
                        \"Action\": \"sns:Publish\",
                        \"Resource\": \"$SNS_TOPIC_ARN\"
                    }
                ]
            }" >/dev/null
        
        # Add role to instance profile
        aws iam add-role-to-instance-profile \
            --instance-profile-name "CockpitSSMInstanceProfile" \
            --role-name "AmazonSSMManagedInstanceCore" >/dev/null
    }
    fi
    
    # Wait for IAM propagation if we created new resources
    if [[ $profile_created == true ]]; then
        log "Waiting 30 seconds for IAM propagation..."
        sleep 30
    fi
    
    success "SSM instance profile configured"
}

# Launch EC2 instance
launch_instance() {
    log "Launching EC2 instance..."
    
    # Create temporary user-data file with SNS ARN substituted
    local temp_userdata=$(mktemp)
    sed "s/PLACEHOLDER_SNS_TOPIC_ARN/$SNS_TOPIC_ARN/g" "$USER_DATA_FILE" > "$temp_userdata"
    
    INSTANCE_ID=$(aws ec2 run-instances \
        --region "$REGION" \
        --image-id "$AMI_ID" \
        --instance-type "$INSTANCE_TYPE" \
        --key-name "$KEY_NAME" \
        --security-group-ids "$SECURITY_GROUP_ID" \
        --subnet-id "$SUBNET_ID" \
        --iam-instance-profile "Name=CockpitSSMInstanceProfile" \
        --user-data file://"$temp_userdata" \
        --placement "AvailabilityZone=$(aws ec2 describe-subnets --region $REGION --subnet-ids $SUBNET_ID --query 'Subnets[0].AvailabilityZone' --output text)" \
        --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=Cockpit-Outpost-Server},{Key=Purpose,Value=Cockpit-WebConsole}]' \
        --query 'Instances[0].InstanceId' \
        --output text)
    
    # Clean up temporary file
    rm -f "$temp_userdata"
    
    if [[ -z "$INSTANCE_ID" ]]; then
        error "Failed to launch instance"
        exit 1
    fi
    
    success "Instance launched: $INSTANCE_ID"
    echo "Instance ID: $INSTANCE_ID" > .last-instance-id
}

# Wait for instance to be running
wait_for_running() {
    log "Waiting for instance to be in running state..."
    
    aws ec2 wait instance-running \
        --region "$REGION" \
        --instance-ids "$INSTANCE_ID"
    
    success "Instance is now running"
}

# Get instance public IP and assign if needed
get_public_ip() {
    log "Getting instance public IP..."
    
    PUBLIC_IP=$(aws ec2 describe-instances \
        --region "$REGION" \
        --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text)
    
    if [[ "$PUBLIC_IP" == "None" ]] || [[ -z "$PUBLIC_IP" ]]; then
        warning "Instance has no public IP, attempting to assign Elastic IP..."
        
        # Try to find available EIP
        local eip_alloc=$(aws ec2 describe-addresses \
            --region "$REGION" \
            --query 'Addresses[?AssociationId==null].AllocationId' \
            --output text | head -1)
        
        if [[ -n "$eip_alloc" && "$eip_alloc" != "None" ]]; then
            log "Found available Elastic IP: $eip_alloc"
            aws ec2 associate-address \
                --region "$REGION" \
                --instance-id "$INSTANCE_ID" \
                --allocation-id "$eip_alloc" >/dev/null
            
            # Get the newly assigned public IP
            PUBLIC_IP=$(aws ec2 describe-instances \
                --region "$REGION" \
                --instance-ids "$INSTANCE_ID" \
                --query 'Reservations[0].Instances[0].PublicIpAddress' \
                --output text)
                
            success "Assigned Elastic IP: $PUBLIC_IP"
        else
            error "No available Elastic IPs found. Please ensure subnet auto-assigns public IPs or release an EIP."
            error "Alternatively, manually associate an Elastic IP after launch."
            exit 1
        fi
    else
        success "Instance already has public IP: $PUBLIC_IP"
    fi
    
    echo "Public IP: $PUBLIC_IP" >> .last-instance-id
}

# Monitor installation progress
monitor_installation() {
    log "Monitoring Cockpit installation progress..."
    log "SSH command: ssh -i ryanfill.pem ec2-user@$PUBLIC_IP"
    
    # Wait for SSH to be available
    log "Waiting for SSH to become available..."
    local ssh_ready=false
    local attempts=0
    local max_attempts=30
    
    while [[ $ssh_ready == false ]] && [[ $attempts -lt $max_attempts ]]; do
        if ssh -i ryanfill.pem -o ConnectTimeout=5 -o StrictHostKeyChecking=no rocky@$PUBLIC_IP "echo 'SSH Ready'" >/dev/null 2>&1; then
            ssh_ready=true
            success "SSH is now available"
        else
            ((attempts++))
            log "SSH attempt $attempts/$max_attempts failed, retrying in 10 seconds..."
            sleep 10
        fi
    done
    
    if [[ $ssh_ready == false ]]; then
        error "SSH never became available after $max_attempts attempts"
        exit 1
    fi
    
    # Monitor user-data execution
    log "Monitoring user-data execution..."
    local installation_complete=false
    local check_count=0
    local max_checks=60  # 30 minutes max
    
    while [[ $installation_complete == false ]] && [[ $check_count -lt $max_checks ]]; do
        ((check_count++))
        
        # Check if user-data log exists and get status
        if ssh -i ryanfill.pem -o StrictHostKeyChecking=no rocky@$PUBLIC_IP "test -f /var/log/user-data.log" 2>/dev/null; then
            
            # Get last few lines of user-data log
            local log_output=$(ssh -i ryanfill.pem -o StrictHostKeyChecking=no rocky@$PUBLIC_IP "sudo tail -10 /var/log/user-data.log" 2>/dev/null || echo "Log read failed")
            
            # Check for completion indicators
            if echo "$log_output" | grep -q "Cockpit installation completed successfully"; then
                installation_complete=true
                success "Installation completed successfully!"
            elif echo "$log_output" | grep -q "ERROR\|FAILED\|error\|failed"; then
                warning "Potential errors detected in installation"
                echo "$log_output"
            else
                # Show progress
                local current_step=$(echo "$log_output" | grep -E "(Installing|Configuring|Setting up)" | tail -1 | sed 's/.*\] //')
                if [[ -n "$current_step" ]]; then
                    log "Progress: $current_step"
                else
                    log "Installation in progress... (check $check_count/$max_checks)"
                fi
            fi
        else
            log "User-data execution starting... (check $check_count/$max_checks)"
        fi
        
        if [[ $installation_complete == false ]]; then
            sleep 30  # Check every 30 seconds
        fi
    done
    
    if [[ $installation_complete == false ]]; then
        warning "Installation monitoring timed out after 30 minutes"
        log "You can manually check progress with: ssh -i ryanfill.pem rocky@$PUBLIC_IP 'sudo tail -f /var/log/user-data.log'"
        return 1
    fi
    
    return 0
}

# Verify Cockpit installation
verify_installation() {
    log "Verifying Cockpit installation..."
    
    local max_attempts=12  # 6 minutes
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        log "Verification attempt $attempt/$max_attempts..."
        
        # Check if Cockpit web interface is accessible
        if curl -k -s --connect-timeout 10 https://$PUBLIC_IP:9090/ >/dev/null 2>&1; then
            success "Cockpit web interface is accessible"
            
            # Check if SSH is working
            if ssh -i ryanfill.pem -o ConnectTimeout=10 -o StrictHostKeyChecking=no rocky@$PUBLIC_IP "echo 'SSH test successful'" >/dev/null 2>&1; then
                success "SSH access is working"
                return 0
            else
                warning "Cockpit accessible but SSH may have issues"
                return 0  # Cockpit is the main goal, SSH issues are secondary
            fi
        fi
        
        log "Cockpit not ready, waiting 30 seconds..."
        sleep 30
        ((attempt++))
    done
    
    warning "Cockpit verification failed after $max_attempts attempts"
    return 1
}

# Monitor installation with fallback verification
monitor_with_fallback() {
    log "Starting installation monitoring with fallback verification..."
    
    if monitor_installation; then
        success "Installation monitoring completed successfully"
        return 0
    else
        warning "Primary monitoring failed, attempting manual verification..."
        
        if verify_installation; then
            success "Installation verified manually - Cockpit is working"
            return 0
        else
            error "Installation appears to have failed completely"
            return 1
        fi
    fi
}

# Wait for Cockpit to be ready
wait_for_cockpit() {
    log "Waiting for Cockpit web interface to be ready..."
    
    local cockpit_ready=false
    local attempts=0
    local max_attempts=20
    
    while [[ $cockpit_ready == false ]] && [[ $attempts -lt $max_attempts ]]; do
        if ssh -i ryanfill.pem -o StrictHostKeyChecking=no rocky@$PUBLIC_IP "systemctl is-active cockpit.socket" >/dev/null 2>&1; then
            cockpit_ready=true
            success "Cockpit is now active and ready"
        else
            ((attempts++))
            log "Cockpit readiness check $attempts/$max_attempts, retrying in 15 seconds..."
            sleep 15
        fi
    done
    
    if [[ $cockpit_ready == false ]]; then
        warning "Cockpit service check timed out, but it may still be starting"
    fi
}

# Open Cockpit in browser
open_cockpit() {
    local cockpit_url="https://$PUBLIC_IP:9090"
    
    success "Cockpit installation complete!"
    echo ""
    echo "═══════════════════════════════════════════════════"
    echo "🚀 COCKPIT SERVER READY"
    echo "═══════════════════════════════════════════════════"
    echo "Instance ID: $INSTANCE_ID"
    echo "Public IP:   $PUBLIC_IP"
    echo "Cockpit URL: $cockpit_url"
    echo "SSH Access:  ssh -i ryanfill.pem rocky@$PUBLIC_IP"
    echo ""
    echo "Opening Cockpit in your browser..."
    echo "═══════════════════════════════════════════════════"
    
    # Open in browser (works on macOS)
    if command -v open &> /dev/null; then
        open "$cockpit_url"
    elif command -v xdg-open &> /dev/null; then
        xdg-open "$cockpit_url"
    else
        log "Please manually open: $cockpit_url"
    fi
}

# Cleanup function for interrupts
cleanup() {
    echo ""
    warning "Script interrupted"
    if [[ -n "$INSTANCE_ID" ]]; then
        echo "Instance ID: $INSTANCE_ID"
        echo "To terminate: aws ec2 terminate-instances --region $REGION --instance-ids $INSTANCE_ID"
    fi
    exit 1
}

# Set trap for cleanup
trap cleanup INT TERM

# Main execution
main() {
    echo "═══════════════════════════════════════════════════"
    echo "🏗️  AWS OUTPOST COCKPIT LAUNCHER"
    echo "═══════════════════════════════════════════════════"
    echo "Outpost ID: $OUTPOST_ID"
    echo "Subnet ID:  $SUBNET_ID"
    echo "Instance:   $INSTANCE_TYPE"
    echo "═══════════════════════════════════════════════════"
    echo ""
    
    check_prerequisites
    get_latest_ami
    ensure_ssm_instance_profile
    launch_instance
    wait_for_running
    get_public_ip
    
    # Provide immediate access information
    success "Instance launched successfully!"
    echo ""
    echo "═══════════════════════════════════════════════════"
    echo "🚀 INSTANCE LAUNCHED"
    echo "═══════════════════════════════════════════════════"
    echo "Instance ID: $INSTANCE_ID"
    echo "Public IP:   $PUBLIC_IP"
    echo "SSH Access:  ssh -i ryanfill.pem rocky@$PUBLIC_IP"
    echo ""
    echo "📧 You will receive an email notification when"
    echo "   Cockpit installation completes (5-10 minutes)"
    echo ""
    echo "📋 Manual monitoring:"
    echo "   ssh -i ryanfill.pem rocky@$PUBLIC_IP 'sudo tail -f /var/log/user-data.log'"
    echo "═══════════════════════════════════════════════════"
    
    # Ask user if they want to monitor installation progress
    echo ""
    read -p "Do you want to monitor installation progress? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if monitor_with_fallback; then
            wait_for_cockpit
            open_cockpit
        else
            warning "Installation monitoring and verification failed"
            echo "Check your email for completion notification"
            echo "Cockpit URL: https://$PUBLIC_IP:9090"
            echo "Manual verification: curl -k https://$PUBLIC_IP:9090/"
        fi
    else
        echo "Instance is running. Check your email for completion notification."
        echo "Cockpit URL: https://$PUBLIC_IP:9090"
    fi
}

# Run main function
main "$@"