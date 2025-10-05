# CI/CD 구성 가이드 (학습용)

> **목적**: Jenkins, Kaniko, Kubernetes를 활용한 CI/CD 프로세스의 각 단계를 이해하고 추후 응용할 수 있도록 학습

## 현재 상태 분석

### 1. 현재 설정된 레포지토리
- **Jenkinsfile 설정**: `https://github.com/qoqomi/myfirst-api-server.git`
- **목표 레포지토리**: `https://github.com/sjnqkqh/Jenkins-CI-CD-sample`

### 2. 현재 빌드 방식
- **Docker 기반 빌드**: Jenkins에서 Docker 데몬을 사용하여 이미지 빌드 및 푸시
- **목표**: Kaniko를 사용한 데몬리스 빌드로 전환

---

## 단계별 학습 및 작업 가이드

### Phase 1: Git 연동 이해하기

#### 1.1 GitHub Repository 연결 변경
**학습 목표**: Jenkins가 GitHub 레포지토리를 어떻게 인증하고 클론하는지 이해

**현재 코드** (Jenkinsfile:6-8):
```groovy
GIT_URL     = 'https://github.com/qoqomi/myfirst-api-server.git'
GIT_BRANCH  = 'main'
GIT_ID      = 'skala-github-id'  // Jenkins Credential ID
```

**변경해야 할 사항**:
```groovy
GIT_URL     = 'https://github.com/sjnqkqh/Jenkins-CI-CD-sample'
GIT_BRANCH  = 'main'
GIT_ID      = 'skala-github-id'  // 또는 새로운 Credential ID
```

**학습 포인트**:
- Jenkins Credential은 어떻게 생성하고 관리하는가?
- GitHub PAT(Personal Access Token)는 어떤 권한이 필요한가?
- private repository vs public repository 접근 차이

**실습 과제**:
1. Jenkins UI에서 Credentials 메뉴 탐색
2. GitHub PAT 생성 (Settings > Developer settings > Personal access tokens)
3. Jenkins에 새 Credential 등록 (Username with password 타입)
   - Username: GitHub 계정명
   - Password: PAT
   - ID: `skala-github-id` (또는 원하는 ID)

---

### Phase 2: Maven 빌드 이해하기

#### 2.1 Maven 빌드 프로세스
**학습 목표**: Maven 빌드가 무엇을 생성하고, 왜 테스트를 스킵하는지 이해

**현재 코드** (Jenkinsfile:33-39):
```groovy
stage('Build with Maven') {
  steps {
    echo 'Build with Maven'
    sh 'mvn clean package -DskipTests'
    sh 'ls -al'
  }
}
```

**학습 포인트**:
- `mvn clean`: target/ 디렉토리 삭제
- `mvn package`: 컴파일 → 테스트 → JAR 파일 생성
- `-DskipTests`: 테스트를 왜 스킵하는가? (빌드 속도 vs 안정성 트레이드오프)
- 생성되는 JAR 파일 위치: `target/*.jar`

**실습 과제**:
1. 로컬에서 `mvn clean package` 실행해보기
2. `target/` 디렉토리에서 생성된 JAR 확인
3. `mvn test` 명령어로 테스트만 실행해보기
4. 빌드 시간 측정 (테스트 포함 vs 제외)

---

### Phase 3: Docker 빌드 이해하기 (현재 방식)

#### 3.1 Docker 빌드 프로세스
**학습 목표**: Docker 이미지 빌드와 레지스트리 푸시 과정 이해

**현재 코드** (Jenkinsfile:63-72):
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

**학습 포인트**:
- `docker.withRegistry()`: Docker 레지스트리 인증 처리
- `docker.build()`: Dockerfile을 기반으로 이미지 빌드
- `--platform=linux/amd64`: 멀티 아키텍처 빌드 (M1 Mac vs Intel)
- `appImage.push()`: Harbor 레지스트리에 이미지 업로드
- **문제점**: Jenkins 노드에 Docker 데몬이 필요 (보안/권한 이슈)

**실습 과제**:
1. `Dockerfile` 파일 분석
2. 로컬에서 `docker build -t test:1.0.0 .` 실행
3. `docker images` 로 생성된 이미지 확인
4. `docker history <이미지ID>` 로 레이어 구조 확인

---

### Phase 4: Kaniko로 전환하기 (핵심 학습)

#### 4.1 Kaniko란?
**학습 목표**: Docker 데몬 없이 컨테이너 이미지를 빌드하는 방법 이해

