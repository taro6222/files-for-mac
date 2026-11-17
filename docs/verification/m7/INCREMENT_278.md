# M7 Increment 278 — SMB 수정이 포함된 설치 프리뷰

앱 소스 `32110faaaf45984bccef450c294b5e4e76418db6`에서 유니버설 프리뷰 0.1.0(1)을 빌드했다. [SMB 시각 보존 수정](INCREMENT_275.md), [게시 전 교차 볼륨 이동 재시도](INCREMENT_272.md)와 [재시도 버튼 회귀](INCREMENT_273.md)의 앱 코드를 포함한다.

로컬 경로는 `build/Files-macOS-preview.dmg`이고 이미지 SHA-256은 `34d58aa5c7d16483e72d9dd17fb401a519af0825ca8a83d192525262caef5a22`다. 이미지 무결성을 검증하고 읽기 전용으로 마운트했다. 앱의 arm64·x86_64 슬라이스와 macOS 14.0 최소 대상, 두 슬라이스의 ad-hoc 서명, 내장 릴리스 노트의 일치를 확인했다. DMG 안에 포함된 실행 파일의 SHA-256은 `dc5d4181868a9ecbfb7c119613eb5523c7f085e82f15048794872ede136024cb`다.

Apple Silicon Sonoma 14.8.7(23J520)에서 같은 이미지 해시를 대조했다. 격리 설치에서 이전 프리뷰 `80c8b68` 실행, 손상된 설치 후보 거부, 새 프리뷰로 교체, 이전 버전 복원을 확인했다. 네 단계에서 설정과 사용자 파일이 보존됐고 이전과 현재 형식의 탭 세션을 복원했다. 두 프리뷰의 표시 버전은 0.1.0(1)이다. [설치·복원 보고서](preview-install-32110fa-sonoma.json)

Launch Services를 통한 arm64 프로세스 20회의 첫 브라우저 창까지 p95 310 ms, 최대 363 ms였다. 공유 OS 캐시에서 측정했다. [기동 보고서](preview-launch-services-32110fa-sonoma.json)

SMB 시각 보존과 게시 후 세션 재연결은 [같은 수정이 포함된 코어의 실마운트 시험](INCREMENT_275.md)에서 통과했다. 이 DMG로 외부 공유에 접속하는 수동 검증과 [전송 중 단절 시험](INCREMENT_277.md)의 실마운트 결과는 별도로 확인한다.
