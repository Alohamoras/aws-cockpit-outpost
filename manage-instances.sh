#!/bin/bash

# Instance Management Utility for Cockpit Outpost Servers
# Provides common management operations for launched instances

set -e

REGION="us-east-1"
INSTANCE_FILE=".last-instance-id"

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

# Get last launched instance info
get_last_instance() {
    if [[ -f "$INSTANCE_FILE" ]]; then
        INSTANCE_ID=$(grep "Instance ID:" "$INSTANCE_FILE" | cut -d' ' -f3)
        PUBLIC_IP=$(grep "Public IP:" "$INSTANCE_FILE" | cut -d' ' -f3)
        
        if [[ -z "$INSTANCE_ID" ]]; then
            error "No instance ID found in $INSTANCE_FILE"
            exit 1
        fi
        
        success "Found last instance: $INSTANCE_ID"
        [[ -n "$PUBLIC_IP" ]] && success "Public IP: $PUBLIC_IP"
    else
        error "No instance file found. Launch an instance first."
        exit 1
    fi
}

# Show instance status
show_status() {
    get_last_instance
    
    log "Fetching instance status..."
    
    local status_output=$(aws ec2 describe-instances \
        --region "$REGION" \
        --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].[State.Name,InstanceType,PublicIpAddress,LaunchTime]' \
        --output table)
    
    echo "═══════════════════════════════════════════════════"
    echo "Instance Status: $INSTANCE_ID"
    echo "═══════════════════════════════════════════════════"
    echo "$status_output"
    echo ""
    
    # Check if instance is running and get additional info
    local state=$(aws ec2 describe-instances \
        --region "$REGION" \
        --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text)
    
    if [[ "$state" == "running" ]]; then
        success "Instance is running"
        
        if [[ -n "$PUBLIC_IP" ]]; then
            echo "Cockpit URL: https://$PUBLIC_IP:9090"
            echo "SSH Command: ssh -i ryanfill.pem ec2-user@$PUBLIC_IP"
        fi
    else
        warning "Instance is not running (state: $state)"
    fi
}

# Connect to instance via SSH
ssh_connect() {
    get_last_instance
    
    if [[ -z "$PUBLIC_IP" ]]; then
        log "Getting current public IP..."
        PUBLIC_IP=$(aws ec2 describe-instances \
            --region "$REGION" \
            --instance-ids "$INSTANCE_ID" \
            --query 'Reservations[0].Instances[0].PublicIpAddress' \
            --output text)
        
        if [[ "$PUBLIC_IP" == "None" ]] || [[ -z "$PUBLIC_IP" ]]; then
            error "No public IP available"
            exit 1
        fi
    fi
    
    log "Connecting to $PUBLIC_IP..."
    ssh -i ryanfill.pem rocky@"$PUBLIC_IP"
}

# Monitor installation logs
monitor_logs() {
    get_last_instance
    
    if [[ -z "$PUBLIC_IP" ]]; then
        log "Getting current public IP..."
        PUBLIC_IP=$(aws ec2 describe-instances \
            --region "$REGION" \
            --instance-ids "$INSTANCE_ID" \
            --query 'Reservations[0].Instances[0].PublicIpAddress' \
            --output text)
        
        if [[ "$PUBLIC_IP" == "None" ]] || [[ -z "$PUBLIC_IP" ]]; then
            error "No public IP available"
            exit 1
        fi
    fi
    
    log "Monitoring installation logs on $PUBLIC_IP..."
    log "Press Ctrl+C to stop monitoring"
    echo ""
    
    ssh -i ryanfill.pem rocky@"$PUBLIC_IP" "sudo tail -f /var/log/user-data.log"
}

# Open Cockpit in browser
open_cockpit() {
    get_last_instance
    
    if [[ -z "$PUBLIC_IP" ]]; then
        log "Getting current public IP..."
        PUBLIC_IP=$(aws ec2 describe-instances \
            --region "$REGION" \
            --instance-ids "$INSTANCE_ID" \
            --query 'Reservations[0].Instances[0].PublicIpAddress' \
            --output text)
        
        if [[ "$PUBLIC_IP" == "None" ]] || [[ -z "$PUBLIC_IP" ]]; then
            error "No public IP available"
            exit 1
        fi
    fi
    
    local cockpit_url="https://$PUBLIC_IP:9090"
    success "Opening Cockpit: $cockpit_url"
    
    if command -v open &> /dev/null; then
        open "$cockpit_url"
    elif command -v xdg-open &> /dev/null; then
        xdg-open "$cockpit_url"
    else
        echo "Please manually open: $cockpit_url"
    fi
}