**Kaniko의 장점**:
- Docker 데몬 불필요 (보안 향상)
- Kubernetes Pod 내에서 실행 가능
- 권한 분리 (각 빌드가 독립된 Pod)
- 빌드 캐시 지원 (성능 향상)

**Kaniko vs Docker**:
| 항목 | Docker | Kaniko |
|------|--------|--------|
| 데몬 필요 | O | X |
| 실행 환경 | Jenkins 노드 | Kubernetes Pod |
| 권한 | root 필요 | 제한된 권한 |
| 보안 | 낮음 | 높음 |

#### 4.2 Kaniko를 사용한 Jenkinsfile 수정
**현재 Docker 기반 Stage 제거 후 다음으로 교체**:

```groovy
stage('Image Build & Push (Kaniko)') {
  steps {
    script {
      // Kubernetes Plugin을 사용한 동적 Pod 생성
      podTemplate(
        yaml: """
apiVersion: v1
kind: Pod
metadata:
  name: kaniko
spec:
  containers:
  - name: kaniko
    image: gcr.io/kaniko-project/executor:latest
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
      ) {
        node(POD_LABEL) {
          container('kaniko') {
            sh """
              /kaniko/executor \\
                --context=\$(pwd) \\
                --dockerfile=Dockerfile \\
                --destination=${IMAGE_REF} \\
                --cache=true \\
                --cache-repo=${IMAGE_REGISTRY}/${IMAGE_NAME}-cache
            """
          }
        }
      }
    }
  }
}
```

**학습 포인트**:
1. **podTemplate**: Jenkins에서 동적으로 Kubernetes Pod 생성
2. **gcr.io/kaniko-project/executor**: Kaniko 실행 이미지
3. **volumeMounts**: Harbor 인증 정보를 Pod에 마운트
4. **--context**: 빌드 컨텍스트 (현재 디렉토리)
5. **--destination**: 푸시할 이미지 경로
6. **--cache**: 빌드 캐시 활성화 (레이어 재사용)
7. **--cache-repo**: 캐시 저장 위치

#### 4.3 Kubernetes Secret 생성 (Harbor 인증)
**학습 목표**: Kubernetes에서 Private Registry 인증 방법 이해

**Secret 생성 명령어**:
```bash
kubectl create secret docker-registry harbor-registry-secret \
  --docker-server=amdp-registry.skala-ai.com \
  --docker-username='robot$skala25a' \
  --docker-password='1qB9cyusbNComZPHAdjNIFWinf52xaBJ' \
  --namespace=skala-practice
```

**Secret 확인**:
```bash
kubectl get secret harbor-registry-secret -n skala-practice -o yaml
```

**학습 포인트**:
- `docker-registry` 타입 Secret의 구조
- `.dockerconfigjson` 내부 구조 (base64 인코딩)
- Kaniko가 이 Secret을 어떻게 사용하는가?

**실습 과제**:
1. Secret 생성 후 `kubectl describe secret` 로 확인
2. Secret을 decode 하여 내용 확인:
   ```bash
   kubectl get secret harbor-registry-secret -n skala-practice -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d
   ```

---

### Phase 5: Jenkins Kubernetes Plugin 설정

#### 5.1 Plugin 설치 및 설정
**학습 목표**: Jenkins가 Kubernetes 클러스터와 통신하는 방법 이해

**필수 Plugin**:
- Kubernetes Plugin
- Kubernetes CLI Plugin

**설정 위치**: Jenkins 관리 > System Configuration > Cloud > Kubernetes

**주요 설정 항목**:
1. **Kubernetes URL**: Kubernetes API 서버 주소
   ```bash
   kubectl cluster-info
   ```

2. **Kubernetes Namespace**: `skala-practice`

3. **Jenkins URL**: Jenkins 서버 주소 (Pod가 Jenkins에 연결하기 위해 필요)

4. **Credentials**: Kubernetes 인증 정보
   - ServiceAccount Token 방식
   - Kubeconfig 파일 방식

**학습 포인트**:
- Jenkins가 어떻게 Kubernetes에 Pod를 생성하는가?
- ServiceAccount의 역할과 권한
- RBAC (Role-Based Access Control) 개념

#### 5.2 ServiceAccount 및 RBAC 설정
**ServiceAccount 생성**:
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: jenkins-agent
  namespace: skala-practice
```

**Role 생성** (Pod 생성 권한):
```yaml
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
```

**RoleBinding 생성**:
```yaml
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

**적용**:
```bash
kubectl apply -f serviceaccount.yaml
kubectl apply -f role.yaml
kubectl apply -f rolebinding.yaml
```

