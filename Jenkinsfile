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
