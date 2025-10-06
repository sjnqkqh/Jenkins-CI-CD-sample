pipeline {
  agent any

  environment {
    // === Git 설정 ===
    GIT_URL     = 'https://github.com/sjnqkqh/Jenkins-CI-CD-sample'
    GIT_BRANCH  = 'main'
    GIT_ID      = 'github-pat-credential'  // Jenkins Credentials ID (PAT은 Jenkins에 보관)

    // === 이미지 설정 ===
    IMAGE_NAME  = 'sk077-myfirst-api-server'
    IMAGE_TAG   = '1.0.0'
    IMAGE_REGISTRY_URL     = 'amdp-registry.skala-ai.com'
    IMAGE_REGISTRY_PROJECT = 'skala25a'
    IMAGE_REGISTRY = "${IMAGE_REGISTRY_URL}/${IMAGE_REGISTRY_PROJECT}"

    // === Kubernetes 설정 ===
    K8S_NAMESPACE = 'skala-practice'
  }

  options {
    disableConcurrentBuilds()
  }

  stages {
    stage('Build / Push / Deploy (in one K8s Pod)') {
      steps {
        script {
          // ▶ 한 Pod에 maven / kaniko / kubectl 컨테이너 구성
          def buildPod = """
apiVersion: v1
kind: Pod
metadata:
  name: build-kaniko-kubectl
spec:
  serviceAccountName: jenkins-agent
  containers:
  - name: maven
    image: maven:3.9-eclipse-temurin-17
    imagePullPolicy: Always
    command: ['bash', '-lc', 'while true; do sleep 3600; done']
    tty: true
    volumeMounts:
    - name: maven-cache
      mountPath: /root/.m2

  - name: kaniko
    image: gcr.io/kaniko-project/executor:v1.23.0-debug
    imagePullPolicy: Always
    command: ['/busybox/sh', '-c', 'sleep 3600']
    tty: true
    volumeMounts:
    - name: docker-config
      mountPath: /kaniko/.docker

  - name: kubectl
    image: bitnami/kubectl:1.30.4
    imagePullPolicy: Always
    command: ['bash','-lc','while true; do sleep 3600; done']
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
"""

          podTemplate(yaml: buildPod) {
            node(POD_LABEL) {

              // 1) 소스 체크아웃
              git branch: "${GIT_BRANCH}",
                      url: "${GIT_URL}",
                      credentialsId: "${GIT_ID}"

              // 2) Maven 빌드 (maven 컨테이너)
              container('maven') {
                sh '''
                  set -eux
                  # mvnw가 있으면 우선 사용, 없으면 mvn 사용
                  if [ -x ./mvnw ]; then
                    ./mvnw -v
                    ./mvnw clean package -DskipTests
                  else
                    mvn -v
                    mvn clean package -DskipTests
                  fi
                  ls -al target/ || true
                '''
              }

              // 3) 이미지 태그 계산
              script {
                def ts = sh(script: "date +%Y%m%d-%H%M%S", returnStdout: true).trim()
                env.FINAL_IMAGE_TAG = "${IMAGE_TAG}-${ts}"
                env.IMAGE_REF = "${IMAGE_REGISTRY}/${IMAGE_NAME}:${FINAL_IMAGE_TAG}"
                echo "Image Reference => ${IMAGE_REF}"
              }

              // 4) 이미지 빌드 & 푸시 (kaniko 컨테이너)
              container('kaniko') {
                sh """
                  /kaniko/executor \
                    --context=\$(pwd) \
                    --dockerfile=Dockerfile \
                    --destination=${IMAGE_REF} \
                    --cache=true \
                    --cache-repo=${IMAGE_REGISTRY}/${IMAGE_NAME}-cache \
                    --snapshot-mode=redo \
                    --verbosity=info
                """
              }

              // 5) 배포 (kubectl 컨테이너)
              container('kubectl') {
                sh '''
                  set -eux
                  echo "Updating image tag in k8s/deploy.yaml ..."
                  sed -Ei "s#(image:[[:space:]]*$IMAGE_REGISTRY/$IMAGE_NAME)[^[:space:]]+#\\1:$FINAL_IMAGE_TAG#" ./k8s/deploy.yaml
                  grep 'image:' ./k8s/deploy.yaml

                  kubectl apply -n ${K8S_NAMESPACE} -f ./k8s
                  kubectl rollout status -n ${K8S_NAMESPACE} deployment/${IMAGE_NAME} --timeout=5m
                '''
              }
            }
          }
        }
      }
    }
  }

  post {
    always { echo 'Pipeline finished!' }
    success { echo '✅ Build and Deployment succeeded!' }
    failure { echo '❌ Build or Deployment failed!' }
  }
}