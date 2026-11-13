# M5 스무 번째 개발 단위 검증

검증일: 2026-11-14

## 범위

- FTP/FTPS 원격 파일을 최종 대상과 같은 디렉터리의 무작위 숨김 staging 파일로 다운로드
- curl 성공 후 staging이 일반 파일이며 심볼릭 링크가 아닌지 재검증
- staging 이름·확장자·부모 디렉터리를 검증해 임의 파일 publish 차단
- 기존 대상은 교체하지 않고 경합 시 `destinationExists` 반환
- 같은 볼륨 rename으로 최종 이름에 원자 publish
- 성공·실패·Task 취소 모든 경로에서 남은 staging 제거

## 검증

- Unicode 최종 이름으로 staging publish 후 내용 동일성과 staging 소멸 확인
- 기존 대상에 대한 publish 거부, 기존·staging 내용 모두 보존 확인
- 심볼릭 링크 staging, 다른 디렉터리 staging, missing staging 거부 확인
- 전체 Swift Testing 125개 통과
- 한국어/영어 × 라이트/다크 UI 4조합 전체 회귀 통과

## 남은 항목

- 실제 FTP/FTPS 서버에서 대용량·취소·네트워크 단절 다운로드 수용 검증
- 다운로드 byte progress와 재개 capability
- 원격 staging 업로드·rename publish·실패 cleanup

따라서 M5 원격 연결 영역 완료로 표시하지 않는다.
