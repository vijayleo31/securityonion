#!/bin/bash

# Exit on any error
set -e

# Set variables and defaults
VM=${1:-"small-vm"}          # VM name
IP=${2:-"192.168.1.10"}      # IP address
GATEWAY=${3:-"192.168.1.1"}  # Gateway
DNS=${4:-"192.168.1.1"}      # Comma-separated list of DNS servers
MAC_ADDRESS="52:54:00:f2:c3:df"  # Default MAC - will be overridden if found

# Show usage if help is requested
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    echo "Usage: $0 <vm_name> <ip> <gateway> <dns_servers>"
    echo "Example: $0 myvm 192.168.1.50 192.168.1.1 8.8.8.8,8.8.4.4"
    echo "All parameters are optional and will use defaults if not specified"
    exit 0
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

# Generate password hash using: 
# Create passwd hash
### python3 -c 'import crypt; print(crypt.crypt("YOUR_PASSWD_HERE", crypt.mksalt(crypt.METHOD_SHA512)))'
# Create ssh keypair
### ssh-keygen -t ed25519 -C "soqemussh" -f ~/.ssh/soqemussh

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
        - ssh-ed25519 ___YOUR_PUB_KEY_HERE___

# Configure where output will go
output:
  all: ">> /var/log/cloud-init.log"

# configure interaction with ssh server
ssh_genkeytypes: ['ed25519', 'rsa']

# set timezone for VM
timezone: UTC

# Don't preallocate the entire disk space
#resize_rootfs: true
#growpart:
#    mode: auto
#    devices: ['/']

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

# First, copy the base image
echo "Creating base VM image..."
cp -v /root/create_vm/OL9U5_x86_64-kvm-b253.qcow2 $VM.qcow2

# First resize the image to our desired size
echo "Resizing image..."
qemu-img resize $VM.qcow2 205G

# Now compress it
echo "Compressing image..."
qemu-img convert -p -O qcow2 -c $VM.qcow2 $VM-compressed.qcow2
mv -v $VM-compressed.qcow2 $VM.qcow2

# Create a cloud-init ISO with network config
echo "Creating cloud-init ISO..."
mkisofs -output $VM-cidata.iso -volid CIDATA -rock user-data meta-data network-config

# Echo the configuration for verification
echo "Creating VM with the following network configuration:"
echo "VM Name: $VM"
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
