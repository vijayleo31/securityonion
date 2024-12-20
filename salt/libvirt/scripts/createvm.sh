#!/bin/bash

# Ensure /root/create_vm/var/lib/libvirt/images exists
# Place this script in /root/create_vm
# Download OL9U5_x86_64-kvm-b253.qcow2 from https://yum.oracle.com/oracle-linux-templates.html, place in /root/create_vm/

# These steps will be removed from the process to create the final image and is being used for development
# This is used for the user-data auth portion of cloud-init
# Create passwd hash:
# python3 -c 'import crypt; print(crypt.crypt("YOUR_PASSWD_HERE", crypt.mksalt(crypt.METHOD_SHA512)))'
# Create ssh keypair:
# ssh-keygen -t ed25519 -C "soqemussh" -f ~/.ssh/soqemussh

# Run the script: createvm.sh coreol9Small 205G
# IP options may be removed for final version

# After running the script, the following will be output:
#[root@jppvirtman create_vm]# ll var/lib/libvirt/images/coreol9Small/
#total 610376
#-rw-r--r--. 1 root root    380928 Dec 20 14:33 coreol9Small-cidata.iso
#-rw-r--r--. 1 root root 624623616 Dec 20 14:33 coreol9Small.qcow2
#-rw-r--r--. 1 root root        55 Dec 20 14:32 meta-data
#-rw-r--r--. 1 root root       333 Dec 20 14:32 network-config
#-rw-r--r--. 1 root root      1047 Dec 20 14:32 user-data

# These files are now scp to a hypervisor node
# Place the files in /var/lib/libvirt/images/coreol9Small (or whatever is the same as the vm name)
# Create your storage pool as instructed by the script. this is only needed if one doesn't already exist
# Run the virt-install command as instructed by the script

# Could add the following to the final runcmd in the user-data to fill the disk to avoid the cons of thin provisioning the disk
#  - dd if=/dev/zero of=/tmp/fill bs=1M || true
#  - rm -f /tmp/fill

# Exit on any error
set -e

# Set variables and defaults
VM=${1:-"small-vm"}          # VM name
DISK_SIZE=${2:-"205G"}       # Disk size with unit (default 205G)
IP=${3:-"192.168.1.10"}      # IP address
GATEWAY=${4:-"192.168.1.1"}  # Gateway
DNS=${5:-"192.168.1.1"}      # Comma-separated list of DNS servers
MAC_ADDRESS="52:54:00:f2:c3:df"  # Default MAC - will be overridden if found

# Show usage if help is requested
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    echo "Usage: $0 <vm_name> <disk_size> <ip> <gateway> <dns_servers>"
    echo "Example: $0 myvm 100G 192.168.1.50 192.168.1.1 8.8.8.8,8.8.4.4"
    echo "Parameters:"
    echo "  vm_name    : Name of the VM (default: small-vm)"
    echo "  disk_size  : Size of the disk with unit G/M (default: 205G)"
    echo "  ip         : IP address (default: 192.168.1.10)"
    echo "  gateway    : Gateway address (default: 192.168.1.1)"
    echo "  dns_servers: Comma-separated DNS servers (default: 192.168.1.1)"
    echo "All parameters are optional and will use defaults if not specified"
    exit 0
fi

# Validate disk size format
if ! [[ $DISK_SIZE =~ ^[0-9]+[GM]$ ]]; then
    echo "Error: Disk size must be a number followed by G (gigabytes) or M (megabytes)"
    echo "Example: 100G or 51200M"
    exit 1
fi

# Convert comma-separated DNS servers to yaml format
format_dns() {
    local IFS=','
    local dns_list=($1)
    local yaml=""
    for dns in "${dns_list[@]}"; do
        yaml="$yaml                    - $dns"$'\n'
    done
    echo "$yaml"
}

DNS_YAML=$(format_dns "$DNS")

