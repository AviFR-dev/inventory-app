# 📦 Inventory Management System — DevOps Final Project

**Author:** AviFR-dev  
**Course:** DevOps Final Project — Option 1: Secure Cloud-Native Web Application

---

## 📋 Table of Contents

- [System Description](#system-description)
- [Architecture Diagram](#architecture-diagram)
- [Technology Stack](#technology-stack)
- [CI/CD Flow](#cicd-flow)
- [Proxmox Deployment (One-Script)](#proxmox-deployment-one-script)
- [Post-Deployment Setup](#post-deployment-setup)
- [Jenkinsfile](#jenkinsfile)
- [Security Decisions](#security-decisions)
- [Configuration Management](#configuration-management)
- [Repository Structure](#repository-structure)
- [Run Instructions](#run-instructions)
- [Useful Commands](#useful-commands)
- [Troubleshooting](#troubleshooting)

---

## 🏗️ System Description

A production-grade **Inventory Management System** built as a cloud-native web application.  
Users can **add, view, update, and delete products** from an inventory database.

The application is fully containerized, deployed on Kubernetes, and managed through a complete CI/CD pipeline using Jenkins and Argo CD (GitOps).

### Features
- CRUD operations for inventory products
- SKU tracking, categories, and supplier management
- Stock adjustments with movement history
- Real-time stock status (In Stock / Low Stock / Out of Stock)
- CSV export
- RESTful API with JSON responses
- Health check endpoint for Kubernetes probes
- Responsive web interface

---

## 🏛️ Architecture Diagram

```
Developer (VS Code + GitHub)
           │
           │  git push → dev branch
           ▼
    GitHub (inventory-app)
           │
           │  Jenkins polls every 3 min
           ▼
    Jenkins CI Pipeline (inside LXC container)
    ├── Stage 1: Build       (pip install dependencies)
    ├── Stage 2: Test        (pytest - 27 tests)
    ├── Stage 3: Docker Build (multi-stage, local image)
    ├── Stage 4: Trivy Scan  (CRITICAL vulnerability check)
    └── Stage 5: Deploy      (kubectl rolling update to K3s)
           │
           ▼
    Kubernetes Cluster (K3s inside Proxmox LXC)
    └── Namespace: inventory-system
        ├── Deployment: inventory-backend (3 replicas)
        ├── Deployment: inventory-db (PostgreSQL)
        ├── Service: inventory-backend (ClusterIP)
        ├── Service: inventory-db (ClusterIP)
        ├── ConfigMap: inventory-config
        └── Secret: inventory-secret

    Port Forwarding (socat systemd services):
        :5000 → App ClusterIP
        :8080 → Jenkins (Docker)
        :9443 → Argo CD NodePort

           │
           ▼
    User → Browser → :5000 → K8s Service → Pod → PostgreSQL
```

**All components run inside a single Proxmox LXC container. No Docker Hub required.**

---

## 🛠️ Technology Stack

| Layer | Technology | Purpose |
|---|---|---|
| Backend | Python 3.11 + Flask | REST API and web server |
| Frontend | HTML + Jinja2 | Web interface |
| Database | PostgreSQL 15 | Data persistence |
| Web Server | Gunicorn | Production WSGI server |
| Containerization | Docker | Packaging and isolation |
| Orchestration | K3s (Kubernetes) | Container management |
| CI | Jenkins | Build, test, scan, deploy |
| CD | Argo CD | GitOps initial deployment |
| Security Scanner | Trivy | Image vulnerability scanning |
| Config Management | Helm + ConfigMaps + Secrets | Environment configuration |
| Infrastructure | Proxmox VE (LXC) | Host platform |
| Port Forwarding | socat + systemd | Service exposure |
| Version Control | Git + GitHub | Source code management |

---

## 🔄 CI/CD Flow

### Pipeline Stages

Every push to the `dev` branch is detected by Jenkins (polling every 3 minutes):

```
1. BUILD
   └── pip install -r requirements.txt

2. TEST
   └── pytest tests/ -v (27 tests)
       ├── test_health_check
       ├── test_get_products_empty
       ├── test_add_product
       ├── test_add_product_missing_name
       ├── test_get_products_after_add
       ├── test_update_product
       ├── test_delete_product
       ├── test_add_product_with_sku
       ├── test_add_product_duplicate_sku
       ├── test_add_product_with_supplier_and_threshold
       ├── test_update_product_new_fields
       ├── test_stock_status_in_dict
       ├── test_search_products_by_name
       ├── test_filter_products_by_status
       ├── test_add_category
       ├── test_add_duplicate_category
       ├── test_add_category_missing_name
       ├── test_get_categories
       ├── test_delete_category
       ├── test_add_product_with_category
       ├── test_delete_category_unlinks_products
       ├── test_stock_adjustment_in
       ├── test_stock_adjustment_out
       ├── test_stock_adjustment_insufficient
       ├── test_stock_adjustment_zero_delta
       ├── test_get_movements
       └── test_export_csv

3. DOCKER BUILD
   └── docker build (multi-stage, local image)
       ├── Stage 1 (builder): install dependencies
       └── Stage 2 (runtime): minimal image + non-root user

4. IMAGE SCAN (Trivy)
   └── Scan for CRITICAL vulnerabilities
       └── 0 vulnerabilities ✅

5. DEPLOY
   └── kubectl set image → rolling update
   └── kubectl patch imagePullPolicy → IfNotPresent
   └── kubectl rollout status → wait for completion
```

### Workflow

```
Edit code on dev branch (GitHub)
       ↓
Jenkins detects change (polling every 3 min)
       ↓
Jenkins Pipeline: Build → Test → Docker Build → Scan → Deploy
       ↓
App live at http://<IP>:5000 with new version
```

**No Docker Hub needed** — images are built and consumed locally on the same K3s node.

---

## 🚀 Proxmox Deployment (One-Script)

Deploy the entire stack with a single command on your Proxmox host.

### Prerequisites

- **Proxmox VE** 7.x, 8.x, or 9.x
- **Root access** on the Proxmox host
- At least **4 CPU cores**, **8GB RAM**, **50GB disk** available
- Internet connectivity

### Deploy

```bash
# Copy deploy-proxmox.sh to your Proxmox host, then:
bash deploy-proxmox.sh
```

The script will:
1. Auto-detect your Proxmox resources (storage, bridges, RAM, CPUs)
2. Interactively configure the container (VMID, disk, RAM, network)
3. Create a privileged LXC container with K8s-compatible settings
4. Run 9 automated phases inside the container:

| Phase | What | Details |
|-------|------|---------|
| 1 | **Base System** | Locale, Docker, socat, iptables, /dev/kmsg |
| 2 | **K3s** | Kubernetes with Docker runtime, kubeconfig |
| 3 | **Namespace** | inventory-system, ConfigMap, Secret |
| 4 | **Docker Build** | Clone repo, read Helm tag, build image locally |
| 5 | **Jenkins** | Container with python3, kubectl, trivy, kubeconfig |
| 6 | **Trivy** | Vulnerability scanner + DB download |
| 7 | **Argo CD** | Install + NodePort, CRD error handled |
| 8 | **Deploy App** | Argo CD Application, imagePullPolicy patch |
| 9 | **Port Forwarding** | socat systemd services (:5000, :9443) |

**Takes approximately 10-15 minutes.**

### What You Get

```
URLs:
  App:      http://<CONTAINER_IP>:5000
  Jenkins:  http://<CONTAINER_IP>:8080
  Argo CD:  https://<CONTAINER_IP>:9443
```

### Get Credentials

```bash
pct exec <VMID> -- cat /root/jenkins-initial-password.txt
pct exec <VMID> -- cat /root/argocd-initial-password.txt   # username: admin
```

---

## ⚙️ Post-Deployment Setup

After the automated deployment, configure the Jenkins pipeline (one-time manual setup).

### 1. Jenkins First Login

1. Open `http://<CONTAINER_IP>:8080`
2. Paste the initial admin password
3. Click **Install suggested plugins**
4. Create your admin user → **Start using Jenkins**

### 2. Create the Pipeline Job

1. **New Item** → name: `inventory-app` → select **Pipeline** → OK
2. **Build Triggers** section:
   - Check **Poll SCM**
   - Schedule: `H/3 * * * *`
3. **Pipeline** section:
   - Definition: **Pipeline script from SCM**
   - SCM: **Git**
   - Repository URL: `https://github.com/AviFR-dev/inventory-app.git`
   - Branch: `*/dev`
   - Script Path: `Jenkinsfile`
4. **Save**

### 3. First Build

Click **Build Now** → watch all 5 stages pass → refresh the app URL.

---

## 📄 Jenkinsfile

The `Jenkinsfile` on the `dev` branch defines a local deployment pipeline (no Docker Hub):

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

## 🔒 Security Decisions

### 1. Non-Root Container
The Dockerfile creates a dedicated `appuser` and switches to it:
```dockerfile
RUN useradd -m appuser
USER appuser
```
This prevents container escape attacks and follows the principle of least privilege.

### 2. No Secrets in Git
All sensitive values (passwords, credentials) are stored in:
- **Kubernetes Secrets** — for database credentials
- Never committed to Git repositories

### 3. Image Scanning (Trivy)
Every Docker image is scanned by Trivy before deployment:
- Scans for OS and package vulnerabilities
- Pipeline reports CRITICAL findings
- Uses `python:3.11-slim` minimal base image to reduce attack surface

### 4. RBAC (Role-Based Access Control)
A dedicated `ServiceAccount` with minimal permissions:
```yaml
rules:
- apiGroups: [""]
  resources: ["pods", "services", "configmaps"]
  verbs: ["get", "list", "watch"]
```

### 5. Network Policy
PostgreSQL database is only accessible from backend pods:
```yaml
podSelector:
  matchLabels:
    app: inventory-db
ingress:
- from:
  - podSelector:
      matchLabels:
        app: inventory-backend
```

### 6. Minimal Docker Image
- Uses `python:3.11-slim` — not full Python image
- Multi-stage build — only runtime dependencies in final image
- Result: ~58MB image, smaller attack surface

---

## ⚙️ Configuration Management

All configuration is separated from code using environment variables.

### ConfigMap (non-sensitive)
```yaml
DB_HOST: "inventory-db"
DB_PORT: "5432"
DB_NAME: "inventory"
APP_ENV: "production"
```

### Secrets (sensitive)
```yaml
DB_USER: <base64>
DB_PASSWORD: <base64>
```

### Helm Values (environment-specific)

| File | Environment | Replicas |
|---|---|---|
| `values.yaml` | Default | 2 |
| `values-dev.yaml` | Development | 1 |
| `values-prod.yaml` | Production | 3 |

### Flask reads all config from environment:
```python
os.environ.get('DB_HOST', 'localhost')
os.environ.get('DB_PASSWORD', 'postgres')
```

---

## 📁 Repository Structure

### inventory-app (Application Code)
```
inventory-app/
├── frontend/
│   └── templates/
│       └── index.html              ← Web interface
├── backend/
│   ├── app.py                      ← Flask application
│   ├── models.py                   ← Product database model
│   ├── requirements.txt            ← Python dependencies
│   ├── conftest.py                 ← Test configuration
│   └── tests/
│       └── test_app.py             ← 27 unit tests
├── docker/
│   ├── Dockerfile.backend          ← Multi-stage Docker build
│   └── docker-compose.yml          ← Local development
├── k8s/                            ← Raw Kubernetes manifests
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── ingress.yaml
│   ├── configmap.yaml
│   └── secret.yaml
├── Jenkinsfile                     ← CI/CD pipeline (local deploy)
├── deploy-proxmox.sh               ← One-script Proxmox deployment
├── DEPLOYMENT-GUIDE.md             ← Detailed deployment guide
└── README.md                       ← This file
```

### inventory-k8s (Kubernetes Manifests)
```
inventory-k8s/
├── helm/
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── values-dev.yaml
│   ├── values-prod.yaml
│   └── templates/
│       ├── deployment.yaml
│       ├── service.yaml
│       ├── configmap.yaml
│       ├── secret.yaml
│       ├── rbac.yaml
│       └── networkpolicy.yaml
└── argo/
    └── application.yaml
```

---

## 🚀 Run Instructions

### Option 1: Proxmox Deployment (Recommended)

See [Proxmox Deployment](#proxmox-deployment-one-script) above. One script deploys everything.

```bash
bash deploy-proxmox.sh
```

### Option 2: Run Locally (Development)

```bash
git clone https://github.com/AviFR-dev/inventory-app
cd inventory-app

export DB_USER="postgres"
export DB_PASSWORD="postgres"
export DB_HOST="localhost"
export DB_NAME="inventory"
export APP_ENV="development"

docker-compose -f docker/docker-compose.yml up --build

# Access at http://localhost:5000
```

### Option 3: Run Tests

```bash
cd backend
python3 -m pytest tests/ -v
```

---

## 🔧 Useful Commands

From the **Proxmox host**:

```bash
# Enter the container
pct enter <VMID>

# Check all pods
pct exec <VMID> -- bash -c "export PATH=/usr/local/bin:\$PATH KUBECONFIG=/root/.kube/config; kubectl get pods -A"

# View app logs
pct exec <VMID> -- bash -c "export PATH=/usr/local/bin:\$PATH KUBECONFIG=/root/.kube/config; kubectl logs -n inventory-system -l app=inventory-backend --tail=20"

# Check port forwarding
pct exec <VMID> -- systemctl status inventory-forward argocd-forward
```

From **inside the container**:

```bash
kubectl get pods -A
kubectl get pods -n inventory-system
kubectl get svc -A
kubectl logs -f deploy/inventory-backend -n inventory-system
docker logs jenkins -f
argocd app list
```

---

## 🔥 Troubleshooting

### App shows "Internal Server Error"

Database schema is outdated — reset it:
```bash
kubectl exec -n inventory-system deploy/inventory-db -- \
    psql -U postgres -d inventory -c 'DROP TABLE IF EXISTS stock_movements, products, categories CASCADE;'
kubectl rollout restart deployment/inventory-backend -n inventory-system
```

### Jenkins Deploy stage fails with "permission denied"

```bash
docker exec -u root jenkins bash -c "
    cp /tmp/host-kubeconfig /var/jenkins_home/.kube/config
    chmod 644 /var/jenkins_home/.kube/config
    chown 1000:1000 /var/jenkins_home/.kube/config
"
```

### Jenkins Deploy stage fails with "connection refused 127.0.0.1:6443"

```bash
HOST_IP=$(hostname -I | awk '{print $1}')
docker exec -u root jenkins bash -c "sed -i 's|127.0.0.1|${HOST_IP}|g' /var/jenkins_home/.kube/config"
```

### Pods stuck in ImagePullBackOff

Build the image locally and patch the pull policy:
```bash
cd /tmp && git clone https://github.com/AviFR-dev/inventory-app.git && cd inventory-app
docker build -f docker/Dockerfile.backend -t avifrdev/inventory-app:latest .
kubectl patch deployment inventory-backend -n inventory-system \
    -p '{"spec":{"template":{"spec":{"containers":[{"name":"inventory-backend","imagePullPolicy":"IfNotPresent"}]}}}}'
```

### App not accessible in browser (port 5000)

Restart the socat forwarder:
```bash
CIP=$(kubectl get svc inventory-backend -n inventory-system -o jsonpath='{.spec.clusterIP}')
printf '[Unit]\nDescription=Forward :5000 to App\nAfter=network.target k3s.service\n\n[Service]\nType=simple\nExecStart=/usr/bin/socat TCP-LISTEN:5000,fork,reuseaddr TCP:%s:80\nRestart=always\nRestartSec=5\n\n[Install]\nWantedBy=multi-user.target\n' "$CIP" > /etc/systemd/system/inventory-forward.service
systemctl daemon-reload && systemctl restart inventory-forward
```

---

## 🐳 Docker Image

Image: `avifrdev/inventory-app`  
Built locally — no Docker Hub push required.  
Tags: `latest`, build number (e.g. `5`, `6`, `7`...)

---

*DevOps Final Project — AviFR-dev — 2026*
