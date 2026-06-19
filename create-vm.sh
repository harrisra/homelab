#!/usr/bin/env bash
# ============================================================================
# Proxmox Cloud-Init VM Deployer
# Creates an Ubuntu KVM VM (qm) provisioned via cloud-init: static network,
# SSH key auth, and an in-guest swapfile (qm has no native "swap" setting —
# that's an LXC/pct-only concept — so swap is created inside the guest OS
# via a cloud-init snippet on first boot).
#
# Run on your Proxmox host:
#   bash create-vm.sh
# ============================================================================

set -euo pipefail

# ── Colors & Helpers ────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

header() {
  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║          Proxmox Cloud-Init VM Deployer          ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
  echo ""
}

# ── Pre-flight checks ──────────────────────────────────────────────────────
preflight() {
  [[ $(id -u) -eq 0 ]] || error "This script must be run as root on the Proxmox host."
  command -v qm    &>/dev/null || error "qm not found. Are you running this on a Proxmox host?"
  command -v wget  &>/dev/null || error "wget not found."
}

# ── Snippets storage check ─────────────────────────────────────────────────
# Custom cloud-init (the swap runcmd below) requires the 'local' storage to
# have the Snippets content type enabled. This isn't on by default.
check_snippets() {
  local content
  content=$(pvesh get /storage/local --output-format json 2>/dev/null \
              | grep -o '"content":"[^"]*"' | cut -d'"' -f4)
  if [[ "$content" != *snippets* ]]; then
    warn "Storage 'local' does not have the 'Snippets' content type enabled."
    warn "Enable it once via: Datacenter → Storage → local → Edit → Content → tick 'Snippets'"
    warn "Or run: pvesm set local --content ${content:+${content},}snippets"
    read -rp "Continue anyway? (y/N): " c
    [[ "$c" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
  fi
}

# ── Configuration ───────────────────────────────────────────────────────────
get_config() {
  local next_id
  next_id=$(pvesh get /cluster/nextid 2>/dev/null || echo "100")

  echo -e "${BOLD}VM Configuration${NC}"
  echo "─────────────────────────────────────────────────"

  read -rp "VM ID [$next_id]: " VM_ID
  VM_ID="${VM_ID:-$next_id}"
  [[ "$VM_ID" =~ ^[0-9]+$ ]] || error "VM ID must be a number."
  qm status "$VM_ID" &>/dev/null && error "VM ID $VM_ID already exists."

  read -rp "VM name [ubuntu-vm]: " VM_NAME
  VM_NAME="${VM_NAME:-ubuntu-vm}"

  read -rp "CPU cores [2]: " VM_CORES
  VM_CORES="${VM_CORES:-2}"

  read -rp "RAM in MB [4096]: " VM_RAM
  VM_RAM="${VM_RAM:-4096}"

  read -rp "Swap in MB (in-guest swapfile, via cloud-init) [512]: " VM_SWAP
  VM_SWAP="${VM_SWAP:-512}"

  read -rp "Disk size in GB [20]: " VM_DISK
  VM_DISK="${VM_DISK:-20}"

  read -rp "Storage pool [local-lvm]: " VM_STORAGE
  VM_STORAGE="${VM_STORAGE:-local-lvm}"

  read -rp "Static IP/CIDR [192.168.1.70/24]: " VM_IP
  VM_IP="${VM_IP:-192.168.1.70/24}"

  if [[ "$VM_IP" == 192.168.1.70/* ]]; then
    warn "192.168.1.70 is already assigned to the existing code-server LXC (see lxc-code-server.md)."
    warn "Creating this VM with the same address WILL cause an IP conflict on the LAN."
    read -rp "Continue with this IP anyway? (y/N): " ipconfirm
    [[ "$ipconfirm" =~ ^[Yy]$ ]] || { echo "Aborted. Re-run with a different IP."; exit 0; }
  fi

  read -rp "Gateway [192.168.1.1]: " VM_GW
  VM_GW="${VM_GW:-192.168.1.1}"

  read -rp "DNS server [1.1.1.1]: " VM_DNS
  VM_DNS="${VM_DNS:-1.1.1.1}"

  read -rp "Cloud-init user [harrisra]: " VM_USER
  VM_USER="${VM_USER:-harrisra}"

  read -rp "Path to SSH public key [$HOME/.ssh/id_ed25519.pub]: " VM_SSHKEY
  VM_SSHKEY="${VM_SSHKEY:-$HOME/.ssh/id_ed25519.pub}"
  [[ -f "$VM_SSHKEY" ]] || error "SSH public key not found at $VM_SSHKEY"

  read -rsp "Cloud-init user password (optional, press Enter for key-only auth): " VM_PASSWORD
  echo ""

  echo ""
  echo -e "${BOLD}Summary${NC}"
  echo "─────────────────────────────────────────────────"
  echo "  VM ID:     $VM_ID"
  echo "  Name:      $VM_NAME"
  echo "  CPU:       $VM_CORES cores"
  echo "  RAM:       $VM_RAM MB"
  echo "  Swap:      $VM_SWAP MB (in-guest swapfile)"
  echo "  Disk:      ${VM_DISK}G on $VM_STORAGE"
  echo "  Network:   $VM_IP via $VM_GW"
  echo "  DNS:       $VM_DNS"
  echo "  CI user:   $VM_USER"
  echo "─────────────────────────────────────────────────"
  echo ""
  read -rp "Proceed? (y/N): " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
}

# ── Download Ubuntu 24.04 Cloud Image ──────────────────────────────────────
get_image() {
  IMG_URL="https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
  IMG_PATH="/var/lib/vz/template/iso/ubuntu-24.04-server-cloudimg-amd64.img"
  mkdir -p "$(dirname "$IMG_PATH")"
  if [[ ! -f "$IMG_PATH" ]]; then
    info "Downloading Ubuntu 24.04 cloud image..."
    wget -q --show-progress -O "$IMG_PATH" "$IMG_URL" || error "Failed to download cloud image."
  else
    success "Using cached cloud image: $IMG_PATH"
  fi
}

# ── Swap Cloud-Init Snippet ─────────────────────────────────────────────────
create_swap_snippet() {
  SNIPPET_DIR="/var/lib/vz/snippets"
  mkdir -p "$SNIPPET_DIR"
  SNIPPET_FILE="${SNIPPET_DIR}/vm-${VM_ID}-swap.yaml"
  cat > "$SNIPPET_FILE" <<EOF
#cloud-config
runcmd:
  - [ fallocate, -l, ${VM_SWAP}M, /swapfile ]
  - [ chmod, "600", /swapfile ]
  - [ mkswap, /swapfile ]
  - [ swapon, /swapfile ]
  - [ sh, -c, "echo '/swapfile none swap sw 0 0' >> /etc/fstab" ]
EOF
}

# ── Create VM ────────────────────────────────────────────────────────────────
create_vm() {
  info "Creating VM $VM_ID..."
  qm create "$VM_ID" \
    --name "$VM_NAME" \
    --memory "$VM_RAM" \
    --cores "$VM_CORES" \
    --cpu host \
    --net0 "virtio,bridge=vmbr0" \
    --ostype l26 \
    --scsihw virtio-scsi-pci \
    --agent enabled=1 \
    --serial0 socket \
    --vga serial0 \
    --onboot 1

  info "Importing cloud image as disk..."
  qm importdisk "$VM_ID" "$IMG_PATH" "$VM_STORAGE" >/dev/null

  qm set "$VM_ID" --scsi0 "${VM_STORAGE}:vm-${VM_ID}-disk-0" >/dev/null
  qm resize "$VM_ID" scsi0 "${VM_DISK}G" >/dev/null

  info "Attaching cloud-init drive and network config..."
  qm set "$VM_ID" --ide2 "${VM_STORAGE}:cloudinit" >/dev/null
  qm set "$VM_ID" --boot order=scsi0 >/dev/null
  qm set "$VM_ID" --ipconfig0 "ip=${VM_IP},gw=${VM_GW}" >/dev/null
  qm set "$VM_ID" --nameserver "$VM_DNS" >/dev/null
  qm set "$VM_ID" --ciuser "$VM_USER" >/dev/null
  qm set "$VM_ID" --sshkeys "$VM_SSHKEY" >/dev/null
  [[ -n "${VM_PASSWORD:-}" ]] && qm set "$VM_ID" --cipassword "$VM_PASSWORD" >/dev/null

  info "Configuring in-guest swapfile via cloud-init..."
  create_swap_snippet
  qm set "$VM_ID" --cicustom "vendor=local:snippets/vm-${VM_ID}-swap.yaml" >/dev/null

  success "VM $VM_ID created."
}

start_vm() {
  info "Starting VM $VM_ID..."
  qm start "$VM_ID"
}

# ── Print Summary ─────────────────────────────────────────────────────────
print_summary() {
  local ip_only="${VM_IP%%/*}"
  echo ""
  echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}${BOLD}║                  VM Ready!                        ║${NC}"
  echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${BOLD}VM:${NC}        $VM_ID ($VM_NAME)"
  echo -e "  ${BOLD}IP:${NC}        $ip_only"
  echo -e "  ${BOLD}Resources:${NC} ${VM_CORES} CPU / ${VM_RAM} MB RAM / ${VM_SWAP} MB swap / ${VM_DISK} GB disk"
  echo -e "  ${BOLD}Storage:${NC}   $VM_STORAGE"
  echo ""
  echo -e "  ${BOLD}Connect:${NC}"
  echo -e "    Console: ${CYAN}qm terminal $VM_ID${NC}"
  echo -e "    SSH:     ${CYAN}ssh ${VM_USER}@${ip_only}${NC}"
  echo ""
  echo -e "  ${BOLD}Note:${NC} cloud-init takes ~30-60s on first boot to apply networking,"
  echo -e "  the SSH key, and the swapfile. If SSH doesn't connect immediately, wait"
  echo -e "  and retry, or check progress with: ${CYAN}qm terminal $VM_ID${NC}"
  echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────
main() {
  header
  preflight
  check_snippets
  get_config
  get_image
  create_vm
  start_vm
  print_summary
}

main "$@"
