# Inventory App — Full Pipeline Setup on Proxmox

Complete guide to deploying [AviFR-dev/inventory-app](https://github.com/AviFR-dev/inventory-app) on a Proxmox home lab with Kubernetes, Jenkins CI, and Argo CD GitOps.

---

## VM Requirements

Create an Ubuntu 22.04/24.04 VM in Proxmox with:

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| CPU      | 4 cores | 6 cores     |
| RAM      | 8 GB    | 12 GB       |
| Disk     | 40 GB   | 60 GB       |

> The full stack (K3s + Jenkins + Argo CD + app) is memory-hungry. 8 GB is tight but workable.

---

## Phase 1 — Base System Setup

SSH into your Ubuntu VM and run:

```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Install essentials
sudo apt install -y curl wget git apt-transport-https ca-certificates gnupg lsb-release

# Install Docker
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
newgrp docker

# Verify
docker --version
```

---

## Phase 2 — Install K3s (Lightweight Kubernetes)

K3s is ideal for a home lab — it's a full Kubernetes distro in a single binary with low resource overhead.

```bash
# Install K3s
curl -sfL https://get.k3s.io | sh -

# Wait for it to be ready
sudo k3s kubectl get nodes

# Set up kubectl for your user
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $USER:$USER ~/.kube/config
export KUBECONFIG=~/.kube/config

# Add to .bashrc so it persists
echo 'export KUBECONFIG=~/.kube/config' >> ~/.bashrc

# Install kubectl alias (optional but handy)
echo 'alias k=kubectl' >> ~/.bashrc
source ~/.bashrc

# Verify cluster is running
kubectl get nodes
kubectl get pods -A
```

You should see your node in `Ready` state and system pods running.

---

## Phase 3 — Create the App Namespace

```bash
kubectl create namespace inventory-system
```

---

## Phase 4 — Install Jenkins

We'll run Jenkins in Docker on the same VM. It needs access to Docker (for building images) and kubectl (for interacting with the cluster).

```bash
# Create a Docker network for Jenkins
docker network create jenkins

# Run Jenkins with Docker socket mounted
docker run -d \
  --name jenkins \
  --restart=unless-stopped \
  --network jenkins \
  -p 8080:8080 \
  -p 50000:50000 \
  -v jenkins_home:/var/jenkins_home \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v $(which docker):/usr/bin/docker \
  -v ~/.kube/config:/var/jenkins_home/.kube/config \
  jenkins/jenkins:lts

# Get the initial admin password
docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword
```

### Configure Jenkins

1. Open `http://<YOUR-VM-IP>:8080` in your browser
2. Paste the initial admin password
3. Install **suggested plugins**
4. Create your admin user

### Install Required Jenkins Plugins

Go to **Manage Jenkins → Plugins → Available** and install:

- Docker Pipeline
- Pipeline
- Git
- Credentials Binding

### Add Docker Hub Credentials

1. Go to **Manage Jenkins → Credentials → System → Global credentials**
2. Click **Add Credentials**
3. Kind: **Username with password**
4. Username: your Docker Hub username
5. Password: your Docker Hub password/token
6. ID: `docker-hub-creds`

### Fix Docker Permissions Inside Jenkins

```bash
# Jenkins needs to run Docker commands
docker exec -u root jenkins bash -c "groupadd -f docker && usermod -aG docker jenkins"
docker restart jenkins
```

### Create the Pipeline

1. **New Item → Pipeline** → name it `inventory-app`
2. Under **Pipeline**, select **Pipeline script from SCM**
3. SCM: **Git**
4. Repository URL: `https://github.com/AviFR-dev/inventory-app.git`
5. Branch: `*/dev` (the CI triggers on dev branch pushes)
6. Script Path: `Jenkinsfile`
7. Save

---

## Phase 5 — Install Trivy (Image Scanner)

The Jenkins pipeline uses Trivy to scan Docker images. Install it on the VM so Jenkins can access it:

```bash
# Install Trivy
sudo apt-get install -y wget apt-transport-https gnupg
wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key | sudo gpg --dearmor -o /usr/share/keyrings/trivy.gpg
echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb generic main" | sudo tee /etc/apt/sources.list.d/trivy.list
sudo apt-get update
sudo apt-get install -y trivy

# Pre-download the vulnerability database
trivy image --download-db-only
```

> **Note:** If the Jenkinsfile calls `trivy` directly, you may need to mount it into the Jenkins container or install it inside Jenkins. Alternatively, modify the pipeline to use a Trivy Docker container.

---

## Phase 6 — Install Argo CD

```bash
# Create Argo CD namespace and install
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for pods to be ready
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=300s

# Expose Argo CD UI via NodePort (home lab friendly)
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "NodePort"}}'

# Get the port
kubectl get svc argocd-server -n argocd

# Get the initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo
```

Access Argo CD at `https://<YOUR-VM-IP>:<NODE-PORT>` (accept the self-signed cert warning).

Login: `admin` / the password from the command above.

### Install Argo CD CLI (Optional)

```bash
curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x argocd
sudo mv argocd /usr/local/bin/

# Login
argocd login <YOUR-VM-IP>:<NODE-PORT> --username admin --password <PASSWORD> --insecure
```

---

## Phase 7 — Clone the GitOps Repo

Your K8s manifests repo is already set up at [AviFR-dev/inventory-k8s](https://github.com/AviFR-dev/inventory-k8s) with the correct structure:

```
inventory-k8s/
├── argo/          ← Argo CD application definition
│   └── application.yaml
└── helm/          ← Helm chart (templates, values, etc.)
    ├── Chart.yaml
    ├── values.yaml
    ├── values-dev.yaml
    ├── values-prod.yaml
    └── templates/
```

Clone it to your VM:

```bash
git clone https://github.com/AviFR-dev/inventory-k8s.git
cd inventory-k8s
```

> **Tip:** If you need to customize values for your home lab (e.g., different replica count, resource limits), edit `helm/values.yaml` and push. Argo CD will pick up the change automatically.

---

## Phase 8 — Configure Argo CD Application

Create the Argo CD application that watches your K8s repo. You can either apply the one already in the repo, or create it manually:

### Option A: Use the Existing Application YAML

```bash
cd inventory-k8s
kubectl apply -f argo/application.yaml
```

### Option B: Create Manually (if you need to customize)

```yaml
# argo-application.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: inventory-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/AviFR-dev/inventory-k8s.git
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
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

```bash
kubectl apply -f argo-application.yaml
```

---

## Phase 9 — Access the App

```bash
# Check pods are running
kubectl get pods -n inventory-system

# Option 1: Port forward (quickest)
kubectl port-forward svc/inventory-backend 5000:5000 -n inventory-system --address=0.0.0.0

# Option 2: NodePort service
kubectl patch svc inventory-backend -n inventory-system -p '{"spec": {"type": "NodePort"}}'
kubectl get svc -n inventory-system
```

Open `http://<YOUR-VM-IP>:5000` (or the NodePort) in your browser.

---

## Phase 10 — Set Up Webhook (Optional)

To trigger Jenkins automatically on `git push`:

1. In your GitHub repo, go to **Settings → Webhooks → Add webhook**
2. Payload URL: `http://<YOUR-PUBLIC-IP>:8080/github-webhook/`
3. Content type: `application/json`
4. Events: **Just the push event**

> **Home lab note:** Your Proxmox VM is likely behind NAT. You'll need to either port-forward 8080 on your router, or use a tunnel like Cloudflare Tunnel or ngrok to expose Jenkins to GitHub.

---

## Quick Reference — Full Pipeline Flow

```
You push to dev branch
        ↓
GitHub webhook → Jenkins
        ↓
Jenkins Pipeline:
  1. pip install dependencies
  2. pytest (7 tests)
  3. docker build (multi-stage)
  4. trivy scan (fail on CRITICAL)
  5. docker push to Docker Hub
  6. update image tag in inventory-k8s repo
        ↓
Argo CD detects change in inventory-k8s
        ↓
Argo CD syncs Helm chart → K3s cluster
        ↓
Rolling update → zero downtime
        ↓
App live at http://<VM-IP>:<PORT>
```

---

## Troubleshooting

**Jenkins can't run Docker commands:**
```bash
docker exec -u root jenkins bash -c "chmod 666 /var/run/docker.sock"
```

**K3s not starting:**
```bash
sudo systemctl status k3s
sudo journalctl -u k3s -f
```

**Argo CD sync failing:**
```bash
kubectl logs -n argocd deployment/argocd-application-controller
argocd app get inventory-app
```

**Pods stuck in CrashLoopBackOff:**
```bash
kubectl logs <pod-name> -n inventory-system
kubectl describe pod <pod-name> -n inventory-system
```

**Database connection issues:**
```bash
# Check if PostgreSQL pod is running
kubectl get pods -n inventory-system -l app=inventory-db

# Check secrets are created
kubectl get secrets -n inventory-system
```

---

## Environment Variables Reference

These are the env vars the app expects (set via ConfigMap/Secrets):

| Variable      | Default     | Source    |
|---------------|-------------|-----------|
| `DB_HOST`     | `localhost` | ConfigMap |
| `DB_PORT`     | `5432`      | ConfigMap |
| `DB_NAME`     | `inventory` | ConfigMap |
| `DB_USER`     | `postgres`  | Secret    |
| `DB_PASSWORD` | `postgres`  | Secret    |
| `APP_ENV`     | —           | ConfigMap |
