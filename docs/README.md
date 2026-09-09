# Files macOS 개발 문서

작성일: 2026-09-09 · 상태: M0/M1 개발 진행 중

개발 저장소: [taro6222/files-for-mac](https://github.com/taro6222/files-for-mac)

원본 참고 저장소: [files-community/Files](https://github.com/files-community/Files)

목표는 Files의 기능과 UI를 macOS에서 충실하게 구현하는 독립 데스크톱 파일 관리자다. 첫 실행 화면만 구현한 시제품을 최종 결과로 취급하지 않는다.

## 문서 순서

1. [제품·UI·기술 설계](MACOS_DESIGN.md): 제품 범위, 화면과 상호작용, 아키텍처, 파일 작업, 배포 설계.
2. [기능 대응 및 개발 계획](FEATURE_PARITY_AND_PLAN.md): 기능 ID, Windows 대응, 단계별 산출물, 원본 전수 조사 절차.
3. [검증·출시 기준](VALIDATION_AND_RELEASE.md): 기능·시각·데이터 무결성·성능 검사와 최종 완료 조건.

## 설계 해석 규칙

- 이 문서는 개발 요구사항이다. 구현·테스트·원본 전체 대조가 이미 완료되었다는 의미가 아니다.
- 원본에서 확인한 사실에는 출처를 붙인다. 수치, 구성, 기본값은 별도 표시가 없으면 맥 앱을 위한 설계 결정이다.
- `M0`에서 원본 릴리스와 커밋을 고정하고 모든 명령·설정·화면을 전수 대응한다. 미확인 항목을 누락시키거나 지원 완료로 표시하지 않는다.
- 중간 마일스톤은 개발 순서이며 최종 범위 축소가 아니다. 플랫폼 차이는 대응표에 남기고, 사용자 기대를 바꾸는 축소는 별도 결정으로 기록한다.
- macOS 고유 창 장식·폰트·권한 화면과 Windows 전용 기능의 대응에는 차이가 있다. 이를 숨긴 채 '원본과 100% 동일'이라고 표현하지 않는다.

개발 진행: [현황](DEVELOPMENT_STATUS.md), [M0 기준](reference/BASELINE.md), [M1 검증](verification/m1/REPORT.md)
