#!/usr/bin/env bash
###############################################################################
#  Inventory App — Smart Proxmox Deployment Script  (v5.0 — Final)
#  ─────────────────────────────────────────────────────────────────
#  No Docker Hub required — images are built locally.
#  Tested on: Proxmox VE 9.1, 8.x, 7.x
#
#  Usage:  bash deploy-proxmox.sh
###############################################################################

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
header()  { echo -e "\n${BOLD}━━━ $* ━━━${NC}\n"; }

###############################################################################
# PRE-FLIGHT
###############################################################################
preflight() {
    header "Pre-flight Checks"
    [[ $EUID -eq 0 ]] || error "Must be root on Proxmox host."
    for cmd in pvesh pvesm pct; do
        command -v "$cmd" &>/dev/null || error "'$cmd' not found."
    done
    if ! command -v jq &>/dev/null; then
        info "Installing jq..."
        apt-get update -qq && apt-get install -y -qq jq
    fi
    PVE_VERSION=$(pveversion 2>/dev/null || echo "unknown")
    success "Proxmox: $PVE_VERSION"
}

###############################################################################
# RESOURCE DETECTION
###############################################################################
detect_resources() {
    header "Detecting Proxmox Resources"

    NODE=$(pvesh get /cluster/status --output-format json 2>/dev/null \
        | jq -r '.[] | select(.type=="node" and .local==1) | .name' 2>/dev/null || hostname)
    success "Node: $NODE"

    NEXT_VMID=$(pvesh get /cluster/nextid 2>/dev/null | tr -d '"' || echo 100)
    success "Next VMID: $NEXT_VMID"

    # Storage
    info "Storage pools:"; echo ""
    STORAGES=(); STORAGE_INFO=(); STORAGE_CONTENT=()
    local sj; sj=$(pvesm status --output-format json 2>/dev/null || echo "[]")
    local cnt; cnt=$(echo "$sj" | jq 'length' 2>/dev/null || echo 0)
    for (( i=0; i<cnt; i++ )); do
        local nm ty co en ac av tt
        nm=$(echo "$sj" | jq -r ".[$i].storage // \"unknown\"")
        ty=$(echo "$sj" | jq -r ".[$i].type // \"unknown\"")
        co=$(echo "$sj" | jq -r ".[$i].content // \"\"")
        en=$(echo "$sj" | jq -r ".[$i].enabled // 1")
        ac=$(echo "$sj" | jq -r ".[$i].active // 1")
        tt=$(echo "$sj" | jq -r ".[$i].total // 0")
        av=$(echo "$sj" | jq -r ".[$i].avail // 0")
        [[ "$en" == "0" || "$ac" == "0" ]] && continue
        local ah th
        if [[ "$av" =~ ^[0-9]+$ ]] && (( av > 0 )); then
            ah=$(numfmt --to=iec-i --suffix=B "$av" 2>/dev/null || echo "$av")
            th=$(numfmt --to=iec-i --suffix=B "$tt" 2>/dev/null || echo "$tt")
        else ah="N/A"; th="N/A"; fi
        STORAGES+=("$nm"); STORAGE_INFO+=("$nm ($ty) Free:$ah/$th"); STORAGE_CONTENT+=("$co")
        echo -e "  ${GREEN}[${#STORAGES[@]}]${NC} ${BOLD}$nm${NC} ${DIM}($ty)${NC} Free:$ah / Total:$th"
    done
    if [[ ${#STORAGES[@]} -eq 0 ]]; then
        warn "JSON found nothing, text fallback..."
        while IFS= read -r line; do
            local sn; sn=$(echo "$line" | awk '{print $1}'); [[ -n "$sn" ]] || continue
            STORAGES+=("$sn"); STORAGE_INFO+=("$sn"); STORAGE_CONTENT+=("")
        done < <(pvesm status 2>/dev/null | tail -n +2)
    fi
    [[ ${#STORAGES[@]} -gt 0 ]] || error "No storage found."
    echo ""

    # Bridges
    info "Network bridges:"; echo ""
    BRIDGES=()
    while IFS= read -r b; do [[ -n "$b" ]] || continue; BRIDGES+=("$b")
        local ip; ip=$(ip -4 addr show "$b" 2>/dev/null | grep -oP 'inet \K[\d./]+' | head -1 || echo "")
        echo -e "  ${GREEN}[${#BRIDGES[@]}]${NC} ${BOLD}$b${NC} $ip"
    done < <(grep -oP '^iface \Kvmbr\d+' /etc/network/interfaces 2>/dev/null | sort -u)
    if [[ ${#BRIDGES[@]} -eq 0 ]]; then
        while IFS= read -r b; do [[ -n "$b" ]] || continue; BRIDGES+=("$b")
            echo -e "  ${GREEN}[${#BRIDGES[@]}]${NC} ${BOLD}$b${NC}"
        done < <(ls /sys/class/net/ 2>/dev/null | grep '^vmbr')
    fi
    [[ ${#BRIDGES[@]} -gt 0 ]] || error "No bridges found."
    echo ""

    # Templates
    info "Ubuntu CT templates..."
    TEMPLATES=(); local tss=()
    for idx in "${!STORAGES[@]}"; do
        local c="${STORAGE_CONTENT[$idx]:-}"
        [[ "$c" == *"vztmpl"* || -z "$c" ]] && tss+=("${STORAGES[$idx]}")
    done
    [[ ${#tss[@]} -gt 0 ]] || tss=("${STORAGES[@]}")
    for s in "${tss[@]}"; do
        while IFS= read -r t; do [[ -n "$t" ]] && TEMPLATES+=("$t")
        done < <(pveam list "$s" 2>/dev/null | grep -i ubuntu | awk '{print $1}' || true)
    done
    [[ ${#TEMPLATES[@]} -gt 0 ]] && success "Found ${#TEMPLATES[@]} template(s)" || info "Will download one"

    # Host resources
    TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
    FREE_RAM_MB=$(free -m | awk '/^Mem:/{print $2-$3}')
    TOTAL_CPUS=$(nproc)
    success "CPUs: $TOTAL_CPUS | RAM: ${TOTAL_RAM_MB}MB (free ~${FREE_RAM_MB}MB)"
}

###############################################################################
# PROMPTS
###############################################################################
prompt_value() {
    local p="$1" d="$2" mn="${3:-}" mx="${4:-}" v
    while true; do
        read -rp "$(echo -e "${BOLD}$p${NC} [$d]: ")" v; v=${v:-$d}
        [[ "$v" =~ ^[0-9]+$ ]] || { warn "Number required"; continue; }
        [[ -n "$mn" ]] && (( v < mn )) && { warn "Min $mn"; continue; }
        [[ -n "$mx" ]] && (( v > mx )) && { warn "Max $mx"; continue; }
        echo "$v"; return
    done
}
prompt_yn() {
    local v; read -rp "$(echo -e "${BOLD}$1${NC} [$2]: ")" v; v=${v:-$2}; [[ "$v" =~ ^[Yy] ]]
}

###############################################################################
# CONFIGURE
###############################################################################
configure() {
    header "Configuration"

    echo -e "${BOLD}Deployment type:${NC}\n  1) LXC (recommended)\n  2) QEMU VM"
    read -rp "> [1]: " dt; dt=${dt:-1}
    [[ "$dt" == "2" ]] && DEPLOY_TYPE="vm" || DEPLOY_TYPE="lxc"
    echo ""

    VMID=$(prompt_value "VMID" "$NEXT_VMID" 100 999999999); echo ""

    read -rp "$(echo -e "${BOLD}Hostname${NC} [inventory-stack]: ")" CT_HOSTNAME
    CT_HOSTNAME=${CT_HOSTNAME:-inventory-stack}; echo ""

    if [[ ${#STORAGES[@]} -eq 1 ]]; then STORAGE="${STORAGES[0]}"; info "Storage: $STORAGE"
    else
        echo -e "${BOLD}Storage:${NC}"
        for i in "${!STORAGES[@]}"; do echo "  $((i+1))) ${STORAGE_INFO[$i]}"; done
        read -rp "> [1]: " sc; sc=${sc:-1}
        [[ "$sc" =~ ^[0-9]+$ ]] && (( sc>=1 && sc<=${#STORAGES[@]} )) && STORAGE="${STORAGES[$((sc-1))]}" || STORAGE="${STORAGES[0]}"
    fi; echo ""

    DISK_SIZE=$(prompt_value "Disk GB (min 30)" "50" 30 500); echo ""

    local mxc=$((TOTAL_CPUS>2?TOTAL_CPUS-1:TOTAL_CPUS)) dc=$((TOTAL_CPUS>=6?4:(TOTAL_CPUS>=4?3:2)))
    CPU_CORES=$(prompt_value "CPU cores (host:$TOTAL_CPUS)" "$dc" 2 "$mxc"); echo ""

    local dr=$((FREE_RAM_MB>12288?8192:(FREE_RAM_MB>8192?6144:4096)))
    RAM_MB=$(prompt_value "RAM MB (min 4096)" "$dr" 4096 "$((TOTAL_RAM_MB-1024))"); echo ""

    local ds=$((RAM_MB/2)); (( ds>4096 )) && ds=4096
    SWAP_MB=$(prompt_value "Swap MB" "$ds" 512 16384); echo ""

    if [[ ${#BRIDGES[@]} -eq 1 ]]; then BRIDGE="${BRIDGES[0]}"; info "Bridge: $BRIDGE"
    else
        echo -e "${BOLD}Bridge:${NC}"
        for i in "${!BRIDGES[@]}"; do echo "  $((i+1))) ${BRIDGES[$i]}"; done
        read -rp "> [1]: " bc; bc=${bc:-1}
        [[ "$bc" =~ ^[0-9]+$ ]] && (( bc>=1 && bc<=${#BRIDGES[@]} )) && BRIDGE="${BRIDGES[$((bc-1))]}" || BRIDGE="${BRIDGES[0]}"
    fi; echo ""

    echo -e "${BOLD}IP config:${NC}\n  1) DHCP\n  2) Static"
    read -rp "> [1]: " ic; ic=${ic:-1}
    if [[ "$ic" == "2" ]]; then
        read -rp "Static IP (CIDR): " STATIC_IP; read -rp "Gateway: " GATEWAY
        NET_CONFIG="ip=${STATIC_IP},gw=${GATEWAY}"
    else NET_CONFIG="ip=dhcp"; fi; echo ""

    read -rp "$(echo -e "${BOLD}DNS${NC} [8.8.8.8]: ")" DNS_SERVER; DNS_SERVER=${DNS_SERVER:-8.8.8.8}; echo ""

    SSH_KEY=""; ROOT_PASS=""
    read -rp "$(echo -e "${BOLD}SSH key path${NC} [~/.ssh/id_rsa.pub or 'skip']: ")" SSH_KEY_PATH
    SSH_KEY_PATH=${SSH_KEY_PATH:-~/.ssh/id_rsa.pub}
    if [[ "$SSH_KEY_PATH" != "skip" ]] && [[ -f "$SSH_KEY_PATH" ]]; then SSH_KEY=$(cat "$SSH_KEY_PATH"); success "SSH key loaded"
    else
        [[ "$SSH_KEY_PATH" != "skip" ]] && warn "Not found"
        read -rsp "$(echo -e "${BOLD}Root password:${NC} ")" ROOT_PASS; echo ""
        [[ -n "$ROOT_PASS" ]] || ROOT_PASS="inventory2026"
    fi; echo ""

    read -rp "$(echo -e "${BOLD}App repo${NC} [https://github.com/AviFR-dev/inventory-app.git]: ")" APP_REPO
    APP_REPO=${APP_REPO:-https://github.com/AviFR-dev/inventory-app.git}
    read -rp "$(echo -e "${BOLD}K8s repo${NC} [https://github.com/AviFR-dev/inventory-k8s.git]: ")" K8S_REPO
    K8S_REPO=${K8S_REPO:-https://github.com/AviFR-dev/inventory-k8s.git}; echo ""

    read -rp "$(echo -e "${BOLD}Docker image name${NC} [avifrdev/inventory-app]: ")" DOCKER_IMAGE
    DOCKER_IMAGE=${DOCKER_IMAGE:-avifrdev/inventory-app}; echo ""

    echo -e "${BOLD}Components:${NC}"
    prompt_yn "K3s? (Y/n)" "Y" && INSTALL_K3S=true || INSTALL_K3S=false
    prompt_yn "Jenkins? (Y/n)" "Y" && INSTALL_JENKINS=true || INSTALL_JENKINS=false
    prompt_yn "Argo CD? (Y/n)" "Y" && INSTALL_ARGOCD=true || INSTALL_ARGOCD=false
    prompt_yn "Inventory App? (Y/n)" "Y" && INSTALL_APP=true || INSTALL_APP=false
    echo ""
}

###############################################################################
# CONFIRM
###############################################################################
confirm() {
    header "Summary"
    cat <<EOF
  VMID:$VMID  Host:$CT_HOSTNAME  Storage:$STORAGE  Disk:${DISK_SIZE}G
  CPU:$CPU_CORES  RAM:${RAM_MB}M  Swap:${SWAP_MB}M  Bridge:$BRIDGE  Net:$NET_CONFIG
  Image: $DOCKER_IMAGE (local build, no Docker Hub)
  K3s=$INSTALL_K3S Jenkins=$INSTALL_JENKINS ArgoCD=$INSTALL_ARGOCD App=$INSTALL_APP
EOF
    echo ""; prompt_yn "Proceed? (Y/n)" "Y" || { info "Aborted."; exit 0; }
}

###############################################################################
# TEMPLATE
###############################################################################
ensure_template() {
    header "CT Template"
    if [[ ${#TEMPLATES[@]} -gt 0 ]]; then
        if [[ ${#TEMPLATES[@]} -eq 1 ]]; then CT_TEMPLATE="${TEMPLATES[0]}"
        else
            for i in "${!TEMPLATES[@]}"; do echo "  $((i+1))) ${TEMPLATES[$i]}"; done
            read -rp "> [${#TEMPLATES[@]}]: " tc; tc=${tc:-${#TEMPLATES[@]}}
            CT_TEMPLATE="${TEMPLATES[$((tc-1))]}"
        fi
        success "Template: $CT_TEMPLATE"
    else
        local ts="$STORAGE"
        for idx in "${!STORAGES[@]}"; do
            [[ "${STORAGE_CONTENT[$idx]:-}" == *"vztmpl"* ]] && { ts="${STORAGES[$idx]}"; break; }
        done
        pveam update || true
        local tn
        tn=$(pveam available --section system 2>/dev/null | grep "ubuntu-22.04" | tail -1 | awk '{print $2}')
        [[ -n "$tn" ]] || tn=$(pveam available --section system 2>/dev/null | grep "ubuntu-24.04" | tail -1 | awk '{print $2}')
        [[ -n "$tn" ]] || error "No Ubuntu template available"
        pveam download "$ts" "$tn"
        CT_TEMPLATE="${ts}:vztmpl/${tn}"
        success "Downloaded: $CT_TEMPLATE"
    fi
}

###############################################################################
# CREATE LXC
###############################################################################
create_lxc() {
    header "Creating LXC ($VMID)"
    pct status "$VMID" &>/dev/null && error "VMID $VMID exists."

    local args=("$VMID" "$CT_TEMPLATE" --hostname "$CT_HOSTNAME"
        --storage "$STORAGE" --rootfs "${STORAGE}:${DISK_SIZE}"
        --cores "$CPU_CORES" --memory "$RAM_MB" --swap "$SWAP_MB"
        --net0 "name=eth0,bridge=${BRIDGE},${NET_CONFIG}" --nameserver "$DNS_SERVER"
        --features "nesting=1,keyctl=1" --unprivileged 0 --onboot 1 --start 0)
    [[ -n "$SSH_KEY" ]] && { echo "$SSH_KEY" > /tmp/_sshkey$$; args+=(--ssh-public-keys /tmp/_sshkey$$); }
    [[ -n "${ROOT_PASS:-}" ]] && args+=(--password "$ROOT_PASS")

    pct create "${args[@]}"; rm -f /tmp/_sshkey$$

    info "LXC K8s config..."
    local cf="/etc/pve/lxc/${VMID}.conf"
    for l in "lxc.apparmor.profile: unconfined" "lxc.cgroup2.devices.allow: a" \
        "lxc.cap.drop:" "lxc.mount.auto: proc:rw sys:rw" \
        "lxc.mount.entry: /dev/kmsg dev/kmsg none defaults,bind,create=file"; do
        grep -qF "$l" "$cf" 2>/dev/null || echo "$l" >> "$cf"
    done

    pct start "$VMID"; sleep 5
    info "Waiting for network..."
    local r=30; while (( r > 0 )); do
        pct exec "$VMID" -- ping -c1 -W2 8.8.8.8 &>/dev/null && break; sleep 3; ((r--))
    done
    CT_IP=$(pct exec "$VMID" -- hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")
    success "Container up — IP: $CT_IP"
}

###############################################################################
# GENERATE GUEST SCRIPT
#
# Strategy: Write the script to a temp file line-by-line using echo/printf.
# This avoids ALL heredoc-inside-heredoc issues.
###############################################################################
generate_setup_script() {
    local SF="/tmp/_guest_setup_$$.sh"

    # Write the entire guest script to a file
    cat > "$SF" << 'GUESTSCRIPT_PART1'
#!/usr/bin/env bash
set -uo pipefail   # NOTE: no -e, we handle errors manually to avoid CRD crash

export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()     { echo -e "${RED}[ERR]${NC}  $*"; }
header()  { echo -e "\n${BOLD}━━━ $* ━━━${NC}\n"; }
die()     { err "$*"; exit 1; }

GUESTSCRIPT_PART1

    # Inject variables (these get expanded NOW by the host shell)
    cat >> "$SF" << GUESTSCRIPT_VARS
INSTALL_K3S="${INSTALL_K3S}"
INSTALL_JENKINS="${INSTALL_JENKINS}"
INSTALL_ARGOCD="${INSTALL_ARGOCD}"
INSTALL_APP="${INSTALL_APP}"
APP_REPO="${APP_REPO}"
K8S_REPO="${K8S_REPO}"
DOCKER_IMAGE="${DOCKER_IMAGE}"
GUESTSCRIPT_VARS

    # Rest of the script — single-quoted so NO expansion happens
    cat >> "$SF" << 'GUESTSCRIPT_PART2'

SUMMARY=()

###########################################################################
# PHASE 1 — Base System
###########################################################################
header "Phase 1: Base System"

[[ -e /dev/kmsg ]] || ln -s /dev/console /dev/kmsg
printf '#!/bin/sh\n[ -e /dev/kmsg ] || ln -s /dev/console /dev/kmsg\nexit 0\n' > /etc/rc.local
chmod +x /etc/rc.local

apt-get update -qq
apt-get install -y -qq locales
sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen
locale-gen en_US.UTF-8
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

apt-get upgrade -y -qq
apt-get install -y -qq \
    curl wget git apt-transport-https ca-certificates gnupg \
    lsb-release software-properties-common jq unzip \
    python3 python3-pip python3-venv \
    iptables open-iscsi apparmor apparmor-utils socat

systemctl enable --now iscsid 2>/dev/null || true

printf 'export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"\nexport KUBECONFIG=/root/.kube/config\n' \
    > /etc/profile.d/inventory-env.sh
chmod +x /etc/profile.d/inventory-env.sh
grep -qF '/usr/local/bin' /root/.bashrc 2>/dev/null || \
    printf 'export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"\nexport KUBECONFIG=/root/.kube/config\n' >> /root/.bashrc

success "Base packages installed"

if ! command -v docker &>/dev/null; then
    info "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
fi
success "Docker: $(docker --version)"

###########################################################################
# PHASE 2 — K3s
###########################################################################
if [[ "$INSTALL_K3S" == "true" ]]; then
    header "Phase 2: K3s"

    if ! (command -v k3s &>/dev/null && k3s kubectl get nodes &>/dev/null); then
        curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--docker --disable=traefik --write-kubeconfig-mode=644" sh - 2>/dev/null || {
            warn "K3s+Docker failed, trying containerd..."
            curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable=traefik --write-kubeconfig-mode=644" sh -
        }
    fi

    info "Waiting for K3s..."
    sleep 10
    r=60; while (( r > 0 )); do
        k3s kubectl get nodes 2>/dev/null | grep -q " Ready" && break; sleep 5; ((r--))
    done
    (( r > 0 )) || die "K3s not ready after 5min"

    mkdir -p /root/.kube
    cp /etc/rancher/k3s/k3s.yaml /root/.kube/config
    chmod 600 /root/.kube/config
    export KUBECONFIG=/root/.kube/config
    ln -sf "$(which k3s)" /usr/local/bin/kubectl 2>/dev/null || true

    kubectl get nodes || die "kubectl cannot reach API"
    success "K3s ready"
    SUMMARY+=("K3s: running")
fi

###########################################################################
# PHASE 3 — Namespace
###########################################################################
if [[ "$INSTALL_K3S" == "true" ]]; then
    header "Phase 3: Namespace & Resources"
    export KUBECONFIG=/root/.kube/config

    kubectl create namespace inventory-system --dry-run=client -o yaml | kubectl apply -f -

    kubectl apply -f - << 'KCMEOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: inventory-config
  namespace: inventory-system
data:
  DB_HOST: "inventory-db"
  DB_PORT: "5432"
  DB_NAME: "inventory"
  APP_ENV: "production"
KCMEOF

    B64_USER=""; B64_PASS=""
    B64_USER=$(echo -n "postgres" | base64)
    B64_PASS=$(echo -n "postgres" | base64)
    kubectl apply -f - << KSEOF
apiVersion: v1
kind: Secret
metadata:
  name: inventory-secret
  namespace: inventory-system
type: Opaque
data:
  DB_USER: ${B64_USER}
  DB_PASSWORD: ${B64_PASS}
KSEOF

    success "Namespace ready"
fi

###########################################################################
# PHASE 4 — Build Docker Image
###########################################################################
if [[ "$INSTALL_APP" == "true" ]]; then
    header "Phase 4: Build Docker Image"

    info "Cloning K8s repo to read image tag..."
    rm -rf /tmp/inventory-k8s
    git clone "$K8S_REPO" /tmp/inventory-k8s 2>/dev/null

    # Read the image tag from Helm values.yaml
    IMAGE_TAG="latest"
    if [[ -f /tmp/inventory-k8s/helm/values.yaml ]]; then
        parsed_tag=""
        parsed_tag=$(grep -oP 'tag:\s*"?\K[^"]+' /tmp/inventory-k8s/helm/values.yaml 2>/dev/null | head -1 || echo "")
        if [[ -n "$parsed_tag" ]]; then
            IMAGE_TAG="$parsed_tag"
            info "Helm values.yaml specifies tag: $IMAGE_TAG"
        fi
    fi

    info "Cloning app repo..."
    rm -rf /tmp/inventory-app
    git clone "$APP_REPO" /tmp/inventory-app

    info "Building ${DOCKER_IMAGE}:${IMAGE_TAG} ..."
    cd /tmp/inventory-app
    docker build -f docker/Dockerfile.backend \
        -t "${DOCKER_IMAGE}:${IMAGE_TAG}" \
        -t "${DOCKER_IMAGE}:latest" \
        .

    success "Image built: ${DOCKER_IMAGE}:${IMAGE_TAG}"
    SUMMARY+=("Image: ${DOCKER_IMAGE}:${IMAGE_TAG} (local)")
fi

###########################################################################
# PHASE 5 — Jenkins
###########################################################################
if [[ "$INSTALL_JENKINS" == "true" ]]; then
    header "Phase 5: Jenkins"

    docker rm -f jenkins 2>/dev/null || true
    docker network create jenkins 2>/dev/null || true

    ld=""; ld=$(which docker)
    jv=(-v jenkins_home:/var/jenkins_home -v /var/run/docker.sock:/var/run/docker.sock -v "${ld}:/usr/bin/docker")
    [[ "$INSTALL_K3S" == "true" && -f /root/.kube/config ]] && jv+=(-v /root/.kube/config:/var/jenkins_home/.kube/config:ro)

    docker run -d --name jenkins --restart=unless-stopped --network jenkins \
        -p 8080:8080 -p 50000:50000 "${jv[@]}" jenkins/jenkins:lts

    info "Waiting for Jenkins (~60s)..."
    sleep 30

    r=24; JENKINS_PASS="not-ready"
    while (( r > 0 )); do
        docker exec jenkins test -f /var/jenkins_home/secrets/initialAdminPassword 2>/dev/null && {
            JENKINS_PASS=$(docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword); break; }
        sleep 5; ((r--))
    done

    docker exec -u root jenkins bash -c "groupadd -f docker; usermod -aG docker jenkins; chmod 666 /var/run/docker.sock" 2>/dev/null || true
    docker restart jenkins 2>/dev/null || true; sleep 10
    JENKINS_PASS=$(docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword 2>/dev/null || echo "$JENKINS_PASS")
    echo "$JENKINS_PASS" > /root/jenkins-initial-password.txt

    success "Jenkins on :8080 — password: $JENKINS_PASS"
    SUMMARY+=("Jenkins: port 8080")
fi

###########################################################################
# PHASE 6 — Trivy
###########################################################################
if [[ "$INSTALL_JENKINS" == "true" ]]; then
    header "Phase 6: Trivy"
    if ! command -v trivy &>/dev/null; then
        wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key | gpg --dearmor -o /usr/share/keyrings/trivy.gpg 2>/dev/null
        echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb generic main" > /etc/apt/sources.list.d/trivy.list
        apt-get update -qq && apt-get install -y -qq trivy
    fi
    trivy image --download-db-only 2>/dev/null || true
    success "Trivy ready"
    SUMMARY+=("Trivy: installed")
fi

###########################################################################
# PHASE 7 — Argo CD
###########################################################################
ARGOCD_NP=""
if [[ "$INSTALL_ARGOCD" == "true" && "$INSTALL_K3S" == "true" ]]; then
    header "Phase 7: Argo CD"
    export KUBECONFIG=/root/.kube/config

    kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

    # FIX: || true prevents CRD "annotations too long" error from killing the script
    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml || {
        warn "Argo CD install had non-critical errors (CRD annotation size) — continuing"
    }

    info "Waiting for Argo CD pods (2-3 min)..."
    kubectl wait --for=condition=Ready pods --all -n argocd --timeout=300s 2>/dev/null || warn "Some pods still starting"

    kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "NodePort"}}' 2>/dev/null || true
    sleep 5

    ARGOCD_NP=$(kubectl get svc argocd-server -n argocd -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}' 2>/dev/null || echo "")

    ap=""
    ap=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "not-ready")
    echo "$ap" > /root/argocd-initial-password.txt

    success "Argo CD installed — NodePort: $ARGOCD_NP"
    SUMMARY+=("Argo CD: NodePort $ARGOCD_NP")

    curl -sSL -o /usr/local/bin/argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64 2>/dev/null \
        && chmod +x /usr/local/bin/argocd || true
fi

###########################################################################
# PHASE 8 — Deploy App
###########################################################################
if [[ "$INSTALL_APP" == "true" && "$INSTALL_ARGOCD" == "true" && "$INSTALL_K3S" == "true" ]]; then
    header "Phase 8: Deploy Inventory App"
    export KUBECONFIG=/root/.kube/config

    # Write the Argo CD Application manifest to a temp file (avoids heredoc issues)
    ARGO_YAML="/tmp/argocd-app.yaml"
    cat > "$ARGO_YAML" << ARGOFILE
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: inventory-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${K8S_REPO}
    targetRevision: main
    path: helm
    helm:
      valueFiles:
        - values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: inventory-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: false
    syncOptions:
      - CreateNamespace=true
ARGOFILE

    kubectl apply -f "$ARGO_YAML"
    rm -f "$ARGO_YAML"
    success "Argo CD application created (self-heal DISABLED)"

    info "Waiting for deployment to appear..."
    r=24
    while (( r > 0 )); do
        kubectl get deployment inventory-backend -n inventory-system &>/dev/null && break
        sleep 10; ((r--))
    done

    if kubectl get deployment inventory-backend -n inventory-system &>/dev/null; then
        # Patch imagePullPolicy so K8s uses the locally built image
        kubectl patch deployment inventory-backend -n inventory-system \
            -p '{"spec":{"template":{"spec":{"containers":[{"name":"inventory-backend","imagePullPolicy":"IfNotPresent"}]}}}}' 2>/dev/null
        success "Patched imagePullPolicy → IfNotPresent"

        info "Waiting for pods..."
        r=30
        while (( r > 0 )); do
            run=0; tot=0
            run=$(kubectl get pods -n inventory-system --no-headers 2>/dev/null | grep -c Running || true)
            tot=$(kubectl get pods -n inventory-system --no-headers 2>/dev/null | wc -l | tr -d ' ' || true)
            run=${run:-0}; tot=${tot:-0}
            [[ "$run" -gt 0 && "$run" -ge "$tot" ]] && break
            info "  Pods: $run/$tot running..."
            sleep 10; ((r--))
        done
    else
        warn "Deployment not found after 4min — check Argo CD sync"
    fi

    kubectl get pods -n inventory-system 2>/dev/null || true
    SUMMARY+=("Inventory App: deployed")
fi

###########################################################################
# PHASE 9 — Port Forwarding (socat systemd services)
###########################################################################
if [[ "$INSTALL_APP" == "true" && "$INSTALL_K3S" == "true" ]]; then
    header "Phase 9: Port Forwarding"
    export KUBECONFIG=/root/.kube/config

    # --- App: port 5000 → ClusterIP:80 ---
    APP_CIP=""
    r=12
    while (( r > 0 )); do
        APP_CIP=$(kubectl get svc inventory-backend -n inventory-system -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
        [[ -n "$APP_CIP" ]] && break; sleep 10; ((r--))
    done

    if [[ -n "$APP_CIP" ]]; then
        info "App ClusterIP: $APP_CIP"
        printf '[Unit]\nDescription=Forward :5000 to Inventory App\nAfter=network.target k3s.service\n\n[Service]\nType=simple\nExecStart=/usr/bin/socat TCP-LISTEN:5000,fork,reuseaddr TCP:%s:80\nRestart=always\nRestartSec=5\n\n[Install]\nWantedBy=multi-user.target\n' "$APP_CIP" \
            > /etc/systemd/system/inventory-forward.service
    else
        warn "Could not get App ClusterIP"
    fi

    # --- Argo CD: port 9443 → NodePort ---
    if [[ -n "$ARGOCD_NP" ]]; then
        info "Argo CD NodePort: $ARGOCD_NP"
        printf '[Unit]\nDescription=Forward :9443 to Argo CD\nAfter=network.target k3s.service\n\n[Service]\nType=simple\nExecStart=/usr/bin/socat TCP-LISTEN:9443,fork,reuseaddr TCP:127.0.0.1:%s\nRestart=always\nRestartSec=5\n\n[Install]\nWantedBy=multi-user.target\n' "$ARGOCD_NP" \
            > /etc/systemd/system/argocd-forward.service
    fi

    systemctl daemon-reload
    [[ -f /etc/systemd/system/inventory-forward.service ]] && systemctl enable --now inventory-forward 2>/dev/null || true
    [[ -f /etc/systemd/system/argocd-forward.service ]] && systemctl enable --now argocd-forward 2>/dev/null || true

    sleep 3
    ss -tlnp | grep -E '5000|9443' || warn "Some ports not listening"

    if curl -sf http://localhost:5000/health &>/dev/null; then
        success "App responding on :5000"
    else
        warn "App not responding yet on :5000"
    fi
    success "Port forwarding configured"
fi

###########################################################################
# DONE
###########################################################################
header "Setup Complete!"
MY_IP=$(hostname -I | awk '{print $1}')
echo -e "
${BOLD}Access:${NC}
  App:      http://${MY_IP}:5000
  Jenkins:  http://${MY_IP}:8080
  Argo CD:  https://${MY_IP}:9443

${BOLD}Credentials:${NC}
  Jenkins:  $(cat /root/jenkins-initial-password.txt 2>/dev/null || echo 'N/A')
  Argo CD:  $(cat /root/argocd-initial-password.txt 2>/dev/null || echo 'N/A')

${BOLD}Installed:${NC}"
for s in "${SUMMARY[@]}"; do echo "  ✅ $s"; done
echo ""

GUESTSCRIPT_PART2

    echo "$SF"
}

###############################################################################
# DEPLOY INTO CONTAINER
###############################################################################
deploy_inside_container() {
    header "Running Setup in Container $VMID"

    local SF
    SF=$(generate_setup_script)

    pct push "$VMID" "$SF" /root/setup.sh --perms 755
    rm -f "$SF"

    info "Running setup (5-10 min)..."
    info "Monitor: pct exec $VMID -- tail -f /var/log/setup.log"
    echo ""

    pct exec "$VMID" -- bash -c "bash /root/setup.sh 2>&1 | tee /var/log/setup.log"

    success "Container setup complete!"
}

###############################################################################
# FINAL INFO
###############################################################################
final_info() {
    header "All Done!"
    echo -e "
${BOLD}╔═══════════════════════════════════════════════════════════════╗
║  Inventory Stack — Deployed on Proxmox!                       ║
╚═══════════════════════════════════════════════════════════════╝${NC}

  Container:  ${BOLD}$VMID${NC} ($CT_HOSTNAME)
  IP:         ${BOLD}$CT_IP${NC}

${BOLD}URLs:${NC}
  App:      ${GREEN}http://${CT_IP}:5000${NC}
  Jenkins:  ${GREEN}http://${CT_IP}:8080${NC}
  Argo CD:  ${GREEN}https://${CT_IP}:9443${NC}

${BOLD}Credentials:${NC}
  pct exec $VMID -- cat /root/jenkins-initial-password.txt
  pct exec $VMID -- cat /root/argocd-initial-password.txt

${BOLD}Commands:${NC}
  pct enter $VMID
  pct exec $VMID -- kubectl get pods -A
  pct exec $VMID -- kubectl get svc -A

${BOLD}Jenkins Setup:${NC}
  1. Open http://${CT_IP}:8080 → paste password
  2. Install plugins → New Item → Pipeline
  3. SCM: Git → ${APP_REPO} → Branch: */dev
  4. Build Now! (local build, no Docker Hub)
"
}

###############################################################################
# MAIN
###############################################################################
main() {
    echo -e "
${BOLD}╔═══════════════════════════════════════════════════════════════╗
║   Inventory App — Proxmox Deployment  v5.0 (Final)            ║
║   K3s + Jenkins + Argo CD — No Docker Hub Required            ║
╚═══════════════════════════════════════════════════════════════╝${NC}
"
    preflight; detect_resources; configure; confirm

    if [[ "$DEPLOY_TYPE" == "lxc" ]]; then
        ensure_template; create_lxc; deploy_inside_container
    else
        warn "VM mode: script saved to /root/inventory-guest-setup.sh"
        local sf; sf=$(generate_setup_script)
        cp "$sf" /root/inventory-guest-setup.sh; chmod +x /root/inventory-guest-setup.sh; rm -f "$sf"
    fi
    final_info
}

main "$@"