**학습 포인트**:
- ServiceAccount vs User Account
- Role vs ClusterRole 차이
- 최소 권한 원칙 (Principle of Least Privilege)

---

### Phase 6: Kubernetes 배포 이해하기

#### 6.1 이미지 태그 업데이트 메커니즘
**학습 목표**: CI/CD에서 새 이미지로 배포를 트리거하는 방법 이해

**현재 코드** (Jenkinsfile:75-94):
```groovy
stage('Deploy to Kubernetes') {
  steps {
    sh '''
        # IMAGE_REGISTRY/IMAGE_NAME 패턴의 태그를 FINAL_IMAGE_TAG 로 치환
        sed -Ei "s#(image:[[:space:]]*$IMAGE_REGISTRY/$IMAGE_NAME)[^[:space:]]+#\\1:$FINAL_IMAGE_TAG#" ./k8s/deploy.yaml

        kubectl apply -n ${K8S_NAMESPACE} -f ./k8s
        kubectl rollout status -n ${K8S_NAMESPACE} deployment/${IMAGE_NAME}
    '''
  }
}
```

**학습 포인트**:
1. **sed 명령어**: 정규식으로 YAML 파일의 이미지 태그 교체
2. **kubectl apply**: 선언적 배포 (Declarative)
3. **kubectl rollout status**: 배포 완료 대기 (블로킹)
4. **Rolling Update 전략**: 무중단 배포 원리

**문제점**:
- `deploy.yaml` 파일을 직접 수정하므로 Git history가 오염됨
- GitOps 원칙 위배

**개선 방안** (학습 후 적용):
- **Kustomize**: 오버레이 패턴으로 이미지 태그만 변경
- **Helm**: Values를 통한 동적 이미지 태그 주입
- **ArgoCD**: GitOps 방식의 배포 자동화

#### 6.2 Deployment 전략 이해
**현재 설정** (k8s/deploy.yaml):
```yaml
spec:
  replicas: 1
  strategy:
    type: RollingUpdate  # 기본값
    rollingUpdate:
      maxSurge: 1        # 추가로 생성할 수 있는 Pod 수
      maxUnavailable: 0  # 동시에 종료 가능한 Pod 수
```

**학습 포인트**:
- **RollingUpdate**: 점진적 교체 (무중단)
- **Recreate**: 전체 삭제 후 재생성 (다운타임 발생)
- **maxSurge**: 리소스 오버헤드 vs 배포 속도
- **maxUnavailable**: 가용성 vs 배포 속도

**실습 과제**:
1. 배포 중 `kubectl get pods -w` 로 Pod 교체 과정 관찰
2. `kubectl describe deployment` 로 이벤트 확인
3. `kubectl rollout history deployment/<이름>` 로 배포 히스토리 확인
4. `kubectl rollout undo deployment/<이름>` 으로 롤백 실습

---

### Phase 7: 모니터링 및 로깅

#### 7.1 Prometheus 메트릭 수집
**현재 설정** (k8s/deploy.yaml:13-16):
```yaml
annotations:
  prometheus.io/scrape: 'true'
  prometheus.io/port: '8080'
  prometheus.io/path: '/actuator/prometheus'
```

**학습 포인트**:
- Prometheus가 Pod를 자동으로 발견하는 메커니즘 (Service Discovery)
- Spring Boot Actuator의 Prometheus Exporter
- 메트릭 종류: Counter, Gauge, Histogram, Summary

**실습 과제**:
1. `curl http://<pod-ip>:8080/actuator/prometheus` 로 메트릭 확인
2. Prometheus UI에서 쿼리 실습:
   ```promql
   rate(http_server_requests_seconds_count[5m])
   ```

#### 7.2 로그 수집
**학습 목표**: 컨테이너 로그를 중앙화하는 방법 이해

**명령어**:
```bash
# 실시간 로그 확인
kubectl logs -f deployment/sk077-myfirst-api-server -n skala-practice

# 이전 Pod 로그 확인 (재시작 시)
kubectl logs deployment/sk077-myfirst-api-server -n skala-practice --previous
```

**학습 포인트**:
- stdout/stderr를 통한 로그 출력 (12-Factor App 원칙)
- Fluentd/Filebeat를 통한 로그 수집
- ELK Stack / EFK Stack 구조

---

## 체크리스트: 실제 작업 순서

### 1단계: 기본 설정
- [ ] Jenkinsfile의 `GIT_URL` 변경
- [ ] GitHub PAT 생성
- [ ] Jenkins Credential 등록

