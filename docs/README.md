# 📦 Inventory Management System — DevOps Final Project

**Author:** AviFR-dev  
**Course:** DevOps Final Project — Option 1: Secure Cloud-Native Web Application

---

## 📋 Table of Contents

- [System Description](#system-description)
- [Architecture Diagram](#architecture-diagram)
- [Technology Stack](#technology-stack)
- [CI/CD Flow](#cicd-flow)
- [Security Decisions](#security-decisions)
- [Configuration Management](#configuration-management)
- [Repository Structure](#repository-structure)
- [Run Instructions](#run-instructions)

---

## 🏗️ System Description

A production-grade **Inventory Management System** built as a cloud-native web application.  
Users can **add, view, update, and delete products** from an inventory database.

The application is fully containerized, deployed on Kubernetes, and managed through a complete CI/CD pipeline using Jenkins and Argo CD (GitOps).

### Features
- CRUD operations for inventory products
- Real-time stock status (In Stock / Low Stock / Out of Stock)
- RESTful API with JSON responses
- Health check endpoint for Kubernetes probes
- Responsive web interface

---

## 🏛️ Architecture Diagram

```
Developer (VS Code + GitHub Desktop)
           │
           │  git push → dev branch
           ▼
    GitHub (inventory-app)
           │
           │  Webhook trigger
           ▼
    Jenkins CI Pipeline
    ├── Stage 1: Build       (pip install dependencies)
    ├── Stage 2: Test        (pytest - 7 tests)
    ├── Stage 3: Docker Build (multi-stage build)
    ├── Stage 4: Trivy Scan  (CRITICAL vulnerability check)
    └── Stage 5: Push        (Docker Hub → avifrdev/inventory-app)
           │
           │  Update image tag in values.yaml
           ▼
    GitHub (inventory-k8s)
           │
           │  Argo CD detects change (Auto-sync)
           ▼
    Kubernetes Cluster (Minikube / EKS)
    └── Namespace: inventory-system
        ├── Deployment: inventory-backend (2 replicas)
        ├── Deployment: inventory-db (PostgreSQL)
        ├── Service: inventory-backend (ClusterIP)
        ├── Service: inventory-db (ClusterIP)
        ├── Ingress: inventory-ingress
        ├── ConfigMap: inventory-config
        ├── Secret: inventory-secret
        ├── ServiceAccount: inventory-sa (RBAC)
        └── NetworkPolicy: DB access restricted
           │
           ▼
    User → Browser → Ingress → Service → Pod → PostgreSQL
```

---

## 🛠️ Technology Stack

| Layer | Technology | Purpose |
|---|---|---|
| Backend | Python 3.11 + Flask | REST API and web server |
| Frontend | HTML + Jinja2 | Web interface |
| Database | PostgreSQL 15 | Data persistence |
| Web Server | Gunicorn | Production WSGI server |
| Containerization | Docker | Packaging and isolation |
| Orchestration | Kubernetes (Minikube/EKS) | Container management |
| CI | Jenkins | Build, test, scan, push |
| CD | Argo CD | GitOps deployment |
| Image Registry | Docker Hub | Store Docker images |
| Security Scanner | Trivy | Image vulnerability scanning |
| Config Management | Helm + ConfigMaps + Secrets | Environment configuration |
| Version Control | Git + GitHub | Source code management |

---

## 🔄 CI/CD Flow

### Continuous Integration (Jenkins)

Every push to the `dev` branch triggers the Jenkins pipeline:

```
1. BUILD
   └── pip install -r requirements.txt

2. TEST
   └── pytest tests/ -v (7 tests)
       ├── test_health_check
       ├── test_get_products_empty
       ├── test_add_product
       ├── test_add_product_missing_name
       ├── test_get_products_after_add
       ├── test_update_product
       └── test_delete_product

3. DOCKER BUILD
   └── docker build (multi-stage)
       ├── Stage 1 (builder): install dependencies
       └── Stage 2 (runtime): minimal image + non-root user

4. IMAGE SCAN (Trivy)
   └── Scan for CRITICAL vulnerabilities
       └── Pipeline FAILS if CRITICAL found ❌
       └── Pipeline PASSES if clean ✅

5. PUSH
   └── docker push avifrdev/inventory-app:${BUILD_NUMBER}
   └── docker push avifrdev/inventory-app:latest
```

### Continuous Deployment (Argo CD — GitOps)

```
1. Jenkins updates image tag in inventory-k8s/helm/values.yaml
2. Pushes to GitHub (inventory-k8s repo)
3. Argo CD detects the change automatically
4. Argo CD syncs the Helm chart to Kubernetes
5. Kubernetes rolling update (zero downtime)
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
- **Jenkins Credentials Store** — for Docker Hub credentials
- **Kubernetes Secrets** — for database credentials
- Never committed to Git repositories

### 3. Image Scanning (Trivy)
Every Docker image is scanned by Trivy before being pushed:
- Scans for OS and package vulnerabilities
- Pipeline **fails automatically** on CRITICAL findings
- Uses `python:3.11-slim` minimal base image to reduce attack surface

### 4. RBAC (Role-Based Access Control)
A dedicated `ServiceAccount` with minimal permissions:
```yaml
rules:
- apiGroups: [""]
  resources: ["pods", "services", "configmaps"]
  verbs: ["get", "list", "watch"]
```
The app can only READ Kubernetes resources — not modify them.

### 5. Network Policy (Bonus)
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
- Result: smaller attack surface, faster pulls

---

## ⚙️ Configuration Management

All configuration is separated from code using environment variables.

### ConfigMap (non-sensitive)
```yaml
DB_HOST: inventory-db
DB_PORT: "5432"
DB_NAME: inventory
APP_ENV: production
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
**No hardcoded values anywhere in the codebase.**

---

## 📁 Repository Structure

### inventory-app (Application Code)
```
inventory-app/
├── frontend/
│   └── templates/
│       └── index.html          ← Web interface
├── backend/
│   ├── app.py                  ← Flask application
│   ├── models.py               ← Product database model
│   ├── requirements.txt        ← Python dependencies
│   ├── conftest.py             ← Test configuration
│   └── tests/
│       └── test_app.py         ← 7 unit tests
├── docker/
│   ├── Dockerfile.backend      ← Multi-stage Docker build
│   └── docker-compose.yml      ← Local development
├── k8s/                        ← Raw Kubernetes manifests
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── ingress.yaml
│   ├── configmap.yaml
│   └── secret.yaml
├── Jenkinsfile                 ← CI pipeline
└── docs/
    └── README.md               ← This file
```

### inventory-k8s (Kubernetes Manifests)
```
inventory-k8s/
├── helm/
│   ├── Chart.yaml
│   ├── values.yaml             ← Default values
│   ├── values-dev.yaml         ← Development environment
│   ├── values-prod.yaml        ← Production environment
│   └── templates/
│       ├── deployment.yaml
│       ├── service.yaml
│       ├── configmap.yaml
│       ├── secret.yaml
│       ├── rbac.yaml
│       └── networkpolicy.yaml
└── argo/
    └── application.yaml        ← Argo CD application
```

---

## 🚀 Run Instructions

### Prerequisites
- Docker Desktop
- Minikube
- kubectl
- Python 3.11+
- Jenkins (running in Docker)

### 1. Run Locally (Development)

```bash
# Clone the repo
git clone https://github.com/AviFR-dev/inventory-app
cd inventory-app

# Set environment variables
$env:DB_USER="postgres"
$env:DB_PASSWORD="postgres"
$env:DB_HOST="localhost"
$env:DB_NAME="inventory"
$env:APP_ENV="development"

# Run with Docker Compose
docker-compose -f docker/docker-compose.yml up --build

# Access at:
# http://localhost:5000
```

### 2. Run Tests

```bash
cd backend
py -m pytest tests/ -v
```

### 3. Deploy to Kubernetes (Minikube)

```bash
# Start Minikube
minikube start --driver=docker

# Create namespace
kubectl create namespace inventory-system

# Apply manifests
kubectl apply -f k8s/ -n inventory-system

# Access the app
minikube service inventory-backend -n inventory-system
```

### 4. Deploy with Helm + Argo CD (GitOps)

```bash
# Install Argo CD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Apply Argo CD application
kubectl apply -f argo/application.yaml

# Argo CD will automatically sync from GitHub
# Any push to inventory-k8s triggers auto-deployment
```

### 5. Jenkins CI Pipeline

1. Open Jenkins at `http://localhost:8080`
2. Go to `inventory-app` pipeline
3. Click **Build Now**
4. Pipeline runs: Build → Test → Docker Build → Trivy Scan → Push

---

## 🐳 Docker Hub

Image: `avifrdev/inventory-app`  
Tags: `latest`, build number (e.g. `6`, `7`, `8`...)

---

*DevOps Final Project — AviFR-dev — 2026*