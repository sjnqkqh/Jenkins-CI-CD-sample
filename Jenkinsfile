// ========================================
// Jenkins Pipeline for Spring Boot with Kaniko
// CI/CD: Build → Push to Registry → Deploy to K8S
// ========================================

pipeline {
    agent {
        kubernetes {
            yaml '''
apiVersion: v1
kind: Pod
metadata:
  labels:
    jenkins: agent
spec:
  serviceAccountName: jenkins-agent
  containers:
  # Kaniko 컨테이너: Docker 이미지 빌드 & Push
  - name: kaniko
    image: gcr.io/kaniko-project/executor:debug
    imagePullPolicy: Always
    command:
    - /busybox/cat
    tty: true
    volumeMounts:
    - name: docker-config
      mountPath: /kaniko/.docker
  # kubectl 컨테이너: K8S 배포
  - name: kubectl
    image: bitnami/kubectl:latest
    imagePullPolicy: Always
    command:
    - cat
    tty: true
  volumes:
  - name: docker-config
    secret:
      secretName: harbor-registry-secret
      items:
      - key: .dockerconfigjson
        path: config.json
'''
        }
    }

    environment {
        // ========================================
        // 환경 변수 설정
        // ========================================

        // 애플리케이션 정보
        APP_NAME = 'sk077-myfirst-api-server'

        // Harbor Registry 설정 (현재 사용 중)
        HARBOR_REGISTRY = 'amdp-registry.skala-ai.com'
        HARBOR_PROJECT = 'skala25a'

        // Kubernetes 설정
        K8S_NAMESPACE = 'skala-practice'

        // 이미지 태그 생성 (타임스탬프 기반)
        IMAGE_TAG = "${env.BUILD_NUMBER}-${new Date().format('yyyyMMdd-HHmmss')}"

        // 최종 이미지 이름 (Harbor Registry)
        FULL_IMAGE_NAME = "${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${APP_NAME}:${IMAGE_TAG}"
    }

    stages {
        // ========================================
        // Stage 1: Git Clone
        // ========================================
        stage('Checkout') {
            steps {
                echo "=========================================="
                echo "Stage: Git Checkout"
                echo "=========================================="

                checkout scm

                script {
                    // Git 정보 출력
                    sh '''
                        echo "Branch: ${GIT_BRANCH}"
                        echo "Commit: ${GIT_COMMIT}"
                        git log -1 --pretty=format:"%h - %an, %ar : %s"
                    '''
                }
            }
        }

        // ========================================
        // Stage 2: Build & Push Docker Image (Kaniko)
        // ========================================
        stage('Build & Push Image') {
            steps {
                echo "=========================================="
                echo "Stage: Build & Push Docker Image"
                echo "Image: ${FULL_IMAGE_NAME}"
                echo "=========================================="

                container('kaniko') {
                    script {
                        // Kaniko를 사용한 이미지 빌드 & Push
                        sh """
                            /kaniko/executor \
                              --context=\${WORKSPACE} \
                              --dockerfile=\${WORKSPACE}/Dockerfile \
                              --destination=${FULL_IMAGE_NAME} \
                              --cache=true \
                              --cache-ttl=24h \
                              --compressed-caching=false \
                              --cleanup
                        """

                        echo "✅ Image built and pushed successfully: ${FULL_IMAGE_NAME}"
                    }
                }
            }
        }

        // ========================================
        // Stage 3: Update Kubernetes Manifests
        // ========================================
        stage('Update K8S Manifests') {
            steps {
                echo "=========================================="
                echo "Stage: Update Kubernetes Deployment"
                echo "=========================================="

                script {
                    // deployment.yaml 파일에서 이미지 태그 업데이트
                    sh """
                        sed -i 's|image: .*/${APP_NAME}:.*|image: ${FULL_IMAGE_NAME}|g' k8s/deploy.yaml

                        # 업데이트된 매니페스트 확인
                        echo "Updated deployment manifest:"
                        grep "image:" k8s/deploy.yaml
                    """
                }
            }
        }

        // ========================================
        // Stage 4: Deploy to Kubernetes
        // ========================================
        stage('Deploy to K8S') {
            steps {
                echo "=========================================="
                echo "Stage: Deploy to Kubernetes"
                echo "Namespace: ${K8S_NAMESPACE}"
                echo "=========================================="

                container('kubectl') {
                    script {
                        // K8S 매니페스트 적용
                        sh """
                            # RBAC 설정 적용 (최초 1회)
                            kubectl apply -f k8s/jenkins-rbac.yaml

                            # 애플리케이션 배포
                            kubectl apply -f k8s/deploy.yaml -n ${K8S_NAMESPACE}
                            kubectl apply -f k8s/service.yaml -n ${K8S_NAMESPACE}

                            # 배포 상태 확인
                            kubectl rollout status deployment/${APP_NAME} -n ${K8S_NAMESPACE} --timeout=300s

                            # 배포된 Pod 확인
                            echo "\\n=== Deployed Pods ==="
                            kubectl get pods -n ${K8S_NAMESPACE} -l app=${APP_NAME}

                            # Service 확인
                            echo "\\n=== Service Info ==="
                            kubectl get svc -n ${K8S_NAMESPACE} ${APP_NAME}
                        """

                        echo "✅ Deployment completed successfully!"
                    }
                }
            }
        }
    }

    // ========================================
    // Post Actions
    // ========================================
    post {
        success {
            echo """
            ========================================
            ✅ Pipeline completed successfully!
            ========================================
            Application: ${APP_NAME}
            Image: ${FULL_IMAGE_NAME}
            Namespace: ${K8S_NAMESPACE}
            Build Number: ${env.BUILD_NUMBER}
            ========================================
            """
        }
        failure {
            echo """
            ========================================
            ❌ Pipeline failed!
            ========================================
            Check the logs above for details.
            Build Number: ${env.BUILD_NUMBER}
            ========================================
            """
        }
        always {
            // 워크스페이스 정리 (선택적)
            // cleanWs()
            echo "Pipeline execution finished."
        }
    }
}