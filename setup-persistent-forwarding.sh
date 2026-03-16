#!/usr/bin/env bash
###############################################################################
#  Persistent Port Forwarding Setup
#  Run this ON the Proxmox host as root
#  Creates systemd services for socat on both Proxmox and inside container 108
###############################################################################

set -euo pipefail

CONTAINER_IP="10.100.102.149"
VMID="108"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }

# ─── Install socat on Proxmox host if missing ────────────────────────────────
if ! command -v socat &>/dev/null; then
    info "Installing socat on Proxmox host..."
    apt-get update -qq && apt-get install -y -qq socat
fi

# ─── Kill existing socat processes on Proxmox host ───────────────────────────
pkill -f "socat TCP-LISTEN" 2>/dev/null || true
sleep 1

# ═══════════════════════════════════════════════════════════════════════════════
# PART 1: Inside container — socat from host port 5000 → K8s ClusterIP
# ═══════════════════════════════════════════════════════════════════════════════
info "Setting up persistent forwarder inside container $VMID..."

pct exec "$VMID" -- bash -c 'cat > /etc/systemd/system/inventory-forward.service << EOF
[Unit]
Description=Forward port 5000 to Inventory App ClusterIP
After=network.target k3s.service
Wants=k3s.service

[Service]
Type=simple
ExecStartPre=/usr/bin/bash -c "until curl -sf http://\$(KUBECONFIG=/root/.kube/config /usr/local/bin/k3s kubectl get svc inventory-backend -n inventory-system -o jsonpath={.spec.clusterIP} 2>/dev/null):80/health 2>/dev/null; do sleep 5; done"
ExecStart=/usr/bin/bash -c "CLUSTER_IP=\$(KUBECONFIG=/root/.kube/config /usr/local/bin/k3s kubectl get svc inventory-backend -n inventory-system -o jsonpath={.spec.clusterIP}); exec /usr/bin/socat TCP-LISTEN:5000,fork,reuseaddr TCP:\${CLUSTER_IP}:80"
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now inventory-forward.service
'

success "Container: inventory-forward.service enabled (port 5000 → app)"

# Also create forwarders for Jenkins (already on 8080 via Docker) and Argo CD
pct exec "$VMID" -- bash -c 'cat > /etc/systemd/system/argocd-forward.service << EOF
[Unit]
Description=Forward port 9443 to Argo CD NodePort
After=network.target k3s.service
Wants=k3s.service

[Service]
Type=simple
ExecStartPre=/usr/bin/bash -c "until KUBECONFIG=/root/.kube/config /usr/local/bin/k3s kubectl get svc argocd-server -n argocd 2>/dev/null | grep -q NodePort; do sleep 5; done"
ExecStart=/usr/bin/bash -c "NODEPORT=\$(KUBECONFIG=/root/.kube/config /usr/local/bin/k3s kubectl get svc argocd-server -n argocd -o jsonpath={.spec.ports[?(@.name==\"https\")].nodePort}); exec /usr/bin/socat TCP-LISTEN:9443,fork,reuseaddr TCP:127.0.0.1:\${NODEPORT}"
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now argocd-forward.service
'

success "Container: argocd-forward.service enabled (port 9443 → Argo CD)"

# ═══════════════════════════════════════════════════════════════════════════════
# PART 2: On Proxmox host — socat from host IP → container IP
# ═══════════════════════════════════════════════════════════════════════════════
info "Setting up persistent forwarders on Proxmox host..."

# App forwarder (Proxmox:5000 → Container:5000)
cat > /etc/systemd/system/fwd-inventory-app.service << EOF
[Unit]
Description=Forward port 5000 to Inventory App container
After=network.target pve-guests.service
Wants=pve-guests.service

[Service]
Type=simple
ExecStartPre=/usr/bin/bash -c "until ping -c1 -W2 ${CONTAINER_IP} &>/dev/null; do sleep 5; done"
ExecStart=/usr/bin/socat TCP-LISTEN:5000,fork,reuseaddr TCP:${CONTAINER_IP}:5000
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Jenkins forwarder (Proxmox:8080 → Container:8080)
cat > /etc/systemd/system/fwd-jenkins.service << EOF
[Unit]
Description=Forward port 8080 to Jenkins container
After=network.target pve-guests.service
Wants=pve-guests.service

[Service]
Type=simple
ExecStartPre=/usr/bin/bash -c "until ping -c1 -W2 ${CONTAINER_IP} &>/dev/null; do sleep 5; done"
ExecStart=/usr/bin/socat TCP-LISTEN:8080,fork,reuseaddr TCP:${CONTAINER_IP}:8080
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Argo CD forwarder (Proxmox:9443 → Container:9443)
cat > /etc/systemd/system/fwd-argocd.service << EOF
[Unit]
Description=Forward port 9443 to Argo CD container
After=network.target pve-guests.service
Wants=pve-guests.service

[Service]
Type=simple
ExecStartPre=/usr/bin/bash -c "until ping -c1 -W2 ${CONTAINER_IP} &>/dev/null; do sleep 5; done"
ExecStart=/usr/bin/socat TCP-LISTEN:9443,fork,reuseaddr TCP:${CONTAINER_IP}:9443
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now fwd-inventory-app.service
systemctl enable --now fwd-jenkins.service
systemctl enable --now fwd-argocd.service

success "Proxmox host: all forwarders enabled"

# ═══════════════════════════════════════════════════════════════════════════════
# Verify
# ═══════════════════════════════════════════════════════════════════════════════
sleep 3

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Persistent Port Forwarding — Active${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo ""

PROXMOX_IP=$(hostname -I | awk '{print $1}')

echo -e "${BOLD}Services inside container ($VMID):${NC}"
pct exec "$VMID" -- systemctl is-active inventory-forward.service 2>/dev/null && \
    echo -e "  ${GREEN}●${NC} inventory-forward  (5000 → app ClusterIP)" || \
    echo -e "  ○ inventory-forward  (not running)"
pct exec "$VMID" -- systemctl is-active argocd-forward.service 2>/dev/null && \
    echo -e "  ${GREEN}●${NC} argocd-forward     (9443 → Argo CD NodePort)" || \
    echo -e "  ○ argocd-forward     (not running)"

echo ""
echo -e "${BOLD}Services on Proxmox host:${NC}"
systemctl is-active fwd-inventory-app.service &>/dev/null && \
    echo -e "  ${GREEN}●${NC} fwd-inventory-app  (${PROXMOX_IP}:5000 → container:5000)" || \
    echo -e "  ○ fwd-inventory-app  (not running)"
systemctl is-active fwd-jenkins.service &>/dev/null && \
    echo -e "  ${GREEN}●${NC} fwd-jenkins        (${PROXMOX_IP}:8080 → container:8080)" || \
    echo -e "  ○ fwd-jenkins        (not running)"
systemctl is-active fwd-argocd.service &>/dev/null && \
    echo -e "  ${GREEN}●${NC} fwd-argocd         (${PROXMOX_IP}:9443 → container:9443)" || \
    echo -e "  ○ fwd-argocd         (not running)"

echo ""
echo -e "${BOLD}Access URLs (survive reboot):${NC}"
echo "  Inventory App:  http://${PROXMOX_IP}:5000"
echo "  Jenkins:        http://${PROXMOX_IP}:8080"
echo "  Argo CD:        https://${PROXMOX_IP}:9443"
echo ""
echo -e "${BOLD}Manage with:${NC}"
echo "  systemctl status fwd-inventory-app"
echo "  systemctl restart fwd-jenkins"
echo "  systemctl stop fwd-argocd"
echo ""
