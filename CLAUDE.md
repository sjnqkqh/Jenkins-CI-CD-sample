# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 프로젝트 개요

Spring Boot 3.4.3 기반 REST API 애플리케이션입니다. Java 17, JPA, H2/MariaDB를 사용하며, Docker 컨테이너화 및 Jenkins CI/CD를 통한 Kubernetes 배포를 지원합니다.

**메인 애플리케이션 진입점**: `src/main/java/com/skala/springbootsample/HttpRequestJpaApplication.java`

**기본 패키지**: `com.skala.springbootsample`

## 빌드 & 실행 명령어

### 로컬 개발
```bash
# 프로젝트 빌드 (테스트 스킵)
mvn clean package -DskipTests

# H2 데이터베이스로 로컬 실행 (기본 프로파일: local)
mvn spring-boot:run

# 특정 프로파일로 실행
mvn spring-boot:run -Dspring-boot.run.profiles=prod
```

### 테스트
```bash
# 전체 테스트 실행
mvn test

# 특정 테스트 클래스 실행
mvn test -Dtest=SkalaspringbootApplicationTests
```

### Docker 작업
```bash
# Docker 이미지 빌드
./docker-build.sh

# Harbor 레지스트리에 푸시 (docker-push.sh에 인증 정보 필요)
./docker-push.sh
```

### Kubernetes 배포
```bash
# 템플릿에서 YAML 파일 생성 (env.properties 사용)
./gen-yaml.sh

# Kubernetes 매니페스트 적용
kubectl apply -n skala-practice -f ./k8s/

# 배포 상태 확인
kubectl rollout status -n skala-practice deployment/sk077-myfirst-api-server
```

## 아키텍처

### 계층 구조
- **Controllers** (`controller/`): REST 엔드포인트
  - `UserController`: User CRUD 작업
  - `RegionController`: Region 관리
  - `DeveloperInfoController`: 설정에서 개발자 메타데이터 제공
  - `ProbeController`: Health/Readiness 프로브

- **Services** (`service/`): 비즈니스 로직 계층
  - `UserService`: User 관리
  - `RegionService`: Region 작업
  - `LifecycleBean`: 애플리케이션 생명주기 훅

- **Repositories** (`repo/`): JPA 데이터 접근
  - `UserRepository`: User 엔티티 영속성
  - `RegionRepository`: Region 엔티티 영속성

- **Domain** (`domain/`): JPA 엔티티
  - `User`: Region과 ManyToOne 관계를 가진 User 엔티티
  - `Region`: User와 OneToMany 관계를 가진 Region 엔티티

- **DTOs** (`dto/`): 데이터 전송 객체
- **Config** (`config/`): Spring 설정
  - `DataInitializer`: 시작 시 초기 데이터를 시딩하는 CommandLineRunner
  - `DeveloperProperties`: 개발자 메타데이터를 위한 커스텀 `@ConfigurationProperties`

### 데이터베이스 설정

애플리케이션은 Spring 프로파일을 통해 여러 데이터베이스를 지원합니다:

- **local** (기본값): H2 인메모리 데이터베이스
  - 콘솔: http://localhost:8080/h2-console
  - JDBC URL: `jdbc:h2:mem:testdb`
  - 인증 정보: admin/password

- **prod**: 운영 데이터베이스 (`application-prod.yaml`에 설정)
- **mariadb**: MariaDB 설정

프로파일 활성화 방법:
- 로컬: `SPRING_PROFILES_ACTIVE` 환경 변수 설정
- Kubernetes: 배포 매니페스트(`k8s/deploy.yaml`)에 설정

### API 문서 & 모니터링

- **Swagger UI**: http://localhost:8080/swagger/swagger-ui
- **OpenAPI Docs**: http://localhost:8080/swagger/swagger-docs
- **Actuator**: http://localhost:8080/actuator
- **Prometheus Metrics**: http://localhost:8080/actuator/prometheus
- **Liveness**: http://localhost:8080/actuator/health/liveness
- **Readiness**: http://localhost:8080/actuator/health/readiness

## 배포

### Jenkins CI/CD 파이프라인

`Jenkinsfile`이 자동화하는 작업:
1. main 브랜치에서 Git 체크아웃
2. Maven 빌드 (`mvn clean package -DskipTests`)
3. 타임스탬프 기반 고유 태그로 Docker 이미지 빌드
4. Harbor 레지스트리에 푸시 (`amdp-registry.skala-ai.com/skala25a`)
5. 새 이미지 태그로 `k8s/deploy.yaml` 업데이트
6. Kubernetes 네임스페이스 `skala-practice`에 배포
7. 롤아웃 완료 대기

**Jenkinsfile의 주요 환경 변수**:
- `IMAGE_NAME`: sk077-myfirst-api-server
- `K8S_NAMESPACE`: skala-practice
- `IMAGE_REGISTRY`: amdp-registry.skala-ai.com/skala25a

### Kubernetes 매니페스트

`k8s/` 디렉토리에 위치:
- `deploy.yaml`: Prometheus 어노테이션이 포함된 Deployment
- `service.yaml`: Service 설정
- `ingress.yaml`: Ingress 규칙

템플릿 파일(`.t` 확장자)은 `env.properties`의 변수를 사용해 `gen-yaml.sh`로 처리할 수 있습니다.

### Kustomize

`kustomize/`의 대체 배포 방법:
- `base/`: 기본 Kubernetes 리소스
- `overlays/dev/`: 개발 환경 오버레이, replicas, images, 환경 변수 패치 포함

## 중요 사항

- Lombok을 사용하여 보일러플레이트 코드 감소 (getters/setters/constructors)
- 시작 시 `DataInitializer`를 통해 초기 데이터 시딩 (3개 region, 3개 user)
- 기본 포트: 8080 (API 및 Actuator 모두)
- Docker 이미지는 `linux/amd64` 플랫폼용으로 빌드
- `docker-push.sh`의 인증 정보는 secrets 관리로 외부화해야 함

## 학습 목적 프로젝트

**중요**: 이 프로젝트는 CI/CD 프로세스를 빠르게 구성하는 것이 목표가 아니라, **각 단계를 이해하고 추후 응용할 수 있도록 학습하는 것이 목적**입니다.

- Claude에게 요청 시: 단순 구현보다는 각 단계의 원리와 개념 설명을 우선적으로 제공할 것
- 코드 변경 시: 왜 이렇게 하는지, 어떤 원리로 동작하는지 설명 포함
- 트러블슈팅: 문제 해결 방법뿐만 아니라 원인과 메커니즘 설명
- 상세 학습 가이드는 `CI-CD-SETUP-GUIDE.md` 참고