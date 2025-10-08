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
  # Maven 컨테이너: 빌드
  - name: maven
    image: maven:3.8.6-openjdk-17
    command:
    - cat
    tty: true
    volumeMounts:
    - name: maven-cache
      mountPath: /root/.m2
  # Kaniko 컨테이너: Docker 이미지 빌드 & Push
  - name: kaniko
    image: gcr.io/kaniko-project/executor:debug
    command:
    - /busybox/cat
    tty: true
    volumeMounts:
    - name: docker-config
      mountPath: /kaniko/.docker
  # kubectl 컨테이너: K8S 배포
  - name: kubectl
    image: lachlanevenson/k8s-kubectl:latest
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
  - name: maven-cache
    emptyDir: {}
'''
    }
  }

  environment {
    // === 사용자 수정 영역 ===
    GIT_URL                = 'https://github.com/sjnqkqh/Jenkins-CI-CD-sample.git'
    GIT_BRANCH             = 'main'
    GIT_ID                 = 'skala-github-id'   // GitHub PAT credential ID
    IMAGE_NAME             = 'sk077-myfirst-api-server'
    // =======================
    IMAGE_TAG              = '1.0.0'
    IMAGE_REGISTRY_URL     = 'amdp-registry.skala-ai.com'
    IMAGE_REGISTRY_PROJECT = 'skala25a'

    DOCKER_CREDENTIAL_ID   = 'skala-image-registry-id'  // Harbor 인증 정보 ID
    K8S_NAMESPACE          = 'skala-practice'
  }

  options {
    disableConcurrentBuilds()
    timestamps()
  }

  stages {
    stage('Clone Repository') {
      steps {
        echo 'Clone Repository'
        git branch: "${GIT_BRANCH}", url: "${GIT_URL}", credentialsId: "${GIT_ID}"
        sh 'ls -al'
      }
    }

    stage('Build with Maven') {
      steps {
        container('maven') {
          echo 'Build with Maven'
          sh 'mvn clean package -DskipTests'
          sh 'ls -al'
        }
      }
    }

    // 태그/이미지 경로 계산 (메타)
    stage('Compute Image Meta') {
      steps {
        script {
          def hashcode = sh(script: "date +%s%N | sha256sum | cut -c1-12", returnStdout: true).trim()
          env.FINAL_IMAGE_TAG = "${IMAGE_TAG}-${hashcode}"
          env.IMAGE_REGISTRY  = "${env.IMAGE_REGISTRY_URL}/${env.IMAGE_REGISTRY_PROJECT}"
          env.REG_HOST        = env.IMAGE_REGISTRY_URL
          env.IMAGE_REF       = "${env.IMAGE_REGISTRY}/${IMAGE_NAME}:${env.FINAL_IMAGE_TAG}"

          echo "REG_HOST: ${env.REG_HOST}"
          echo "IMAGE_REF: ${env.IMAGE_REF}"
        }
      }
    }

    // Kaniko를 사용한 이미지 빌드 & 푸시
    stage('Image Build & Push (Kaniko)') {
      steps {
        container('kaniko') {
          script {
            sh """
              /kaniko/executor \
                --context=${WORKSPACE} \
                --dockerfile=${WORKSPACE}/Dockerfile \
                --destination=${IMAGE_REF} \
                --custom-platform=linux/amd64 \
                --cache=true \
                --cache-ttl=24h \
                --compressed-caching=false \
                --cleanup
            """
          }
        }
      }
    }

    // k8s 리소스 파일(deploy.yaml) 수정 및 배포
    stage('Deploy to Kubernetes') {
      steps {
        container('kubectl') {
          sh '''
            set -eux
            test -f ./k8s/deploy.yaml

            echo "--- BEFORE ---"
            grep -n 'image:' ./k8s/deploy.yaml || true

            # IMAGE_REGISTRY/IMAGE_NAME 패턴의 태그를 FINAL_IMAGE_TAG 로 치환
            sed -Ei "s#(image:[[:space:]]*$IMAGE_REGISTRY/$IMAGE_NAME)[^[:space:]]+#\\1:$FINAL_IMAGE_TAG#" ./k8s/deploy.yaml

            echo "--- AFTER ---"
            grep -n 'image:' ./k8s/deploy.yaml || true

            kubectl apply -n ${K8S_NAMESPACE} -f ./k8s
            kubectl rollout status -n ${K8S_NAMESPACE} deployment/${IMAGE_NAME}
          '''
        }
      }
    }
  }
}