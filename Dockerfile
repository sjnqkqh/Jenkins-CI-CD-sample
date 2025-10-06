# ========================================
# Stage 1: Build Stage
# Maven을 사용하여 애플리케이션 빌드
# ========================================
FROM maven:3.9-eclipse-temurin-17 AS builder

# 작업 디렉토리 설정
WORKDIR /build

# pom.xml을 먼저 복사하여 의존성 캐싱 최적화
COPY pom.xml .

# 의존성 다운로드 (레이어 캐싱을 위해 소스 코드 복사 전에 실행)
RUN mvn dependency:go-offline -B

# 소스 코드 복사
COPY src ./src

# 애플리케이션 빌드 (테스트 스킵)
RUN mvn clean package -DskipTests -B

# ========================================
# Stage 2: Runtime Stage
# 빌드된 JAR 파일만을 포함한 경량 이미지 생성
# ========================================
FROM eclipse-temurin:17-jre-alpine

# 작업 디렉토리 설정
WORKDIR /app

# 애플리케이션 포트 노출
EXPOSE 8080
EXPOSE 8081

# 빌드 스테이지에서 생성된 JAR 파일 복사
COPY --from=builder /build/target/spring-boot-app-0.0.1-SNAPSHOT.jar app.jar

# 비특권 사용자로 실행 (보안 강화)
RUN addgroup --system spring && adduser --system --ingroup spring spring
USER spring:spring

# Health check (K8s probes를 위해 선택적)
HEALTHCHECK --interval=30s --timeout=3s --start-period=40s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:8080/actuator/health || exit 1

# 애플리케이션 실행
# - JVM 메모리 최적화 옵션 포함
# - 컨테이너 환경 인식 활성화
ENTRYPOINT ["java", \
    "-XX:+UseContainerSupport", \
    "-XX:MaxRAMPercentage=75.0", \
    "-Djava.security.egd=file:/dev/./urandom", \
    "-jar", \
    "app.jar"]