# Set up directory structure
D=/root/create_vm/var/lib/libvirt/images
mkdir -vp $D/$VM
cd $D/$VM

# Create cloud-init metadata
cat > meta-data << EOF
instance-id: ${VM}
local-hostname: ${VM}
EOF

# Create network configuration
cat > network-config << EOF
version: 2
ethernets:
    eth0:
        match:
            macaddress: ${MAC_ADDRESS}
        dhcp4: false
        dhcp6: false
        addresses:
            - ${IP}/24
        routes:
            - to: 0.0.0.0/0
              via: ${GATEWAY}
        nameservers:
            addresses:
$(format_dns "$DNS")
EOF

# Create user-data with network configuration
cat > user-data << EOF
#cloud-config
preserve_hostname: False
hostname: ${VM}
fqdn: ${VM}.local

users:
    - default
    - name: soqemussh
      groups: ['wheel']
      shell: /bin/bash
      sudo: ALL=(ALL) NOPASSWD:ALL
      lock_passwd: false
      passwd: $(echo '___YOUR_HASH_HERE___')
      ssh-authorized-keys:
        - ssh-ed25519 ___YOUR_PUB_KEY_HERE___ soqemussh

# Configure where output will go
output:
  all: ">> /var/log/cloud-init.log"

# configure interaction with ssh server
ssh_genkeytypes: ['ed25519', 'rsa']

# set timezone for VM
timezone: UTC

# Install QEMU guest agent. Enable and start the service
packages:
  - qemu-guest-agent

runcmd:
  - systemctl enable --now qemu-guest-agent
  - systemctl enable --now serial-getty@ttyS0.service
  - systemctl enable --now NetworkManager
  - growpart /dev/vda 2
  - pvresize /dev/vda2
  - lvextend -l +100%FREE /dev/vg_main/lv_root
  - xfs_growfs /dev/vg_main/lv_root
EOF

# First, copy the base image with progress
echo "Creating base VM image..."
rsync --progress /root/create_vm/OL9U5_x86_64-kvm-b253.qcow2 $VM.qcow2

# Resize the image to specified size
echo "Resizing image to $DISK_SIZE..."
echo "Current image size: $(qemu-img info $VM.qcow2 | grep 'virtual size' | cut -d':' -f2 | cut -d'(' -f1 | tr -d ' ')"
qemu-img resize -f qcow2 $VM.qcow2 $DISK_SIZE
echo "New image size: $(qemu-img info $VM.qcow2 | grep 'virtual size' | cut -d':' -f2 | cut -d'(' -f1 | tr -d ' ')"

# Now compress it with progress
echo "Compressing image..."
qemu-img convert -p -O qcow2 -c $VM.qcow2 $VM-compressed.qcow2
mv -v $VM-compressed.qcow2 $VM.qcow2

# Create a cloud-init ISO with network config and progress indication
echo "Creating cloud-init ISO..."
mkisofs -output $VM-cidata.iso -volid CIDATA -rock -verbose user-data meta-data network-config

# Echo the configuration for verification
echo "Creating VM with the following configuration:"
echo "VM Name: $VM"
echo "Disk Size: $DISK_SIZE"
echo "IP Address: $IP"
echo "Gateway: $GATEWAY"
echo "DNS Servers: $DNS"
echo "MAC Address: $MAC_ADDRESS"

echo "Files have been created in $D/$VM"
echo
echo "To complete VM creation on the hypervisor, run:"
echo "virsh pool-create-as --name $VM --type dir --target $D/$VM"
echo "virt-install --import --name ${VM} \\"
echo "    --memory 4096 --vcpus 4 --cpu host \\"
echo "    --disk ${VM}.qcow2,format=qcow2,bus=virtio \\"
echo "    --disk ${VM}-cidata.iso,device=cdrom \\"
echo "    --network bridge=br0,model=virtio,mac=${MAC_ADDRESS} \\"
echo "    --os-variant=ol9.5 \\"
echo "    --noautoconsole"
