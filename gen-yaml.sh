#!/bin/bash

# 템플릿 변수 치환 스크립트
# env.properties 파일의 KEY=VALUE를 사용하여 .t 파일들의 ${KEY} 형태 변수를 치환
# macOS와 Ubuntu 모두 호환

set -e  # 에러 발생 시 스크립트 종료

# 색상 코드 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

TEMP_FILE=$(mktemp)
ERROR_COUNT=0

# 인수 파싱
DIRECTORY_PATH=""
COMMAND="create"

# 첫 번째 인수 분석
if [ $# -eq 0 ]; then
    DIRECTORY_PATH="."
    COMMAND="create"
elif [ $# -eq 1 ]; then
    if [[ "$1" == "." || "$1" == ".." || "$1" == "../" ]]; then
        DIRECTORY_PATH="$1"
        COMMAND="create"
    elif [[ "$1" == "create" || "$1" == "delete" || "$1" == "help" ]]; then
        DIRECTORY_PATH="."
        COMMAND="$1"
    else
        echo -e "${RED}오류: 잘못된 인수입니다: $1${NC}"
        exit 1
    fi
elif [ $# -eq 2 ]; then
    DIRECTORY_PATH="$1"
    COMMAND="$2"
else
    echo -e "${RED}오류: 너무 많은 인수입니다.${NC}"
    exit 1
fi

# 경로 정규화
case "$DIRECTORY_PATH" in
    "."|"")
        DIRECTORY_PATH="."
        ;;
    ".."|"../")
        DIRECTORY_PATH=".."
        ;;
    *)
        echo -e "${RED}오류: 지원하지 않는 경로입니다: $DIRECTORY_PATH${NC}"
        exit 1
        ;;
esac

# env.properties 파일 경로 설정
PROPERTIES_FILE="$DIRECTORY_PATH/env.properties"

# 사용법 표시 함수
show_usage() {
    echo -e "${BLUE}사용법:${NC}"
    echo -e "  $0 [경로] [명령어]"
    echo ""
    echo -e "${BLUE}예시:${NC}"
    echo -e "  $0                    # 현재 디렉토리, create"
    echo -e "  $0 . create           # 현재 디렉토리, create"
    echo -e "  $0 .. delete          # 상위 디렉토리, delete"
}

# 명령어 검증
case "$COMMAND" in
    create|delete|help)
        ;;
    *)
        echo -e "${RED}오류: 잘못된 명령어입니다: $COMMAND${NC}"
        show_usage
        exit 1
        ;;
esac

if [ "$COMMAND" = "help" ]; then
    show_usage
    exit 0
fi

echo -e "${GREEN}=== 템플릿 스크립트 ($COMMAND 모드, 경로: $DIRECTORY_PATH) ===${NC}"

# .t 확장자 파일들 찾기 (macOS/Ubuntu 호환 방식)
echo -e "${YELLOW}1. $DIRECTORY_PATH 에서 .t 확장자 파일 검색 중...${NC}"

# 방법 1: 배열에 직접 할당 (macOS와 Ubuntu 모두 지원)
template_files_array=()
while IFS= read -r file; do
    template_files_array+=("$file")
done < <(find "$DIRECTORY_PATH" -name "*.t" -type f 2>/dev/null)

# 또는 방법 2: IFS를 사용한 방식 (더 간단하지만 파일명에 공백이 있으면 문제)
# IFS=$'\n'
# template_files_array=($(find "$DIRECTORY_PATH" -name "*.t" -type f 2>/dev/null))
# unset IFS

