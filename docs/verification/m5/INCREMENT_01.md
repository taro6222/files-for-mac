# M5 첫 번째 개발 단위 검증

검증일: 2026-11-13

## 범위

- archive entry를 regular file·directory·symbolic link·hard link·기타로 구분
- 절대 경로, `..`, `.`, 빈 component, `~`, Windows drive, 역슬래시, NUL 차단
- symbolic/hard link 및 특수 항목을 초기 안전 backend에서 거부
- Unicode canonical normalization 뒤 중복 경로 차단
- 항목 수, 단일 파일 크기, 총 비압축 크기와 Int64 overflow 차단
- backend가 추출을 시작하기 전에 사용할 순수 Core validator 제공

## 검증

- 전체 Swift 테스트 및 FilesMac 빌드: 99개 테스트 통과
- 정상 Unicode 디렉터리 트리의 상대 경로 정규화 확인
- 상위/절대/Windows/역슬래시 경로와 링크 거부 확인
- 조합형·완성형 Unicode 중복 경로 거부 확인
- 항목 수·단일 파일·총 크기·합산 overflow 한도 확인

## 남은 항목

- ZIP entry 목록을 descriptor로 변환하는 backend
- staging 추출 후 실제 파일 트리 재검증과 atomic publish
- ZIP 생성·목록·추출 UI
- 7z/RAR capability 결정과 실제 fixture 검증

따라서 M5 완료로 표시하지 않는다.
