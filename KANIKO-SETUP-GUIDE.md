# Kaniko 기반 CI/CD 구성 가이드

> **목적**: Jenkins + Kaniko + Kubernetes를 활용한 CI/CD 파이프라인 구성 및 각 단계의 원리 이해

## 목차
- [Phase 1: 환경 준비](#phase-1-환경-준비)
- [Phase 2: Kubernetes 리소스 준비](#phase-2-kubernetes-리소스-준비)
- [Phase 3: Jenkins 설치 및 설정](#phase-3-jenkins-설치-및-설정)
- [Phase 4: Jenkinsfile 수정](#phase-4-jenkinsfile-수정)
- [Phase 5: 전체 Jenkinsfile 구조](#phase-5-전체-jenkinsfile-구조)
- [Phase 6: 테스트 및 검증](#phase-6-테스트-및-검증)
- [Phase 7: 트러블슈팅](#phase-7-트러블슈팅)

---

## Phase 1: 환경 준비

### 1.1 전제 조건 확인

**필요한 인프라**:
```bash
# Kubernetes 클러스터 접근 확인
kubectl cluster-info
kubectl get nodes

# Jenkins가 사용할 네임스페이스 확인
kubectl get ns skala-practice
```

**학습 포인트**:
- Kaniko는 Kubernetes Pod로 실행되므로 K8s 클러스터 필수
- Jenkins도 K8s에 있거나, 최소한 K8s API 접근 권한 필요

### 1.2 Jenkins 실행 방식 결정

#### 옵션 A: Jenkins를 Kubernetes에 배포 (추천)
**장점**:
- Kaniko Pod를 동일 클러스터에서 실행 가능
- 네트워크 격리 없음
- 리소스 관리 용이
- 실무 환경과 유사

**단점**:
- 초기 설정이 복잡
- Helm 또는 YAML 이해 필요

#### 옵션 B: Jenkins를 Docker로 로컬 실행
**장점**:
- 빠른 시작
- 로컬 개발 환경과 유사

**단점**:
- kubectl 설정 공유 필요
- kubeconfig 파일 마운트 필수
- 클러스터 외부에서 접근 (네트워크 이슈 가능)

**실행 방법** (옵션 B):
```bash
docker run -d \
  --name jenkins \
  -p 8080:8080 \
  -p 50000:50000 \
  -v jenkins_home:/var/jenkins_home \
  -v ~/.kube:/root/.kube \
  -v ~/.m2:/root/.m2 \
  jenkins/jenkins:lts
```

---

## Phase 2: Kubernetes 리소스 준비

### 2.1 Harbor Registry Secret 생성

**목적**: Kaniko가 이미지를 푸시할 때 Harbor 인증에 사용

**Secret 생성**:
```bash
kubectl create secret docker-registry harbor-registry-secret \
  --docker-server=amdp-registry.skala-ai.com \
  --docker-username='robot$skala25a' \
  --docker-password='1qB9cyusbNComZPHAdjNIFWinf52xaBJ' \
  --namespace=skala-practice
```

**검증**:
```bash
# Secret 존재 확인
kubectl get secret harbor-registry-secret -n skala-practice

# 상세 정보 확인
kubectl describe secret harbor-registry-secret -n skala-practice

# dockerconfigjson 내용 확인
kubectl get secret harbor-registry-secret -n skala-practice \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq
```

**학습 포인트**:
- Kaniko는 `/kaniko/.docker/config.json`에서 인증 정보 읽음
- Secret을 volumeMount로 해당 경로에 마운트
- `docker-registry` 타입 Secret은 자동으로 `.dockerconfigjson` 생성
- `.dockerconfigjson` 구조:
  ```json
  {
    "auths": {
      "amdp-registry.skala-ai.com": {
        "username": "robot$skala25a",
        "password": "...",
        "auth": "base64(username:password)"
      }
    }
  }
  ```

### 2.2 ServiceAccount 및 RBAC 설정

**목적**: Jenkins가 Kaniko Pod를 생성할 권한 부여

**파일 생성**: `k8s/jenkins-rbac.yaml`

```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: jenkins-agent
  namespace: skala-practice
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: jenkins-agent-role
  namespace: skala-practice
rules:
- apiGroups: [""]
  resources: ["pods", "pods/exec", "pods/log"]
  verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get"]
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: jenkins-agent-binding
  namespace: skala-practice
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: jenkins-agent-role
subjects:
- kind: ServiceAccount
  name: jenkins-agent
  namespace: skala-practice
```

**적용 및 확인**:
```bash
# RBAC 리소스 적용
kubectl apply -f k8s/jenkins-rbac.yaml

# 생성된 리소스 확인
kubectl get sa,role,rolebinding -n skala-practice

# 권한 테스트
kubectl auth can-i create pods \
  --as=system:serviceaccount:skala-practice:jenkins-agent \
  -n skala-practice
```

**학습 포인트**:

1. **ServiceAccount (SA)**:
   - Pod가 Kubernetes API와 통신할 때 사용하는 ID
   - User Account와 달리 네임스페이스에 속함
   - 자동으로 Token Secret 생성

2. **Role**:
   - 네임스페이스 단위 권한 정의
   - ClusterRole과 달리 특정 네임스페이스에만 적용
   - `rules`: 어떤 리소스에 어떤 동작을 허용할지 정의

3. **RoleBinding**:
   - Role을 특정 ServiceAccount에 연결
   - `subjects`: 누구에게 (ServiceAccount, User, Group)
   - `roleRef`: 어떤 권한을 (Role, ClusterRole)

4. **권한 상세**:
   - `pods/exec`: Pod 내부에서 명령 실행 (Jenkins가 빌드 명령 실행)
   - `pods/log`: Pod 로그 조회 (빌드 로그 수집)
   - `secrets`: Harbor 인증 정보 읽기
   - `configmaps`: 빌드 설정 읽기 (필요시)

---

## Phase 3: Jenkins 설치 및 설정

### 3.1 Jenkins를 Kubernetes에 배포 (Helm 사용)

**Helm 차트 추가**:
```bash
# Helm 저장소 추가
helm repo add jenkins https://charts.jenkins.io
helm repo update

# 사용 가능한 차트 버전 확인
helm search repo jenkins
```

**Values 파일 작성**: `jenkins-values.yaml`

```yaml
controller:
  # Service 타입 (LoadBalancer, NodePort, ClusterIP)
  serviceType: LoadBalancer

  # 초기 플러그인 설치
  installPlugins:
    - kubernetes:4256.v4b_a_0b_e3f_c8e5
    - git:5.7.0
    - credentials-binding:700.v8133766e4ac7
    - workflow-aggregator:600.vb_57cdd26fdd7
    - docker-workflow:580.vc0c340686b_54

  # Jenkins Controller ServiceAccount
  serviceAccount:
    create: true
    name: jenkins

  # Java 옵션 (초기 설정 마법사 스킵)
  javaOpts: "-Djenkins.install.runSetupWizard=false"

  # 리소스 제한
  resources:
    requests:
      cpu: "500m"
      memory: "1Gi"
    limits:
      cpu: "2000m"
      memory: "4Gi"

# Agent 설정 (Kaniko Pod 템플릿용)
agent:
  enabled: true
  namespace: skala-practice
  serviceAccount: jenkins-agent
```

**Jenkins 설치**:
```bash
# Jenkins 설치
helm install jenkins jenkins/jenkins \
  -f jenkins-values.yaml \
  --namespace jenkins \
  --create-namespace

# 설치 상태 확인
helm list -n jenkins
kubectl get pods -n jenkins -w
```

**초기 비밀번호 확인**:
```bash
# 방법 1: kubectl exec
kubectl exec --namespace jenkins -it svc/jenkins -c jenkins -- \
  cat /var/jenkins_home/secrets/initialAdminPassword

# 방법 2: Secret에서 확인
kubectl get secret --namespace jenkins jenkins -o jsonpath="{.data.jenkins-admin-password}" | base64 --decode
```

**Jenkins 접속**:
```bash
# Service 타입이 LoadBalancer인 경우
kubectl get svc -n jenkins jenkins

# 포트 포워딩 (로컬 테스트용)
kubectl port-forward -n jenkins svc/jenkins 8080:8080
```
→ http://localhost:8080 접속

**학습 포인트**:

1. **Helm Chart 구조**:
   - `controller`: Jenkins 마스터 노드 설정
   - `agent`: 빌드를 실행할 동적 에이전트 설정
   - Values.yaml로 선언적 설정 관리

2. **ServiceType 비교**:
   - `LoadBalancer`: 외부 IP 할당 (클라우드 환경)
   - `NodePort`: 노드 IP:Port로 접근
   - `ClusterIP`: 클러스터 내부에서만 접근

3. **플러그인 자동 설치**:
   - `kubernetes`: K8s에서 동적 Agent Pod 생성
   - `git`: Git 저장소 연동
   - `credentials-binding`: Secret을 환경 변수로 바인딩
   - `workflow-aggregator`: Pipeline DSL 지원

### 3.2 Jenkins Kubernetes Plugin 설정

**Jenkins UI 접속 후 설정**:

1. **Manage Jenkins → Clouds → New cloud → Kubernetes**

2. **주요 설정 항목**:

   | 항목 | 값 | 설명 |
   |------|-----|------|
   | Kubernetes URL | `https://kubernetes.default.svc.cluster.local` | 클러스터 내부 API 서버 |
   | Kubernetes Namespace | `skala-practice` | Pod 생성할 네임스페이스 |
   | Credentials | `k8s-sa-token` | ServiceAccount Token |
   | Jenkins URL | `http://jenkins.jenkins.svc.cluster.local:8080` | Agent가 연결할 Jenkins 주소 |

**ServiceAccount Token을 Jenkins Credential로 등록**:

```bash
# Step 1: ServiceAccount의 Secret 이름 찾기
SA_SECRET=$(kubectl get sa jenkins-agent -n skala-practice -o jsonpath='{.secrets[0].name}')

# Step 2: Token 추출
TOKEN=$(kubectl get secret $SA_SECRET -n skala-practice -o jsonpath='{.data.token}' | base64 -d)

# Step 3: Token 출력 (복사)
echo $TOKEN
```

**Jenkins UI에서 Credential 등록**:
- Manage Jenkins → Credentials → System → Global credentials
- Add Credentials:
  - Kind: `Secret text`
  - Secret: (위에서 복사한 토큰)
  - ID: `k8s-sa-token`
  - Description: `Kubernetes ServiceAccount Token for skala-practice`

**학습 포인트**:

1. **ServiceAccount Token**:
   - Kubernetes API 인증 방법 중 하나
   - JWT(JSON Web Token) 형식
   - `system:serviceaccount:<namespace>:<sa-name>` 형태의 identity

2. **Jenkins ↔ Kubernetes 연동 흐름**:
   ```
   Jenkins Pipeline 실행
     ↓
   podTemplate() 호출
     ↓
   Kubernetes API에 Pod 생성 요청 (Token 인증)
     ↓
   Kaniko Pod 생성 (jenkins-agent SA 사용)
     ↓
   Jenkins가 Pod 내부에서 명령 실행
     ↓
   빌드 완료 후 Pod 자동 삭제
   ```

3. **kubernetes.default.svc.cluster.local**:
   - 클러스터 내부 DNS
   - 모든 Pod에서 접근 가능한 API 서버 주소
   - 클러스터 외부에서는 다른 주소 사용

---

## Phase 4: Jenkinsfile 수정

### 4.1 현재 구조 분석

**현재 Docker 기반 빌드** (Jenkinsfile:63-72):
```groovy
stage('Image Build & Push (docker)') {
    steps {
        script {
            docker.withRegistry("https://${IMAGE_REGISTRY}", "${DOCKER_CREDENTIAL_ID}") {
                def appImage = docker.build("${IMAGE_REF}", "--platform=linux/amd64 .")
                appImage.push()
            }
        }
    }
}
```

**문제점**:
- Jenkins 노드에 Docker 데몬 필요
- root 권한 필요 (보안 위험)
- 단일 노드에서만 실행 가능

### 4.2 Kaniko Stage로 교체

**제거할 부분**: 위의 Docker stage 전체

**추가할 코드**:
```groovy
stage('Image Build & Push (Kaniko)') {
  steps {
    script {
      // Kaniko Pod 템플릿 정의
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
    - name: workspace
      mountPath: /workspace
  volumes:
  - name: docker-config
    secret:
      secretName: harbor-registry-secret
      items:
      - key: .dockerconfigjson
        path: config.json
  - name: workspace
    emptyDir: {}
"""

      // Kubernetes Plugin을 사용한 동적 Pod 생성
      podTemplate(yaml: kanikoYaml) {
        node(POD_LABEL) {
          // Git checkout (Kaniko Pod 내부에서)
          checkout scm

          container('kaniko') {
            sh """
              /kaniko/executor \\
                --context=/workspace \\
                --dockerfile=/workspace/Dockerfile \\
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
```

### 4.3 코드 상세 설명

#### Pod Template 부분

**1. 컨테이너 이미지**:
```yaml
image: gcr.io/kaniko-project/executor:v1.23.0-debug
```
- `debug` 태그: BusyBox shell 포함 (디버깅 용이)
- `latest` 태그: shell 없음 (경량, 프로덕션 권장)
- `v1.23.0`: 특정 버전 고정 (재현 가능성)

**2. Command와 TTY**:
```yaml
command: ["/busybox/cat"]
tty: true
```
- **목적**: Pod를 실행 상태로 유지
- Kaniko는 즉시 종료되는 이미지 → shell을 실행하여 대기
- Jenkins가 나중에 `/kaniko/executor` 명령 실행

**3. Volume Mounts**:
```yaml
volumeMounts:
- name: docker-config
  mountPath: /kaniko/.docker
- name: workspace
  mountPath: /workspace
```
- `/kaniko/.docker/config.json`: Harbor 인증 정보
- `/workspace`: Git 소스 코드 (Jenkins가 checkout)

**4. Volumes**:
```yaml
volumes:
- name: docker-config
  secret:
    secretName: harbor-registry-secret
    items:
    - key: .dockerconfigjson
      path: config.json  # /kaniko/.docker/config.json으로 마운트됨
- name: workspace
  emptyDir: {}  # 임시 디렉토리 (Pod 삭제 시 사라짐)
```

#### Kaniko Executor 옵션

| 옵션 | 설명 | 예시 |
|------|------|------|
| `--context` | Dockerfile이 있는 빌드 컨텍스트 경로 | `/workspace` |
| `--dockerfile` | Dockerfile 경로 (절대 또는 컨텍스트 상대) | `/workspace/Dockerfile` |
| `--destination` | 푸시할 이미지 전체 경로 | `registry.com/repo/image:tag` |
| `--cache` | 레이어 캐싱 활성화 (빌드 속도 향상) | `true` / `false` |
| `--cache-repo` | 캐시 이미지 저장 위치 | `registry.com/repo/cache` |
| `--snapshot-mode` | 파일 변경 감지 방식 | `redo`, `time`, `full` |
| `--log-format` | 로그 출력 형식 | `text`, `json` |
| `--verbosity` | 로그 레벨 | `panic`, `fatal`, `error`, `warn`, `info`, `debug`, `trace` |

**snapshot-mode 비교**:
- `redo`: 파일 내용 기반 (정확하지만 느림)
- `time`: 수정 시간 기반 (빠르지만 부정확할 수 있음)
- `full`: 전체 파일시스템 스캔 (가장 정확하지만 가장 느림)

#### Pipeline DSL

**1. podTemplate()**:
```groovy
podTemplate(yaml: kanikoYaml) {
  node(POD_LABEL) {
    // ...
  }
}
```
- Kubernetes Plugin이 제공하는 함수
- YAML로 정의한 Pod를 동적 생성
- `POD_LABEL`: 자동 생성된 Pod 라벨 (Jenkins가 할당)

**2. checkout scm**:
```groovy
checkout scm
```
- Jenkinsfile이 있는 Git 저장소를 체크아웃
- `scm`: Source Code Management (Pipeline에서 자동 설정)
- 동일한 branch, commit을 Pod 내부로 복제

**3. container()**:
```groovy
container('kaniko') {
  sh "..."
}
```
- 멀티 컨테이너 Pod에서 특정 컨테이너 선택
- 해당 컨테이너 내부에서 명령 실행

---

## Phase 5: 전체 Jenkinsfile 구조

### 5.1 완성된 Jenkinsfile

```groovy
pipeline {
  agent any

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
```

### 5.2 주요 변경점 요약

| 항목 | 이전 (Docker) | 이후 (Kaniko) |
|------|--------------|--------------|
| Git URL | `qoqomi/myfirst-api-server` | `sjnqkqh/Jenkins-CI-CD-sample` |
| 빌드 도구 | Docker (데몬 필요) | Kaniko (데몬리스) |
| 실행 위치 | Jenkins 노드 | Kubernetes Pod |
| 인증 방식 | Jenkins Credential | Kubernetes Secret |
| 태그 생성 | 해시 기반 | 타임스탬프 기반 |
| 캐싱 | Docker layer cache | Kaniko cache repo |

### 5.3 추가 개선 사항

#### GitHub PAT Credential 등록

**Jenkins UI 설정**:
1. Manage Jenkins → Credentials → Global
2. Add Credentials:
   - Kind: `Username with password`
   - Username: GitHub 사용자명
   - Password: Personal Access Token (PAT)
   - ID: `github-pat-credential`

**GitHub PAT 생성** (https://github.com/settings/tokens):
- Settings → Developer settings → Personal access tokens → Tokens (classic)
- Generate new token:
  - ✅ `repo` (전체 체크)
  - ✅ `workflow` (GitHub Actions 사용 시)

#### Maven 캐싱 (빌드 속도 향상)

**Persistent Volume 사용**:
```groovy
stage('Build with Maven') {
  steps {
    container('maven') {
      sh 'mvn clean package -DskipTests -Dmaven.repo.local=/workspace/.m2'
    }
  }
}
```

---

## Phase 6: 테스트 및 검증

### 6.1 단계별 검증 절차

#### Step 1: RBAC 권한 검증

```bash
# jenkins-agent SA가 Pod 생성 권한 있는지 확인
kubectl auth can-i create pods \
  --as=system:serviceaccount:skala-practice:jenkins-agent \
  -n skala-practice
# 출력: yes

# 다른 권한도 확인
kubectl auth can-i get secrets \
  --as=system:serviceaccount:skala-practice:jenkins-agent \
  -n skala-practice
# 출력: yes
```

#### Step 2: Secret 검증

```bash
# Secret 존재 확인
kubectl get secret harbor-registry-secret -n skala-practice

# dockerconfigjson 내용 확인 (포맷 검증)
kubectl get secret harbor-registry-secret -n skala-practice \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq

# 예상 출력:
# {
#   "auths": {
#     "amdp-registry.skala-ai.com": {
#       "username": "robot$skala25a",
#       "password": "...",
#       "auth": "..."
#     }
#   }
# }
```

#### Step 3: Kaniko 수동 테스트 (Jenkins 없이)

**테스트용 Pod 생성**:
```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: kaniko-test
  namespace: skala-practice
spec:
  serviceAccountName: jenkins-agent
  containers:
  - name: kaniko
    image: gcr.io/kaniko-project/executor:v1.23.0-debug
    command: ["/busybox/sh", "-c", "sleep 3600"]
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
EOF
```

**Pod 내부에서 빌드 테스트**:
```bash
# Pod 접속
kubectl exec -it kaniko-test -n skala-practice -- /busybox/sh

# (Pod 내부) 인증 설정 확인
cat /kaniko/.docker/config.json

# (Pod 내부) Git에서 직접 빌드 테스트
/kaniko/executor \
  --context=git://github.com/sjnqkqh/Jenkins-CI-CD-sample \
  --destination=amdp-registry.skala-ai.com/skala25a/test:kaniko \
  --cache=true \
  --verbosity=debug
```

**성공 시 출력**:
```
INFO[0000] Retrieving image manifest ...
INFO[0001] Retrieving image layers ...
INFO[0010] Built cross stage deps: map[]
INFO[0010] Executing 0 build triggers
INFO[0010] Building stage '...' [idx: 0, base-idx: -1]
...
INFO[0050] Pushing image to amdp-registry.skala-ai.com/skala25a/test:kaniko
INFO[0055] Pushed amdp-registry.skala-ai.com/skala25a/test:kaniko
```

**실패 시 디버깅**:
```bash
# 네트워크 확인
/busybox/ping amdp-registry.skala-ai.com

# DNS 확인
/busybox/nslookup amdp-registry.skala-ai.com

# 인증 정보 확인
cat /kaniko/.docker/config.json | /busybox/grep amdp-registry
```

**테스트 완료 후 정리**:
```bash
kubectl delete pod kaniko-test -n skala-practice
```

#### Step 4: Jenkins Pipeline 생성

**Jenkins UI 작업**:
1. **New Item** → 이름 입력 (예: `kaniko-cicd-test`) → **Pipeline** 선택
2. **Pipeline 설정**:
   - Definition: `Pipeline script from SCM`
   - SCM: `Git`
   - Repository URL: `https://github.com/sjnqkqh/Jenkins-CI-CD-sample`
   - Credentials: `github-pat-credential`
   - Branch Specifier: `*/main`
   - Script Path: `Jenkinsfile`
3. **Save** 클릭
4. **Build Now** 클릭

#### Step 5: 빌드 로그 모니터링

**Jenkins UI에서**:
- Build History에서 진행 중인 빌드 클릭
- Console Output 확인

**Kubernetes에서**:
```bash
# Kaniko Pod 조회 (실행 중일 때만 보임)
kubectl get pods -n skala-practice | grep kaniko

# 실시간 로그 확인
kubectl logs -f -n skala-practice <kaniko-pod-name>

# 여러 Pod 동시 모니터링 (stern 사용)
stern -n skala-practice kaniko
```

**Deployment 상태 확인**:
```bash
# Deployment 상태 (실시간)
kubectl get pods -n skala-practice -w

# Rollout history
kubectl rollout history -n skala-practice deployment/sk077-myfirst-api-server

# 최근 이벤트
kubectl get events -n skala-practice --sort-by='.lastTimestamp'
```

#### Step 6: 애플리케이션 검증

**Pod 상태 확인**:
```bash
kubectl get pods -n skala-practice -l app=sk077-myfirst-api-server
```

**서비스 접속**:
```bash
# Service 정보 확인
kubectl get svc -n skala-practice

# 포트 포워딩
kubectl port-forward -n skala-practice svc/sk077-myfirst-api-server 8080:8080

# 헬스 체크
curl http://localhost:8080/actuator/health
```

**Ingress 확인** (있는 경우):
```bash
kubectl get ingress -n skala-practice
```

### 6.2 성능 측정

**빌드 시간 비교**:
```bash
# Jenkins 빌드 히스토리에서 확인
# Docker 빌드 vs Kaniko 빌드 시간 비교
```

**캐시 효과 확인**:
```bash
# 첫 번째 빌드 (캐시 없음)
# 두 번째 빌드 (캐시 사용)
# 시간 차이 확인

# Harbor에서 캐시 이미지 확인
# <IMAGE_NAME>-cache 저장소 확인
```

---

## Phase 7: 트러블슈팅

### 7.1 자주 발생하는 문제

#### 문제 1: Kaniko Pod 생성 실패

**증상**:
```
Error: pods is forbidden: User "system:serviceaccount:jenkins:jenkins"
cannot create resource "pods" in API group "" in the namespace "skala-practice"
```

**원인**: RBAC 권한 부족

**해결**:
```bash
# 권한 확인
kubectl auth can-i create pods \
  --as=system:serviceaccount:skala-practice:jenkins-agent \
  -n skala-practice

# RoleBinding 확인
kubectl get rolebinding -n skala-practice jenkins-agent-binding -o yaml

# 문제: subject의 ServiceAccount가 잘못됨
# 수정: jenkins → jenkins-agent
kubectl edit rolebinding jenkins-agent-binding -n skala-practice
```

#### 문제 2: Harbor 인증 실패

**증상**:
```
error pushing image: failed to push to destination
amdp-registry.skala-ai.com/skala25a/sk077-myfirst-api-server:1.0.0-xxx:
UNAUTHORIZED: authentication required
```

**원인**: Secret 설정 오류

**해결 1: Secret 형식 확인**:
```bash
# dockerconfigjson 확인
kubectl get secret harbor-registry-secret -n skala-practice \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq

# 올바른 형식:
{
  "auths": {
    "amdp-registry.skala-ai.com": {
      "username": "robot$skala25a",
      "password": "...",
      "auth": "..."
    }
  }
}

# auth 필드가 없다면 수동 생성:
echo -n "robot\$skala25a:password" | base64
```

**해결 2: Secret 재생성**:
```bash
# 기존 Secret 삭제
kubectl delete secret harbor-registry-secret -n skala-practice

# 재생성 (패스워드 확인!)
kubectl create secret docker-registry harbor-registry-secret \
  --docker-server=amdp-registry.skala-ai.com \
  --docker-username='robot$skala25a' \
  --docker-password='1qB9cyusbNComZPHAdjNIFWinf52xaBJ' \
  --namespace=skala-practice
```

**해결 3: Harbor 사용자 권한 확인**:
- Harbor UI 접속
- Projects → skala25a → Members
- robot$skala25a 계정에 `Push` 권한 있는지 확인

#### 문제 3: Git 체크아웃 실패

**증상**:
```
ERROR: Error cloning remote repo 'origin'
hudson.plugins.git.GitException: Command "git fetch --tags --progress
https://github.com/sjnqkqh/Jenkins-CI-CD-sample +refs/heads/*:refs/remotes/origin/*"
returned status code 128
```

**원인**: GitHub 인증 실패

**해결**:
```bash
# 1. GitHub PAT 권한 확인
# Settings → Developer settings → Personal access tokens
# ✅ repo 권한 필요

# 2. Jenkins Credential 확인
# Credential ID가 Jenkinsfile과 일치하는지 확인
# github-pat-credential

# 3. Private 저장소인 경우 PAT 필수
# Public 저장소는 Credential 없이도 가능
```

#### 문제 4: kubectl 명령 실패 (Deploy stage)

**증상**:
```
The connection to the server localhost:8080 was refused
```

**원인**: kubectl 설정이 없거나 잘못됨

**해결 (Jenkins가 클러스터 외부인 경우)**:
```bash
# Jenkins Pod에 kubeconfig 마운트
# values.yaml에 추가:
controller:
  additionalVolumes:
    - name: kubeconfig
      secret:
        secretName: kubeconfig-secret
  additionalVolumeMounts:
    - name: kubeconfig
      mountPath: /root/.kube

# kubeconfig Secret 생성:
kubectl create secret generic kubeconfig-secret \
  --from-file=config=$HOME/.kube/config \
  -n jenkins
```

**해결 (Jenkins가 클러스터 내부인 경우)**:
```bash
# ServiceAccount 사용
# Jenkinsfile Deploy stage 수정:
sh '''
  kubectl --token=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token) \
    --server=https://kubernetes.default.svc.cluster.local \
    --certificate-authority=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
    apply -n ${K8S_NAMESPACE} -f ./k8s
'''
```

#### 문제 5: 이미지 태그가 업데이트되지 않음

**증상**:
```bash
kubectl get pods -n skala-practice
# 새 Pod가 생성되지 않음
```

**원인**: deploy.yaml의 이미지 태그가 변경되지 않음

**해결**:
```bash
# sed 명령어 디버깅
echo "현재 이미지:"
grep 'image:' ./k8s/deploy.yaml

echo "환경 변수:"
echo "IMAGE_REGISTRY=$IMAGE_REGISTRY"
echo "IMAGE_NAME=$IMAGE_NAME"
echo "FINAL_IMAGE_TAG=$FINAL_IMAGE_TAG"

# sed 패턴 확인
sed -n "s#(image:[[:space:]]*$IMAGE_REGISTRY/$IMAGE_NAME)[^[:space:]]+#\\1:$FINAL_IMAGE_TAG#p" ./k8s/deploy.yaml
```

**대안: Kustomize 사용**:
```bash
# kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deploy.yaml
images:
  - name: amdp-registry.skala-ai.com/skala25a/sk077-myfirst-api-server
    newTag: ${FINAL_IMAGE_TAG}

# Jenkinsfile
sh '''
  kustomize edit set image ${IMAGE_REGISTRY}/${IMAGE_NAME}:${FINAL_IMAGE_TAG}
  kubectl apply -k . -n ${K8S_NAMESPACE}
'''
```

#### 문제 6: Kaniko 빌드가 너무 느림

**원인**: 캐시 미사용 또는 네트워크 문제

**해결**:
```bash
# 1. 캐시 확인
# Harbor에 <IMAGE_NAME>-cache 저장소 생성 확인

# 2. snapshot-mode 변경
--snapshot-mode=time  # redo 대신 time 사용 (빠름)

# 3. 네트워크 최적화
--push-retry=3  # 푸시 재시도 횟수
--skip-tls-verify  # TLS 검증 스킵 (테스트용만)

# 4. 병렬 처리
--parallel-push  # 레이어 병렬 푸시
```

### 7.2 디버깅 팁

#### Kaniko 디버그 모드

```bash
# executor 대신 debug 이미지 사용
image: gcr.io/kaniko-project/executor:v1.23.0-debug

# Pod 접속하여 수동 실행
kubectl exec -it <kaniko-pod> -n skala-practice -- /busybox/sh

# 환경 변수 확인
env

# 파일 시스템 확인
ls -la /workspace
ls -la /kaniko/.docker

# 수동 빌드 (단계별)
/kaniko/executor \
  --context=/workspace \
  --no-push \
  --verbosity=trace
```

#### Jenkins Pipeline 디버깅

```groovy
// 환경 변수 출력
sh 'env | sort'

// 파일 확인
sh 'ls -la'
sh 'cat Dockerfile'

// Pod 정보 출력
sh 'kubectl get pods -n skala-practice'

// 조건부 실행
script {
  if (env.BRANCH_NAME == 'main') {
    echo "메인 브랜치 빌드"
  }
}
```

### 7.3 로그 수집

**Kaniko Pod 로그**:
```bash
# 실시간 로그
kubectl logs -f <kaniko-pod> -n skala-practice

# 로그 저장
kubectl logs <kaniko-pod> -n skala-practice > kaniko-build.log

# 이전 Pod 로그 (재시작된 경우)
kubectl logs <kaniko-pod> -n skala-practice --previous
```

**Jenkins 빌드 로그**:
```bash
# CLI로 로그 다운로드
jenkins-cli -s http://jenkins-url/ console <job-name> <build-number>
```

**Kubernetes 이벤트**:
```bash
# 네임스페이스 이벤트 (최근 1시간)
kubectl get events -n skala-practice \
  --sort-by='.lastTimestamp' \
  --field-selector involvedObject.kind=Pod

# 특정 Pod 이벤트
kubectl describe pod <kaniko-pod> -n skala-practice
```

---

## 📋 실행 체크리스트

### 사전 준비
- [ ] Kubernetes 클러스터 접근 가능
- [ ] kubectl 명령어 실행 가능
- [ ] Helm 설치 (Jenkins 배포용)
- [ ] `skala-practice` 네임스페이스 존재
- [ ] Harbor Registry 접속 가능
- [ ] GitHub 저장소 접근 권한

### Kubernetes 리소스 생성
- [ ] Harbor Registry Secret 생성
  ```bash
  kubectl get secret harbor-registry-secret -n skala-practice
  ```
- [ ] ServiceAccount `jenkins-agent` 생성
  ```bash
  kubectl get sa jenkins-agent -n skala-practice
  ```
- [ ] Role 및 RoleBinding 생성
  ```bash
  kubectl get role,rolebinding -n skala-practice | grep jenkins-agent
  ```
- [ ] RBAC 권한 검증
  ```bash
  kubectl auth can-i create pods --as=system:serviceaccount:skala-practice:jenkins-agent -n skala-practice
  ```

### Jenkins 설치
- [ ] Helm으로 Jenkins 설치
  ```bash
  helm list -n jenkins
  ```
- [ ] Jenkins Pod 실행 확인
  ```bash
  kubectl get pods -n jenkins
  ```
- [ ] 초기 비밀번호로 로그인
- [ ] 필수 플러그인 설치
  - [ ] Kubernetes Plugin
  - [ ] Git Plugin
  - [ ] Credentials Binding Plugin

### Jenkins 설정
- [ ] Kubernetes Cloud 설정
  - [ ] Kubernetes URL: `https://kubernetes.default.svc.cluster.local`
  - [ ] Namespace: `skala-practice`
  - [ ] Credentials: ServiceAccount Token
- [ ] GitHub PAT Credential 등록 (ID: `github-pat-credential`)
- [ ] ServiceAccount Token Credential 등록 (ID: `k8s-sa-token`)

### Jenkinsfile 수정
- [ ] Git URL → `https://github.com/sjnqkqh/Jenkins-CI-CD-sample`
- [ ] Docker stage 제거
- [ ] Kaniko stage 추가
- [ ] Credential ID 업데이트

### 테스트
- [ ] Kaniko 수동 테스트 성공
  ```bash
  kubectl exec -it kaniko-test -n skala-practice -- /kaniko/executor ...
  ```
- [ ] Jenkins Pipeline Job 생성
- [ ] 첫 번째 빌드 실행
- [ ] 빌드 로그에서 에러 없는지 확인
- [ ] Harbor에 이미지 푸시 확인
- [ ] Kubernetes 배포 성공 확인
  ```bash
  kubectl get pods -n skala-practice -l app=sk077-myfirst-api-server
  ```
- [ ] 애플리케이션 접속 테스트
  ```bash
  curl http://<service-url>/actuator/health
  ```

### 최적화 (선택)
- [ ] 캐시 활성화 확인 (두 번째 빌드가 더 빠른지)
- [ ] Maven 로컬 저장소 캐싱
- [ ] Parallel Stage 적용
- [ ] 알림 설정 (Slack, Email 등)

---

## 다음 단계: 고급 주제

### 1. GitOps (ArgoCD)
- Jenkinsfile에서 kubectl apply 제거
- Git Push만 하면 ArgoCD가 자동 배포
- Declarative, Auditable 배포

### 2. Multi-stage Dockerfile 최적화
```dockerfile
# 빌드 스테이지
FROM maven:3.8-openjdk-17 AS builder
WORKDIR /app
COPY pom.xml .
RUN mvn dependency:go-offline
COPY src ./src
RUN mvn package -DskipTests

# 런타임 스테이지
FROM openjdk:17-slim
COPY --from=builder /app/target/*.jar app.jar
ENTRYPOINT ["java", "-jar", "/app.jar"]
```

### 3. 보안 스캔
```groovy
stage('Security Scan') {
  steps {
    sh 'trivy image ${IMAGE_REF}'
  }
}
```

### 4. 성능 테스트
```groovy
stage('Performance Test') {
  steps {
    sh 'k6 run load-test.js'
  }
}
```

### 5. Blue-Green / Canary 배포
```yaml
# Argo Rollouts 사용
kind: Rollout
spec:
  strategy:
    canary:
      steps:
      - setWeight: 20
      - pause: {duration: 10m}
      - setWeight: 50
      - pause: {duration: 10m}
```

---

## 참고 자료

### 공식 문서
- [Kaniko Documentation](https://github.com/GoogleContainerTools/kaniko)
- [Jenkins Kubernetes Plugin](https://plugins.jenkins.io/kubernetes/)
- [Kubernetes RBAC](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)

### 학습 자료
- [12-Factor App](https://12factor.net/)
- [Kubernetes Best Practices](https://kubernetes.io/docs/concepts/configuration/overview/)
- [Docker vs Kaniko](https://cloud.google.com/blog/products/containers-kubernetes/introducing-kaniko-build-container-images-in-kubernetes-and-google-container-builder-even-without-root-access)

### 트러블슈팅
- [Kaniko Issues](https://github.com/GoogleContainerTools/kaniko/issues)
- [Jenkins Pipeline Syntax](https://www.jenkins.io/doc/book/pipeline/syntax/)

---

**작성일**: 2025-10-05
**버전**: 1.0
**대상 레포지토리**: https://github.com/sjnqkqh/Jenkins-CI-CD-sample