# Terminate instance
terminate_instance() {
    get_last_instance
    
    echo "═══════════════════════════════════════════════════"
    echo "⚠️  INSTANCE TERMINATION"
    echo "═══════════════════════════════════════════════════"
    echo "Instance ID: $INSTANCE_ID"
    [[ -n "$PUBLIC_IP" ]] && echo "Public IP:   $PUBLIC_IP"
    echo ""
    echo "This action cannot be undone!"
    echo ""
    
    read -p "Are you sure you want to terminate this instance? (type 'yes' to confirm): " confirm
    
    if [[ "$confirm" == "yes" ]]; then
        log "Terminating instance $INSTANCE_ID..."
        
        aws ec2 terminate-instances \
            --region "$REGION" \
            --instance-ids "$INSTANCE_ID" \
            --output table
        
        success "Termination initiated"
        
        # Remove instance file
        rm -f "$INSTANCE_FILE"
        log "Cleaned up instance file"
    else
        log "Termination cancelled"
    fi
}

# Check Cockpit service status
check_cockpit_status() {
    get_last_instance
    
    if [[ -z "$PUBLIC_IP" ]]; then
        log "Getting current public IP..."
        PUBLIC_IP=$(aws ec2 describe-instances \
            --region "$REGION" \
            --instance-ids "$INSTANCE_ID" \
            --query 'Reservations[0].Instances[0].PublicIpAddress' \
            --output text)
        
        if [[ "$PUBLIC_IP" == "None" ]] || [[ -z "$PUBLIC_IP" ]]; then
            error "No public IP available"
            exit 1
        fi
    fi
    
    log "Checking Cockpit service status on $PUBLIC_IP..."
    
    # Check various services
    services=("cockpit.socket" "libvirtd" "podman.socket" "pmcd" "pmlogger")
    
    echo "═══════════════════════════════════════════════════"
    echo "Service Status Report"
    echo "═══════════════════════════════════════════════════"
    
    for service in "${services[@]}"; do
        status=$(ssh -i ryanfill.pem -o StrictHostKeyChecking=no ec2-user@"$PUBLIC_IP" "systemctl is-active $service 2>/dev/null || echo 'inactive'")
        if [[ "$status" == "active" ]]; then
            echo -e "✅ $service: ${GREEN}$status${NC}"
        else
            echo -e "❌ $service: ${RED}$status${NC}"
        fi
    done
    
    echo ""
    
    # Check if Cockpit web interface is responding
    log "Testing Cockpit web interface connectivity..."
    if ssh -i ryanfill.pem -o StrictHostKeyChecking=no ec2-user@"$PUBLIC_IP" "curl -k -s --max-time 5 https://localhost:9090 >/dev/null 2>&1"; then
        success "Cockpit web interface is responding"
        echo "🌐 Cockpit URL: https://$PUBLIC_IP:9090"
    else
        warning "Cockpit web interface is not responding"
    fi
}

# Show usage
show_usage() {
    echo "Instance Management Utility for Cockpit Outpost Servers"
    echo ""
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  status    - Show instance status and information"
    echo "  ssh       - Connect to instance via SSH"
    echo "  logs      - Monitor installation logs in real-time"
    echo "  cockpit   - Open Cockpit web interface in browser"
    echo "  services  - Check Cockpit and related service status"
    echo "  terminate - Terminate the instance (requires confirmation)"
    echo "  help      - Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 status     # Check if instance is running"
    echo "  $0 logs       # Watch installation progress"
    echo "  $0 cockpit    # Open web interface"
    echo "  $0 services   # Check service health"
}

# Main execution
case "${1:-help}" in
    "status")
        show_status
        ;;
    "ssh")
        ssh_connect
        ;;
    "logs")
        monitor_logs
        ;;
    "cockpit")
        open_cockpit
        ;;
    "services")
        check_cockpit_status
        ;;
    "terminate")
        terminate_instance
        ;;
    "help"|*)
        show_usage
        ;;
esac