### 2단계: Kubernetes 인증 설정
- [ ] Harbor Registry Secret 생성
- [ ] ServiceAccount 생성
- [ ] Role 및 RoleBinding 생성

### 3단계: Jenkins Plugin 설정
- [ ] Kubernetes Plugin 설치
- [ ] Cloud 설정 (Kubernetes 연결)
- [ ] ServiceAccount Token을 Jenkins Credential에 등록

### 4단계: Kaniko 적용
- [ ] Jenkinsfile에 Kaniko stage 추가
- [ ] Docker stage 제거 또는 주석 처리
- [ ] 테스트 빌드 실행

### 5단계: 배포 및 검증
- [ ] Kubernetes에 배포 실행
- [ ] Pod 정상 동작 확인
- [ ] Ingress를 통한 서비스 접근 확인
- [ ] Prometheus 메트릭 수집 확인

### 6단계: 문서화
- [ ] 각 단계에서 배운 내용 정리
- [ ] 트러블슈팅 경험 기록
- [ ] 개선 아이디어 메모

---

## 추가 학습 주제

### 고급 주제
1. **GitOps**: ArgoCD를 사용한 선언적 배포
2. **Helm**: 패키지 관리 및 템플릿화
3. **Kustomize**: 오버레이 기반 구성 관리
4. **Multi-stage Dockerfile**: 빌드 최적화
5. **Security Scanning**: Trivy/Clair를 통한 이미지 취약점 스캔

### 성능 최적화
1. Kaniko 캐시 전략
2. Maven 의존성 캐시
3. Parallel Stage 활용
4. Resource Limits/Requests 튜닝

### 장애 대응
1. Liveness/Readiness Probe 설정
2. PodDisruptionBudget 설정
3. HPA (Horizontal Pod Autoscaler) 적용
4. Circuit Breaker 패턴

---

## 참고 자료

### 공식 문서
- [Kaniko Documentation](https://github.com/GoogleContainerTools/kaniko)
- [Jenkins Kubernetes Plugin](https://plugins.jenkins.io/kubernetes/)
- [Kubernetes Best Practices](https://kubernetes.io/docs/concepts/configuration/overview/)

### 학습 순서 권장
1. Docker 기초 → Dockerfile 작성 → 멀티 스테이지 빌드
2. Kubernetes 기초 → Pod → Deployment → Service → Ingress
3. Jenkins 기초 → Pipeline → Groovy 스크립트
4. Kaniko 적용 → Kubernetes Plugin 연동
5. GitOps 도입 (ArgoCD)

---

## 트러블슈팅 가이드

### 자주 발생하는 문제

#### 1. Kaniko Pod가 생성되지 않음
**원인**: ServiceAccount 권한 부족
**해결**:
```bash
kubectl describe pod <kaniko-pod> -n skala-practice
kubectl get rolebinding -n skala-practice
```

#### 2. Harbor 인증 실패
**원인**: Secret이 올바르게 생성되지 않음
**해결**:
```bash
kubectl get secret harbor-registry-secret -n skala-practice -o yaml
# .dockerconfigjson 키 확인
```

#### 3. 이미지 Pull 실패
**원인**: ImagePullSecret이 ServiceAccount에 연결되지 않음
**해결**:
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: default
  namespace: skala-practice
imagePullSecrets:
- name: harbor-registry-secret
```

#### 4. Deployment 업데이트가 반영되지 않음
**원인**: 이미지 태그가 동일하여 Kubernetes가 변경을 감지하지 못함
**해결**: 매번 고유한 태그 사용 (타임스탬프 기반)
```groovy
env.FINAL_IMAGE_TAG = "${IMAGE_TAG}-${hashcode}"
```

---

## 학습 목표 체크

이 가이드를 완료하면 다음을 이해하고 설명할 수 있어야 합니다:

- [ ] Jenkins Pipeline의 동작 원리
- [ ] Docker vs Kaniko의 차이와 장단점
- [ ] Kubernetes RBAC 개념
- [ ] 컨테이너 이미지 빌드 최적화 기법
- [ ] Rolling Update 배포 전략
- [ ] GitOps 원칙과 이점
- [ ] Prometheus 메트릭 수집 메커니즘
- [ ] CI/CD 파이프라인의 각 단계별 역할

**다음 프로젝트에 적용할 수 있는 능력**:
- 새로운 프로젝트에 CI/CD 파이프라인 구축
- 기존 파이프라인 최적화 및 문제 해결
- 보안 및 성능 개선 방안 도출