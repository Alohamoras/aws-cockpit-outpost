#!/bin/bash
# AWS Outpost Storage Configuration Script
# Post-installation script to configure storage drives for Cockpit workloads
# Run this AFTER Cockpit installation is complete

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Color output for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging setup
LOG_FILE="/var/log/storage-config.log"
exec > >(tee -a "$LOG_FILE")
exec 2>&1

echo -e "${BLUE}=== AWS OUTPOST STORAGE CONFIGURATION ===${NC}"
echo "Started at: $(date)"
echo "Log file: $LOG_FILE"

# Function to print colored messages
log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Function to check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root or with sudo"
        exit 1
    fi
}

# Function to check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check if required tools are available
    local required_tools=("lsblk" "parted" "pvcreate" "vgcreate" "lvcreate" "mkfs.xfs")
    local missing_tools=()
    
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_warning "Installing missing tools: ${missing_tools[*]}"
        if ! dnf install -y lvm2 parted xfsprogs; then
            log_error "Failed to install required tools"
            exit 1
        fi
    fi
    
    # Install mdadm and bc if not present
    if ! command -v mdadm &> /dev/null || ! command -v bc &> /dev/null; then
        log_info "Installing mdadm and bc..."
        dnf install -y mdadm bc || {
            log_error "Failed to install mdadm and bc"
            exit 1
        }
    fi
    
    log_success "Prerequisites check completed"
}

