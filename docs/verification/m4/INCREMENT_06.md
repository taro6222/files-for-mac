# M4 여섯 번째 개발 단위 검증

검증일: 2026-11-13

## 범위

- Space 키와 파일 메뉴의 macOS 네이티브 `QLPreviewPanel`
- 현재 보기의 단일·다중 선택 URL datasource
- 패널 내 선택 항목 전환을 위한 전체 preview 항목 제공
- 패널 종료 시 datasource·delegate 해제와 선택 URL 정리
- Swift 6 MainActor와 Objective-C Quick Look datasource의 `@preconcurrency` 경계

## 자동 및 실제 UI 검증

전체 Swift 테스트 및 FilesMac 빌드 결과: 91개 테스트 통과. `DEVELOPER_DIR=/Library/Developer/CommandLineTools scripts/verify-ui.sh` 결과 한국어/영어 × 밝게/어둡게 네 조합에서 `quickLookWindow`, `quickLookItems`를 포함한 모든 검사가 `true`였다.

각 조합의 `quick-look.png`를 생성하고 한국어 다크 화면에서 네이티브 패널, 선택 파일 제목, 닫기 컨트롤을 직접 확인했다. 현재 자동 검증 환경에서는 Quick Look 확장 렌더링 영역이 빈 상태로 캡처되어 텍스트 본문 렌더 완료를 통과로 주장하지 않는다.

## 남은 항목

- 실제 사용자 세션에서 텍스트·이미지·PDF·영상 preview 렌더 확인
- 손상·암호화·미지원 포맷의 오류 격리와 앱 응답성
- preview 중 선택 변경 동기화
- 폴더·package와 네트워크 파일의 로딩·취소 동작

따라서 M4 완료로 표시하지 않는다.
