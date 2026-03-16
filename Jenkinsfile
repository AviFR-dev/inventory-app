pipeline {
    agent any

    environment {
        DOCKER_IMAGE = "avifrdev/inventory-app"
        DOCKER_TAG   = "${BUILD_NUMBER}"
        K8S_REPO     = "https://github.com/AviFR-dev/inventory-k8s.git"
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

        stage('Update K8s Repo') {
            steps {
                echo 'Updating Helm values with new image tag...'
                withCredentials([usernamePassword(
                    credentialsId: 'github-credentials',
                    usernameVariable: 'GIT_USER',
                    passwordVariable: 'GIT_TOKEN'
                )]) {
                    sh """
                        rm -rf /tmp/inventory-k8s
                        git clone https://\${GIT_USER}:\${GIT_TOKEN}@github.com/AviFR-dev/inventory-k8s.git /tmp/inventory-k8s
                        cd /tmp/inventory-k8s
                        git checkout main

                        sed -i 's/tag: .*/tag: "${DOCKER_TAG}"/' helm/values.yaml

                        git config user.email "jenkins@inventory.local"
                        git config user.name "Jenkins CI"
                        git add helm/values.yaml
                        git commit -m "Auto-deploy: update image tag to ${DOCKER_TAG}"
                        git push https://\${GIT_USER}:\${GIT_TOKEN}@github.com/AviFR-dev/inventory-k8s.git main

                        rm -rf /tmp/inventory-k8s
                    """
                }
            }
        }

        stage('Deploy') {
            steps {
                echo 'Deploying via kubectl (immediate) + Argo CD will sync...'
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
            echo "✅ Pipeline completed! Image: ${DOCKER_IMAGE}:${DOCKER_TAG} — K8s repo updated"
        }
        failure {
            echo '❌ Pipeline failed!'
        }
    }
}
