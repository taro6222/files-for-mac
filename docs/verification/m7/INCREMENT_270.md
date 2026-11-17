# M7 Increment 270 — macOS 14 Sonoma 설치·기동 검증

Apple Silicon에서 Tart 2.41.1 호스트 전용 네트워크로 macOS 14.8.7 (23J520) 게스트를 실행했다. Sonoma 이미지의 OCI digest는 `sha256:e2ebdfc4d354b336fe00d729c11a8136a019b8046f41cc183a2fe51b85d18f49`다. [Sonoma 이미지 소스](https://github.com/cirruslabs/macos-image-templates/pkgs/container/macos-sonoma-base)

앱 소스 `80c8b680241da59cd675720e7cfea384daf2da60`으로 유니버설 프리뷰를 제작했다. 이미지 SHA-256은 `b65580ae06e8c2c16be522c110c7d5a9dc8af09a4e2638e2f45a4fc4297049e0`이다. 같은 해시의 이미지를 게스트에서 읽기 전용으로 마운트하고 두 슬라이스의 서명을 확인했다. 격리된 테스트 앱으로 설치, 손상된 교체본 거부, 새 앱 교체와 이전 앱 복원을 검증했다. 기존 앱 설정과 사용자 파일이 보존됐고 두 세션 형식의 창 상태를 복원했다. [설치·복원 결과](preview-install-80c8b68-sonoma.json)

실제 arm64 프로세스로 직접 실행과 Launch Services 기동을 각각 20회 수행했다. 공유 OS 캐시 조건에서 직접 실행의 창 표시 p95는 363 ms, Launch Services의 창 표시 p95는 279 ms였다. 검증에 사용한 같은 창 관측 코드와 macOS 14.0 대상 바이너리를 게스트에 전달했다. [직접 기동](preview-startup-80c8b68-sonoma.json) · [Launch Services 기동](preview-launch-services-80c8b68-sonoma.json)

같은 앱 코드의 디버그 AppKit 빌드로 한국어·영어와 밝은·어두운 테마 네 조합의 파일 작업 검사 78개씩 통과했다. 게스트로 전달한 시험 바이너리의 SHA-256을 호스트 빌드와 대조했다. 영어·밝은 테마의 전체 AppKit 검사도 281개 모두 통과했다. 첫 전체 시험에서 Git 입력 저장소를 준비했고, 콘텐츠 검색 두 건의 재검증을 위해 게스트의 Data 볼륨 인덱싱을 켜고 실제 검색 결과가 등록된 뒤 재실행했다.

Sonoma의 초기 14.x 버전, Sonoma Intel, 전체 VoiceOver 탐색과 정식 서명·공증 후 다운로드 설치는 별도로 검증한다.