if [ ${#template_files_array[@]} -eq 0 ]; then
    echo -e "${RED}오류: $DIRECTORY_PATH 에서 .t 확장자 파일을 찾을 수 없습니다.${NC}"
    exit 1
fi

echo -e "${GREEN}발견된 템플릿 파일 개수: ${#template_files_array[@]}${NC}"
for file in "${template_files_array[@]}"; do
    echo "  - $file"
done

# DELETE 모드 처리
if [ "$COMMAND" = "delete" ]; then
    echo -e "${YELLOW}2. YAML 파일 삭제 중...${NC}"

    for file in "${template_files_array[@]}"; do
        if [ -f "$file" ]; then
            yaml_file="${file%.t}.yaml"
            if [ -f "$yaml_file" ]; then
                rm -f "$yaml_file"
                echo -e "${GREEN}   삭제됨: $yaml_file${NC}"
            fi
        fi
    done

    echo -e "${GREEN}=== YAML 파일 삭제 완료 ===${NC}"
    rm -f "$TEMP_FILE"
    exit 0
fi

# CREATE 모드 - env.properties 파일 확인
if [ ! -f "$PROPERTIES_FILE" ]; then
    echo -e "${RED}오류: $PROPERTIES_FILE 파일을 찾을 수 없습니다.${NC}"
    exit 1
fi

echo -e "${YELLOW}2. $PROPERTIES_FILE 파일에서 변수 로드 중...${NC}"

# properties 파일 로드를 위한 임시 파일
VARS_FILE=$(mktemp)

# properties 파일을 읽고 변수 저장
while IFS= read -r line || [[ -n "$line" ]]; do
    # Windows CR 문자 제거 (WSL 호환)
    line="${line//$'\r'/}"

    # 주석이나 빈 줄 건너뛰기
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" != *"="* ]] && continue

    # key=value 분리 (macOS와 Ubuntu 모두 호환)
    key=$(echo "$line" | cut -d '=' -f 1 | xargs)
    value=$(echo "$line" | cut -d '=' -f 2- | xargs)

    # 따옴표 제거 (더 간단한 방식)
    value="${value#\"}"
    value="${value%\"}"
    value="${value#\'}"
    value="${value%\'}"

    # 유효한 key-value만 저장
    if [[ -n "$key" && -n "$value" ]]; then
        echo "$key=$value" >> "$VARS_FILE"
        echo "  - $key = $value"
    fi
done < "$PROPERTIES_FILE"

# HASHCODE 자동 생성
GENERATED_HASHCODE=$(date +%s | shasum | cut -c1-8)  # macOS는 shasum 사용
echo "HASHCODE=$GENERATED_HASHCODE" >> "$VARS_FILE"
echo "  - HASHCODE = $GENERATED_HASHCODE (자동 생성)"

echo -e "${GREEN}변수 로드 완료${NC}"

# 변수가 제대로 로드되었는지 확인 (파일이 비어있지 않은지만 체크)
if [[ ! -s "$VARS_FILE" ]]; then
    echo -e "${RED}오류: properties 파일에서 변수를 로드하지 못했습니다.${NC}"
    echo -e "${YELLOW}파일 내용 확인:${NC}"
    cat "$PROPERTIES_FILE" | head -10
    rm -f "$TEMP_FILE" "$VARS_FILE"
    exit 1
fi

echo -e "${YELLOW}3. 템플릿 파일 처리 중...${NC}"

# 함수: 파일에서 모든 ${변수명} 패턴 추출
extract_variables() {
    local file="$1"
    grep -o '\${[A-Za-z_][A-Za-z0-9_]*}' "$file" 2>/dev/null | sed 's/\${//;s/}//' | sort -u
}

# 함수: 변수 값 가져오기
get_variable_value() {
    local var_name="$1"
    grep "^$var_name=" "$VARS_FILE" 2>/dev/null | cut -d'=' -f2-
}

# 함수: 변수 확인
check_variables() {
    local file="$1"
    local missing_vars=()
    local vars=$(extract_variables "$file")

    if [ -n "$vars" ]; then
        echo "  검증 중: $(basename "$file")"
        for var in $vars; do
            local value=$(get_variable_value "$var")
            if [ -z "$value" ]; then
                missing_vars+=("$var")
                echo -e "    ${RED} \${$var} - 정의되지 않음${NC}"
                ((ERROR_COUNT++))
            fi
        done

        if [ ${#missing_vars[@]} -gt 0 ]; then
            return 1
        fi
    fi
    return 0
}

# 함수: 파일의 변수 치환
replace_variables() {
    local file="$1"
    local output_file="${file%.t}.yaml"

    # 파일 복사 (CR 제거)
    tr -d '\r' < "$file" > "$TEMP_FILE"

    # 변수 치환
    while IFS='=' read -r key value; do
        if [[ -n "$key" && -n "$value" ]]; then
            # 특수문자 이스케이프 (macOS sed 호환)
            escaped_value=$(printf '%s\n' "$value" | sed 's/[[\.*^$()+?{\\]/\\&/g')

            # macOS와 Linux 모두 호환되는 sed 사용
            if [[ "$OSTYPE" == "darwin"* ]]; then
                # macOS
                sed -i '' "s|\${$key}|$escaped_value|g" "$TEMP_FILE"
            else
                # Linux
                sed -i "s|\${$key}|$escaped_value|g" "$TEMP_FILE"
            fi
        fi
    done < "$VARS_FILE"

    # 결과 저장
    cp "$TEMP_FILE" "$output_file"
    echo -e "${GREEN}   $(basename "$file") -> $(basename "$output_file")${NC}"
}

# 변수 검증
echo -e "${YELLOW}변수 검증 중...${NC}"
for file in "${template_files_array[@]}"; do
    if [ -f "$file" ]; then
        check_variables "$file"
    fi
done

# 오류 확인
if [ $ERROR_COUNT -gt 0 ]; then
    echo -e "${RED}오류: 총 $ERROR_COUNT 개의 정의되지 않은 변수가 발견되었습니다.${NC}"
    rm -f "$TEMP_FILE" "$VARS_FILE"
    exit 1
fi

# 변수 치환 수행
echo -e "${YELLOW}변수 치환 수행 중...${NC}"
for file in "${template_files_array[@]}"; do
    if [ -f "$file" ]; then
        replace_variables "$file"
    fi
done

# 정리
rm -f "$TEMP_FILE" "$VARS_FILE"

echo -e "${GREEN}=== 템플릿 YAML 파일 생성 완료 ===${NC}"
echo -e "${GREEN}${#template_files_array[@]}개의 .t 파일이 성공적으로 .yaml 파일로 변환되었습니다.${NC}"