# Function to safely detect the boot drive
detect_boot_drive() {
    log_info "Detecting boot drive..."
    
    # Find the device containing the root filesystem
    local root_device
    root_device=$(findmnt -n -o SOURCE / | head -1)
    
    if [[ -z "$root_device" ]]; then
        log_error "Could not determine root filesystem device"
        return 1
    fi
    
    log_info "Root filesystem is on: $root_device"
    
    # Handle different root filesystem types
    if [[ "$root_device" =~ /dev/mapper/ ]]; then
        # LVM root filesystem - find the underlying physical device
        log_info "LVM root detected, finding underlying physical device..."
        
        # Extract VG name from mapper path
        local vg_name
        if [[ "$root_device" =~ /dev/mapper/([^-]+)- ]]; then
            vg_name="${BASH_REMATCH[1]}"
        else
            log_error "Could not extract VG name from: $root_device"
            return 1
        fi
        
        # Find physical volumes for this VG
        local pv_devices
        mapfile -t pv_devices < <(pvdisplay -c | grep ":${vg_name}:" | cut -d: -f1 | tr -d ' ')
        
        if [[ ${#pv_devices[@]} -eq 0 ]]; then
            log_error "No physical volumes found for VG: $vg_name"
            return 1
        fi
        
        # Use the first PV to determine boot drive
        local first_pv="${pv_devices[0]}"
        first_pv=$(echo "$first_pv" | tr -d ' ')  # Remove any remaining spaces
        log_info "Found PV: $first_pv"
        
        # Extract the base device name from PV
        if [[ "$first_pv" =~ /dev/nvme[0-9]+n[0-9]+p[0-9]+ ]]; then
            # NVMe device: /dev/nvme0n1p1 -> /dev/nvme0n1
            BOOT_DRIVE="${first_pv%p*}"
        elif [[ "$first_pv" =~ /dev/(sd[a-z]|xvd[a-z])[0-9]+ ]]; then
            # SATA/SCSI device: /dev/sda1 -> /dev/sda
            BOOT_DRIVE="${first_pv%[0-9]*}"
        else
            log_error "Unknown PV device type: $first_pv"
            return 1
        fi
        
    elif [[ "$root_device" =~ /dev/nvme[0-9]+n[0-9]+p[0-9]+ ]]; then
        # Direct NVMe partition: /dev/nvme0n1p1 -> /dev/nvme0n1
        BOOT_DRIVE="${root_device%p*}"
        
    elif [[ "$root_device" =~ /dev/(sd[a-z]|xvd[a-z])[0-9]+ ]]; then
        # Direct SATA/SCSI partition: /dev/sda1 -> /dev/sda
        BOOT_DRIVE="${root_device%[0-9]*}"
        
    else
        log_error "Unknown root device type: $root_device"
        log_info "Supported types: LVM (/dev/mapper/), NVMe (/dev/nvmeXnY), SATA/SCSI (/dev/sdX)"
        return 1
    fi
    
    # Verify the boot drive exists
    if [[ ! -b "$BOOT_DRIVE" ]]; then
        log_error "Boot drive $BOOT_DRIVE is not a valid block device"
        return 1
    fi
    
    log_success "Boot drive detected: $BOOT_DRIVE"
    return 0
}

# Function to detect available data drives
detect_data_drives() {
    log_info "Detecting available data drives..."
    
    # Get all block devices (NVMe, SATA, SCSI)
    local all_drives
    mapfile -t all_drives < <(lsblk -dnp -o NAME,TYPE | grep 'disk$' | awk '{print $1}' | sort)
    
    DATA_DRIVES=()
    
    log_info "Examining ${#all_drives[@]} block devices..."
    
    for drive in "${all_drives[@]}"; do
        log_info "Checking drive: $drive"
        
        # Skip the boot drive
        if [[ "$drive" == "$BOOT_DRIVE" ]]; then
            log_info "  Skipping boot drive: $drive"
            continue
        fi
        
        # Check if drive exists and is accessible
        if [[ ! -b "$drive" ]]; then
            log_warning "  Drive $drive is not accessible, skipping"
            continue
        fi
        
        # Check if drive has any mounted partitions or is in use
        local drive_in_use=false
        
        # Check for mounted partitions
        if lsblk "$drive" -o MOUNTPOINT | grep -v '^$' | grep -q '/'; then
            log_info "  Drive $drive has mounted partitions, skipping"
            drive_in_use=true
        fi
        
        # Check if drive or its partitions are part of existing LVM
        if ! $drive_in_use && pvdisplay "$drive"* &>/dev/null; then
            log_info "  Drive $drive is part of existing LVM, skipping"
            drive_in_use=true
        fi
        
        # Check if drive is part of existing RAID
        if ! $drive_in_use && grep -q "$(basename "$drive")" /proc/mdstat 2>/dev/null; then
            log_info "  Drive $drive is part of existing RAID, skipping"
            drive_in_use=true
        fi
        
        # Check for filesystem signatures on the raw device
        if ! $drive_in_use; then
            local fs_type
            fs_type=$(blkid -o value -s TYPE "$drive" 2>/dev/null || echo "")
            if [[ -n "$fs_type" ]]; then
                log_info "  Drive $drive has filesystem signature ($fs_type), skipping"
                drive_in_use=true
            fi
        fi
        
        # If drive passed all checks, it's available for use
        if ! $drive_in_use; then
            log_success "  Drive $drive is available for configuration"
            DATA_DRIVES+=("$drive")
        fi
    done
    
    log_info "Found ${#DATA_DRIVES[@]} available data drives: ${DATA_DRIVES[*]}"
    
    # Show what we're skipping for transparency
    if [[ ${#DATA_DRIVES[@]} -eq 0 ]]; then
        log_warning "No available data drives found. This could be because:"
        log_warning "  - All drives are already in use"
        log_warning "  - All drives have existing data"
        log_warning "  - Only the boot drive is present"
        log_info "Use 'lsblk' and 'pvdisplay' to see current disk usage"
    fi
}

# Function to expand boot drive if free space is available
expand_boot_drive() {
    log_info "Checking for expandable space on boot drive..."
    
    if [[ -z "$BOOT_DRIVE" ]]; then
        log_warning "Boot drive not detected, skipping expansion"
        return 0
    fi
    
    # Check if boot drive is accessible
    if [[ ! -b "$BOOT_DRIVE" ]]; then
        log_warning "Boot drive $BOOT_DRIVE not accessible, skipping expansion"
        return 0
    fi
    
    # Check for unallocated space with timeout
    local free_space_info
    log_info "Running parted to check free space (with 30s timeout)..."
    if ! free_space_info=$(timeout 30s parted "$BOOT_DRIVE" print free 2>/dev/null | grep "Free Space" | tail -1); then
        log_warning "Parted command timed out or failed, skipping boot drive expansion"
        log_info "You can manually expand the boot drive later if needed"
        return 0
    fi
    
    if [[ -z "$free_space_info" ]]; then
        log_info "No free space found on boot drive"
        return 0
    fi
    
    # Extract free space size (convert to GB)
    local free_space_raw
    free_space_raw=$(echo "$free_space_info" | awk '{print $3}')
    local free_space_gb
    
    # Convert to GB (handle different units)
    if [[ "$free_space_raw" =~ ([0-9.]+)GB ]]; then
        free_space_gb=${BASH_REMATCH[1]%.*}  # Remove decimal part
    elif [[ "$free_space_raw" =~ ([0-9.]+)TB ]]; then
        free_space_gb=$((${BASH_REMATCH[1]%.*} * 1000))
    else
        log_info "Free space too small or unknown unit: $free_space_raw"
        return 0
    fi
    
    # Only proceed if we have significant free space (>10GB)
    if [[ -n "$free_space_gb" ]] && (( free_space_gb > 10 )); then
        log_info "Found ${free_space_gb}GB free space, attempting to expand rocky VG..."
        
        # Get the last partition number and calculate next
        local last_part_num
        last_part_num=$(parted "$BOOT_DRIVE" print | grep -E "^ *[0-9]" | tail -1 | awk '{print $1}')
        local next_part_num=$((last_part_num + 1))
        
        # Get end position of last partition
        local last_part_end
        last_part_end=$(parted "$BOOT_DRIVE" print | grep -E "^ *${last_part_num}" | awk '{print $3}')
        
        if [[ -n "$last_part_end" ]]; then
            # Create new partition
            log_info "Creating partition ${next_part_num} from ${last_part_end} to 100%"
            if parted "$BOOT_DRIVE" mkpart primary "${last_part_end}" 100%; then
                if parted "$BOOT_DRIVE" set "$next_part_num" lvm on; then
                    # Wait for device to be ready
                    sleep 5
                    partprobe "$BOOT_DRIVE"
                    sleep 3
                    
                    # Determine new partition name
                    local new_partition
                    if [[ "$BOOT_DRIVE" =~ nvme ]]; then
                        new_partition="${BOOT_DRIVE}p${next_part_num}"
                    else
                        new_partition="${BOOT_DRIVE}${next_part_num}"
                    fi
                    
                    # Wait for partition to appear
                    local wait_count=0
                    while [[ ! -e "$new_partition" ]] && [[ $wait_count -lt 10 ]]; do
                        sleep 2
                        ((wait_count++))
                    done
                    
                    if [[ -e "$new_partition" ]]; then
                        # Create PV and extend VG
                        if pvcreate "$new_partition"; then
                            if vgextend rocky "$new_partition"; then
                                log_success "Successfully expanded rocky VG with ${free_space_gb}GB"
                            else
                                log_error "Failed to extend rocky VG"
                            fi
                        else
                            log_error "Failed to create physical volume"
                        fi
                    else
                        log_error "New partition $new_partition did not appear"
                    fi
                else
                    log_error "Failed to set LVM flag on partition"
                fi
            else
                log_error "Failed to create new partition"
            fi
        else
            log_error "Could not determine last partition end position"
        fi
    else
        log_info "Free space (${free_space_gb}GB) too small to expand"
    fi
}

# Function to configure data drives with RAID
configure_data_drives() {
    local drive_count=${#DATA_DRIVES[@]}
    
    if [[ $drive_count -eq 0 ]]; then
        log_info "No data drives available for configuration"
        return 0
    fi
    
    log_info "Configuring $drive_count data drives..."
    
    # Validate all drives are clean
    for drive in "${DATA_DRIVES[@]}"; do
        if [[ ! -b "$drive" ]]; then
            log_error "Drive $drive is not a valid block device"
            return 1
        fi
        
        # Check if drive is mounted
        if lsblk "$drive" -o MOUNTPOINT | grep -q '/'; then
            log_error "Drive $drive has mounted partitions"
            return 1
        fi
    done
    
    # Configure based on number of drives
    if [[ $drive_count -ge 3 ]]; then
        log_info "Creating RAID5 array with $drive_count drives..."
        configure_raid5
    elif [[ $drive_count -eq 2 ]]; then
        log_info "Creating RAID1 array with 2 drives..."
        configure_raid1
    else
        log_info "Configuring single data drive..."
        configure_single_drive
    fi
}

# Function to configure RAID5
configure_raid5() {
    log_info "Setting up RAID5 array..."
    
    # Wipe existing signatures
    for drive in "${DATA_DRIVES[@]}"; do
        wipefs -a "$drive" || log_warning "Could not wipe $drive"
    done
    
    # Create RAID5 array
    if mdadm --create /dev/md0 --level=5 --raid-devices=${#DATA_DRIVES[@]} "${DATA_DRIVES[@]}" --verbose; then
        log_success "RAID5 array created successfully"
        
        # Save configuration
        mdadm --detail --scan >> /etc/mdadm.conf
        
        # Wait for array to be ready
        log_info "Waiting for RAID array to initialize..."
        sleep 10
        
        # Create LVM
        if pvcreate /dev/md0 && vgcreate data /dev/md0; then
            log_success "LVM volume group 'data' created on RAID5"
            return 0
        else
            log_error "Failed to create LVM on RAID5"
            return 1
        fi
    else
        log_error "Failed to create RAID5 array"
        return 1
    fi
}

# Function to configure RAID1
configure_raid1() {
    log_info "Setting up RAID1 array..."
    
    # Wipe existing signatures
    for drive in "${DATA_DRIVES[@]}"; do
        wipefs -a "$drive" || log_warning "Could not wipe $drive"
    done
    
    # Create RAID1 array
    if mdadm --create /dev/md0 --level=1 --raid-devices=2 "${DATA_DRIVES[@]}" --verbose; then
        log_success "RAID1 array created successfully"
        
        # Save configuration
        mdadm --detail --scan >> /etc/mdadm.conf
        
        # Wait for array to be ready
        log_info "Waiting for RAID array to sync..."
        sleep 10
        
        # Create LVM
        if pvcreate /dev/md0 && vgcreate data /dev/md0; then
            log_success "LVM volume group 'data' created on RAID1"
            return 0
        else
            log_error "Failed to create LVM on RAID1"
            return 1
        fi
    else
        log_error "Failed to create RAID1 array"
        return 1
    fi
}

# Function to configure single drive
configure_single_drive() {
    local drive="${DATA_DRIVES[0]}"
    log_info "Setting up single drive: $drive"
    
    # Wipe existing signatures
    wipefs -a "$drive" || log_warning "Could not wipe $drive"
    
    # Create LVM directly on drive
    if pvcreate "$drive" && vgcreate data "$drive"; then
        log_success "LVM volume group 'data' created on single drive"
        return 0
    else
        log_error "Failed to create LVM on single drive"
        return 1
    fi
}

# Function to create logical volumes and filesystems
create_storage_volumes() {
    log_info "Creating logical volumes for workloads..."
    
    # Check if data VG exists
    if ! vgdisplay data &>/dev/null; then
        log_warning "No 'data' volume group found, skipping volume creation"
        return 0
    fi
    
    # Get available space using a more reliable method
    local data_free_gb
    
    # Use vgs command which gives more consistent output
    local vgs_output
    if vgs_output=$(vgs data --noheadings --units g --options vg_free 2>/dev/null); then
        # Extract the number from output like "  3543.46g"
        data_free_gb=$(echo "$vgs_output" | sed 's/[^0-9.]//g' | cut -d. -f1)
        log_info "Available space from vgs: ${data_free_gb}GB"
    else
        # Fallback to vgdisplay parsing
        local data_free_raw
        data_free_raw=$(vgdisplay data | grep "Free.*PE.*Size" | awk '{print $7}' | sed 's/[<>]//g')
        log_info "Raw VG free space from vgdisplay: $data_free_raw"
        
        # Handle different units
        if [[ "$data_free_raw" =~ ([0-9.]+)[[:space:]]*GiB ]]; then
            data_free_gb=$(echo "${BASH_REMATCH[1]} * 1.024 * 1.024" | bc | cut -d. -f1)
        elif [[ "$data_free_raw" =~ ([0-9.]+)[[:space:]]*TiB ]]; then
            data_free_gb=$(echo "${BASH_REMATCH[1]} * 1024" | bc | cut -d. -f1)
        elif [[ "$data_free_raw" =~ ([0-9.]+)[[:space:]]*GB ]]; then
            data_free_gb=${BASH_REMATCH[1]%.*}
        elif [[ "$data_free_raw" =~ ([0-9.]+)[[:space:]]*TB ]]; then
            data_free_gb=$(echo "${BASH_REMATCH[1]} * 1000" | bc | cut -d. -f1)
        elif [[ "$data_free_raw" =~ ^([0-9.]+)$ ]]; then
            # Just a number, assume TiB
            data_free_gb=$(echo "${BASH_REMATCH[1]} * 1024" | bc | cut -d. -f1)
        else
            log_error "Could not parse available space format: $data_free_raw"
            log_info "Please check 'vgdisplay data' output manually"
            return 1
        fi
    fi
    
    if [[ -z "$data_free_gb" ]] || (( data_free_gb < 50 )); then
        log_warning "Insufficient space for volume creation: ${data_free_gb}GB"
        return 0
    fi
    
    log_info "Available space: ${data_free_gb}GB"
    
    # Calculate sizes (leaving 5% free space)
    local usable_space=$((data_free_gb * 95 / 100))
    local vm_size=$((usable_space * 40 / 100))
    local container_size=$((usable_space * 30 / 100))
    local storage_size=$((usable_space * 25 / 100))
    
    log_info "Creating volumes: VM=${vm_size}G, Container=${container_size}G, Storage=${storage_size}G"
    
    # Create logical volumes
    if lvcreate -L "${vm_size}G" -n lvvms data &&
       lvcreate -L "${container_size}G" -n lvcontainers data &&
       lvcreate -L "${storage_size}G" -n lvstorage data; then
        
        log_success "Logical volumes created successfully"
        
        # Create mount points
        mkdir -p /var/lib/libvirt /var/lib/containers /storage
        
        # Create filesystems
        log_info "Creating XFS filesystems..."
        if mkfs.xfs /dev/data/lvvms &&
           mkfs.xfs /dev/data/lvcontainers &&
           mkfs.xfs /dev/data/lvstorage; then
            
            log_success "Filesystems created successfully"
            
            # Add to fstab
            {
                echo "/dev/data/lvvms /var/lib/libvirt xfs defaults 0 2"
                echo "/dev/data/lvcontainers /var/lib/containers xfs defaults 0 2"
                echo "/dev/data/lvstorage /storage xfs defaults 0 2"
            } >> /etc/fstab
            
            # Mount filesystems
            if mount -a; then
                log_success "All filesystems mounted successfully"
                
                # Set proper ownership and permissions
                chown -R qemu:qemu /var/lib/libvirt 2>/dev/null || true
                chmod 755 /var/lib/libvirt /var/lib/containers /storage
                
                log_success "Storage configuration completed successfully"
                return 0
            else
                log_error "Failed to mount filesystems"
                return 1
            fi
        else
            log_error "Failed to create filesystems"
            return 1
        fi
    else
        log_error "Failed to create logical volumes"
        return 1
    fi
}

# Function to display final configuration
display_configuration() {
    echo -e "\n${GREEN}=== STORAGE CONFIGURATION SUMMARY ===${NC}"
    
    echo -e "\n${BLUE}Volume Groups:${NC}"
    vgdisplay | grep -E "VG Name|VG Size" || true
    
    echo -e "\n${BLUE}RAID Arrays:${NC}"
    if [[ -e /proc/mdstat ]]; then
        cat /proc/mdstat
    else
        echo "No RAID arrays configured"
    fi
    
    echo -e "\n${BLUE}Mounted Filesystems:${NC}"
    df -h | grep -E "(rocky|data|/storage)" || echo "No custom storage mounted"
    
    echo -e "\n${BLUE}Block Device Layout:${NC}"
    lsblk
    
    echo -e "\n${GREEN}Storage configuration completed at: $(date)${NC}"
}

# Function to handle cleanup on error
cleanup_on_error() {
    log_error "Script failed, performing cleanup..."
    
    # Stop and remove any partially created RAID arrays
    if [[ -e /dev/md0 ]]; then
        mdadm --stop /dev/md0 2>/dev/null || true
        mdadm --remove /dev/md0 2>/dev/null || true
    fi
    
    # Remove any LVM artifacts
    for vg in data; do
        if vgdisplay "$vg" &>/dev/null; then
            vgremove -f "$vg" 2>/dev/null || true
        fi
    done
}

# Main execution function
main() {
    # Set error trap
    trap cleanup_on_error ERR
    
    log_info "Starting storage configuration..."
    
    # Run configuration steps
    check_root
    check_prerequisites
    detect_boot_drive
    detect_data_drives
    
    # Skip boot drive expansion if we have data drives (it's not critical)
    if [[ ${#DATA_DRIVES[@]} -gt 0 ]]; then
        log_info "Data drives available, skipping boot drive expansion (not needed)"
    else
        expand_boot_drive
    fi
    
    configure_data_drives
    create_storage_volumes
    display_configuration
    
    log_success "Storage configuration completed successfully!"
    echo -e "\n${YELLOW}IMPORTANT:${NC} Restart Cockpit services to recognize new storage:"
    echo "  systemctl restart cockpit.socket"
    echo "  systemctl restart libvirtd"
    echo "  systemctl restart podman"
}

# Check if script is being sourced or executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi