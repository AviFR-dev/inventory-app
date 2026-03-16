# Inventory App — Proxmox Deployment Guide

**One-script deployment** of the complete CI/CD stack on a Proxmox home lab.  
No Docker Hub required — everything runs locally.

---

## What Gets Deployed

| Component | Purpose | Access |
|-----------|---------|--------|
| **K3s** | Lightweight Kubernetes | Inside container |
| **Jenkins** | CI pipeline (build, test, scan, deploy) | `http://<IP>:8080` |
| **Argo CD** | GitOps initial deployment | `https://<IP>:9443` |
| **Trivy** | Container image vulnerability scanner | Used by Jenkins |
| **Inventory App** | Flask + PostgreSQL web app | `http://<IP>:5000` |
| **PostgreSQL** | Database (runs in K8s) | Internal to cluster |

---

## Prerequisites

- **Proxmox VE** 7.x, 8.x, or 9.x
- **Root access** on the Proxmox host
- At least **4 CPU cores**, **8GB RAM**, **50GB disk** available for the container
- An Ubuntu CT template (script downloads one if not found)
- Internet connectivity (for pulling packages and images)

---

## Deployment

### Step 1 — Run the Script

Copy `deploy-proxmox.sh` to your Proxmox host and run as root:

```bash
bash deploy-proxmox.sh
```

The script will:
1. Detect your Proxmox resources (storage, bridges, RAM, CPUs)
2. Ask you to configure the container (VMID, disk size, RAM, network, etc.)
3. Create a privileged LXC container with K8s-compatible settings
4. Install everything inside the container automatically

**This takes approximately 10-15 minutes.**

### Step 2 — Verify Deployment

When the script finishes, it displays the container IP and access URLs:

```
Container:  132 (inventory-stack)
IP:         10.100.102.118

URLs:
  App:      http://10.100.102.118:5000
  Jenkins:  http://10.100.102.118:8080
  Argo CD:  https://10.100.102.118:9443
```

Open all three URLs in your browser to verify they load.

### Step 3 — Get Credentials

```bash
# Jenkins initial admin password
pct exec <VMID> -- cat /root/jenkins-initial-password.txt

# Argo CD admin password (username: admin)
pct exec <VMID> -- cat /root/argocd-initial-password.txt
```

---

## Post-Deployment Setup

After the automated deployment, you need to configure the Jenkins pipeline manually (one-time setup).

### 1. Jenkins First Login

1. Open `http://<CONTAINER_IP>:8080`
2. Paste the initial admin password
3. Click **Install suggested plugins** (wait for installation)
4. Create your admin user
5. Click **Save and Finish** → **Start using Jenkins**

### 2. Create the Pipeline Job

1. Click **New Item** on the dashboard
2. Enter name: `inventory-app`
3. Select **Pipeline** → click **OK**
4. Scroll down to the **Pipeline** section:
   - Definition: **Pipeline script from SCM**
   - SCM: **Git**
   - Repository URL: `https://github.com/AviFR-dev/inventory-app.git`
   - Branch Specifier: `*/dev`
   - Script Path: `Jenkinsfile`
5. Scroll up to **Build Triggers**:
   - Check **Poll SCM**
   - Schedule: `H/3 * * * *` (checks GitHub every 3 minutes)
6. Click **Save**

### 3. Run Your First Build

1. Click **Build Now**
2. Watch the pipeline execute 5 stages:
   - **Build** — installs Python dependencies
   - **Test** — runs 27 pytest tests
   - **Docker Build** — builds the container image locally
   - **Image Scan** — Trivy scans for CRITICAL vulnerabilities
   - **Deploy** — rolling update to K8s via `kubectl`
3. Verify the build shows **SUCCESS** (green checkmark)
4. Refresh `http://<CONTAINER_IP>:5000` to see the app

### 4. Argo CD (Optional Verification)

1. Open `https://<CONTAINER_IP>:9443` (accept the self-signed cert warning)
2. Login with username `admin` and the password from Step 3
3. You should see the `inventory-app` application in a **Synced** state

---

## Jenkinsfile

The repository's `Jenkinsfile` on the `dev` branch should contain this pipeline for local deployment (no Docker Hub):

```groovy
pipeline {
    agent any

    environment {
        DOCKER_IMAGE = "avifrdev/inventory-app"
        DOCKER_TAG   = "${BUILD_NUMBER}"
    }

    stages {
        stage('Build') {
            steps {
                echo 'Installing dependencies...'
                sh 'python3 -m pip install -r backend/requirements.txt pytest --break-system-packages'
            }
        }

        stage('Test') {
            steps {
                echo 'Running tests...'
                sh 'cd backend && python3 -m pytest tests/ -v'
            }
        }

        stage('Docker Build') {
            steps {
                echo 'Building Docker image...'
                sh "docker build -f docker/Dockerfile.backend -t ${DOCKER_IMAGE}:${DOCKER_TAG} ."
                sh "docker tag ${DOCKER_IMAGE}:${DOCKER_TAG} ${DOCKER_IMAGE}:latest"
            }
        }

        stage('Image Scan') {
            steps {
                echo 'Scanning image with Trivy...'
                sh "trivy image --exit-code 0 --severity CRITICAL ${DOCKER_IMAGE}:${DOCKER_TAG} || true"
            }
        }

        stage('Deploy') {
            steps {
                echo 'Deploying to Kubernetes...'
                sh """
                    kubectl set image deployment/inventory-backend \
                        inventory-backend=${DOCKER_IMAGE}:${DOCKER_TAG} \
                        -n inventory-system
                    kubectl patch deployment inventory-backend -n inventory-system \
                        -p '{"spec":{"template":{"spec":{"containers":[{"name":"inventory-backend","imagePullPolicy":"IfNotPresent"}]}}}}'
                    kubectl rollout status deployment/inventory-backend -n inventory-system --timeout=120s
                """
            }
        }
    }

    post {
        success {
            echo "✅ Pipeline completed! Image: ${DOCKER_IMAGE}:${DOCKER_TAG}"
        }
        failure {
            echo '❌ Pipeline failed!'
        }
    }
}
```

---

## CI/CD Workflow

Once everything is set up, the workflow is:

```
1. Edit code on the dev branch (GitHub)
       ↓
2. Jenkins detects change (polling every 3 min)
       ↓
3. Jenkins Pipeline runs:
   ├── Build:        pip install dependencies
   ├── Test:         pytest (27 tests)
   ├── Docker Build: builds image locally
   ├── Image Scan:   Trivy vulnerability check
   └── Deploy:       kubectl rolling update to K8s
       ↓
4. App live at http://<IP>:5000 with new version
```

**No Docker Hub needed** — images are built and consumed locally on the same K3s node.

---

## Architecture

```
Browser
  │
  ├── :5000 (socat) ──→ K8s ClusterIP ──→ Inventory App Pods (x3)
  │                                              │
  │                                              ▼
  │                                        PostgreSQL Pod
  │
  ├── :8080 (Docker) ──→ Jenkins Container
  │
  └── :9443 (socat) ──→ Argo CD (NodePort)

All inside a single Proxmox LXC container running:
  • K3s (Kubernetes)
  • Docker (container runtime)
  • socat (port forwarding via systemd)
```

---

## Useful Commands

Run from the **Proxmox host**:

```bash
# Enter the container
pct enter <VMID>

# Check all pods
pct exec <VMID> -- bash -c "export PATH=/usr/local/bin:\$PATH KUBECONFIG=/root/.kube/config; kubectl get pods -A"

# Check all services
pct exec <VMID> -- bash -c "export PATH=/usr/local/bin:\$PATH KUBECONFIG=/root/.kube/config; kubectl get svc -A"

# View app logs
pct exec <VMID> -- bash -c "export PATH=/usr/local/bin:\$PATH KUBECONFIG=/root/.kube/config; kubectl logs -n inventory-system -l app=inventory-backend --tail=20"

# View Jenkins logs
pct exec <VMID> -- docker logs jenkins -f

# Check port forwarding
pct exec <VMID> -- systemctl status inventory-forward argocd-forward

# View the initial setup log
pct exec <VMID> -- cat /var/log/setup.log
```

Run from **inside the container** (`pct enter <VMID>`):

```bash
kubectl get pods -A                    # All pods
kubectl get pods -n inventory-system   # App pods
kubectl get svc -A                     # All services
kubectl logs -f deploy/inventory-backend -n inventory-system  # App logs
docker logs jenkins -f                 # Jenkins logs
argocd app list                        # Argo CD apps
```

---

## Troubleshooting

### App shows "Internal Server Error"

The database schema is outdated. Reset it:

```bash
kubectl exec -n inventory-system deploy/inventory-db -- \
    psql -U postgres -d inventory -c 'DROP TABLE IF EXISTS stock_movements, products, categories CASCADE;'
kubectl rollout restart deployment/inventory-backend -n inventory-system
```

### Jenkins build fails at "Deploy" stage

**Permission denied on kubeconfig:**
```bash
docker exec -u root jenkins bash -c "
    cp /tmp/host-kubeconfig /var/jenkins_home/.kube/config
    chmod 644 /var/jenkins_home/.kube/config
    chown 1000:1000 /var/jenkins_home/.kube/config
"
```

**Connection refused to 127.0.0.1:6443:**
```bash
HOST_IP=$(hostname -I | awk '{print $1}')
docker exec -u root jenkins bash -c "sed -i 's|127.0.0.1|${HOST_IP}|g' /var/jenkins_home/.kube/config"
```

### App not accessible in browser

Check socat forwarding:
```bash
systemctl status inventory-forward
ss -tlnp | grep 5000
```

Restart if needed:
```bash
CIP=$(kubectl get svc inventory-backend -n inventory-system -o jsonpath='{.spec.clusterIP}')
printf '[Unit]\nDescription=Forward :5000 to App\nAfter=network.target k3s.service\n\n[Service]\nType=simple\nExecStart=/usr/bin/socat TCP-LISTEN:5000,fork,reuseaddr TCP:%s:80\nRestart=always\nRestartSec=5\n\n[Install]\nWantedBy=multi-user.target\n' "$CIP" > /etc/systemd/system/inventory-forward.service
systemctl daemon-reload
systemctl restart inventory-forward
```

### K3s not responding

```bash
systemctl status k3s
journalctl -u k3s --no-pager -n 50
```

### Pods stuck in ImagePullBackOff

The image doesn't exist locally. Build it:
```bash
cd /tmp && git clone https://github.com/AviFR-dev/inventory-app.git && cd inventory-app
IMAGE_TAG=$(grep -oP 'tag:\s*"?\K[^"]+' /tmp/inventory-k8s/helm/values.yaml 2>/dev/null || echo "latest")
docker build -f docker/Dockerfile.backend -t avifrdev/inventory-app:${IMAGE_TAG} -t avifrdev/inventory-app:latest .
kubectl patch deployment inventory-backend -n inventory-system \
    -p '{"spec":{"template":{"spec":{"containers":[{"name":"inventory-backend","imagePullPolicy":"IfNotPresent"}]}}}}'
```

---

## What the Deploy Script Does (9 Phases)

| Phase | What | Details |
|-------|------|---------|
| 1 | **Base System** | Locale, Docker, socat, iptables, /dev/kmsg fix |
| 2 | **K3s** | Kubernetes with Docker runtime, kubeconfig setup |
| 3 | **Namespace** | `inventory-system` namespace, ConfigMap, Secret |
| 4 | **Docker Build** | Clones app repo, reads tag from Helm values, builds image locally |
| 5 | **Jenkins** | Docker container with python3, kubectl, trivy, kubeconfig (IP-fixed) |
| 6 | **Trivy** | Vulnerability scanner, pre-downloads DB |
| 7 | **Argo CD** | Install + NodePort exposure, CRD error handled |
| 8 | **Deploy App** | Argo CD Application, imagePullPolicy patch, self-heal disabled |
| 9 | **Port Forwarding** | socat systemd services for :5000 (app) and :9443 (Argo CD) |

---

## Files

| File | Purpose |
|------|---------|
| `deploy-proxmox.sh` | Main deployment script (run on Proxmox host) |
| `Jenkinsfile` | CI/CD pipeline definition (local deploy, no Docker Hub) |

---

*Inventory Management System — DevOps Project — AviFR-dev — 2026*
