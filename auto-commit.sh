#!/bin/bash

# 사용법: ./auto_commit.sh <반복횟수>
# 예시:  ./auto_commit.sh 5

if [ $# -ne 1 ]; then
  echo "사용법: $0 <반복횟수>"
  exit 1
fi

COUNT=$1

for i in $(seq 1 $COUNT)
do
  echo "# ${i}번째 commit" >> README.md
  git add README.md
  git commit -m "${i}번째 commit"
done

