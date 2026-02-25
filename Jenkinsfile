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
                sh """
                    docker run --rm \
                    -v /var/run/docker.sock:/var/run/docker.sock \
                    aquasec/trivy:latest image \
                    --exit-code 1 \
                    --severity CRITICAL \
                    ${DOCKER_IMAGE}:${DOCKER_TAG}
                """
            }
        }

        stage('Push') {
            steps {
                echo 'Pushing to Docker Hub...'
                withCredentials([usernamePassword(
                    credentialsId: 'dockerhub-credentials',
                    usernameVariable: 'DOCKER_USER',
                    passwordVariable: 'DOCKER_PASS'
                )]) {
                    sh "echo $DOCKER_PASS | docker login -u $DOCKER_USER --password-stdin"
                    sh "docker push ${DOCKER_IMAGE}:${DOCKER_TAG}"
                    sh "docker push ${DOCKER_IMAGE}:latest"
                }
            }
        }
    }
stage('Update Helm Values') {
    steps {
        echo 'Updating Helm values with new image tag...'
        sh """
            git clone https://github.com/AviFR-dev/inventory-k8s.git
            cd inventory-k8s
            git checkout dev
            sed -i 's/tag: .*/tag: "${DOCKER_TAG}"/' helm/values.yaml
            git config user.email "jenkins@inventory.com"
            git config user.name "Jenkins"
            git add helm/values.yaml
            git commit -m "Auto-deploy: update image tag to ${DOCKER_TAG}"
            git push https://github.com/AviFR-dev/inventory-k8s.git dev
        """
    }
}
    post {
        success {
            echo '✅ Pipeline completed successfully!'
        }
        failure {
            echo '❌ Pipeline failed!'
        }
        always {
            sh "docker logout"
        }
    }
}