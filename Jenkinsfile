pipeline {
  agent any
  tools { maven 'maven-3.9' }
  environment {
    // === Git 설정 ===
    GIT_URL     = 'https://github.com/sjnqkqh/Jenkins-CI-CD-sample'
    GIT_BRANCH  = 'main'
    GIT_ID      = 'github-pat-credential'  // GitHub PAT Credential ID

    // === 이미지 설정 ===
    IMAGE_NAME  = 'sk077-myfirst-api-server'
    IMAGE_TAG   = '1.0.0'
    IMAGE_REGISTRY_URL = 'amdp-registry.skala-ai.com'
    IMAGE_REGISTRY_PROJECT = 'skala25a'
    IMAGE_REGISTRY = "${IMAGE_REGISTRY_URL}/${IMAGE_REGISTRY_PROJECT}"

    // === Kubernetes 설정 ===
    K8S_NAMESPACE = 'skala-practice'
  }

  options {
    disableConcurrentBuilds()  // 동시 빌드 방지
    timestamps()               // 로그에 타임스탬프 추가
  }

  stages {
    stage('Clone Repository') {
      steps {
        echo 'Clone Repository'
        git branch: "${GIT_BRANCH}",
            url: "${GIT_URL}",
            credentialsId: "${GIT_ID}"
      }
    }

    stage('Build with Maven') {
      steps {
        echo 'Build with Maven'
        sh 'mvn -v'
        sh 'mvn clean package -DskipTests'
        sh 'ls -al target/'
      }
    }

    stage('Compute Image Tag') {
      steps {
        script {
          // 타임스탬프 기반 고유 태그 생성
          def timestamp = sh(
            script: "date +%Y%m%d-%H%M%S",
            returnStdout: true
          ).trim()

          env.FINAL_IMAGE_TAG = "${IMAGE_TAG}-${timestamp}"
          env.IMAGE_REF = "${IMAGE_REGISTRY}/${IMAGE_NAME}:${FINAL_IMAGE_TAG}"

          echo "=========================================="
          echo "Image Reference: ${IMAGE_REF}"
          echo "=========================================="
        }
      }
    }

    stage('Build & Push with Kaniko') {
      steps {
        script {
          def kanikoYaml = """
apiVersion: v1
kind: Pod
metadata:
  name: kaniko
spec:
  serviceAccountName: jenkins-agent
  containers:
  - name: kaniko
    image: gcr.io/kaniko-project/executor:v1.23.0-debug
    imagePullPolicy: Always
    command:
    - /busybox/cat
    tty: true
    volumeMounts:
    - name: docker-config
      mountPath: /kaniko/.docker
  volumes:
  - name: docker-config
    secret:
      secretName: harbor-registry-secret
      items:
      - key: .dockerconfigjson
        path: config.json
"""

          podTemplate(yaml: kanikoYaml) {
            node(POD_LABEL) {
              // Git 소스 체크아웃
              checkout scm

              container('kaniko') {
                sh """
                  /kaniko/executor \\
                    --context=\$(pwd) \\
                    --dockerfile=Dockerfile \\
                    --destination=${IMAGE_REF} \\
                    --cache=true \\
                    --cache-repo=${IMAGE_REGISTRY}/${IMAGE_NAME}-cache \\
                    --snapshot-mode=redo \\
                    --log-format=text \\
                    --verbosity=info
                """
              }
            }
          }
        }
      }
    }

    stage('Deploy to Kubernetes') {
      steps {
        sh '''
          set -eux

          echo "Updating image in k8s/deploy.yaml..."

          # 이미지 태그 업데이트 (sed를 사용한 in-place 치환)
          sed -Ei "s#(image:[[:space:]]*$IMAGE_REGISTRY/$IMAGE_NAME)[^[:space:]]+#\\1:$FINAL_IMAGE_TAG#" ./k8s/deploy.yaml

          echo "--- Updated deploy.yaml ---"
          grep 'image:' ./k8s/deploy.yaml

          # Kubernetes 배포
          kubectl apply -n ${K8S_NAMESPACE} -f ./k8s

          # 롤아웃 완료 대기 (타임아웃 5분)
          kubectl rollout status -n ${K8S_NAMESPACE} deployment/${IMAGE_NAME} --timeout=5m
        '''
      }
    }
  }

  post {
    always {
      echo 'Pipeline finished!'
    }
    success {
      echo '✅ Build and Deployment succeeded!'
    }
    failure {
      echo '❌ Build or Deployment failed!'
    }
  }
}