# 375 — 압축 편집 창 연결, 원격 UI 수용 대기

ZIP/단일 7z 창에 파일 추가·새 폴더·이름 변경·하위 트리 삭제·현재 창의 편집 Undo를 연결했다. **UI 코드는 빌드했으며 실제 창 표시/조작은 아직 원격 수용 전이다. F23/M7 전체 완료가 아니다.**

## 사용자 동작

툴바와 같은 문맥 메뉴를 제공하고 선택·실행·sheet 상태로 활성 조건을 통일한다. 다중 선택 삭제, Return 이름 변경, 앱의 새 폴더/이름 변경/삭제/Undo 명령을 archive 창의 responder로 연결한다. 일반 탐색 창으로 돌아오면 삭제/Undo 메뉴 제목을 다시 일반 파일 작업 문구로 복원한다. 이름 sheet는 빈 이름·경로 이탈·중복과 같은 이름 변경을 막는다. 삭제는 하위 범위와 보존된 이전 원본을 설명하고 확인받는다.

추가 위치는 선택한 폴더 또는 파일의 부모이며 선택이 없으면 archive root다. 실제 선택한 파일/폴더는 기존 FD 계획·검증·백업/저널 저장 API로 전달한다. 암호가 필요하면 secure sheet를 표시하고 잘못된 암호에는 재입력/취소를 허용한다. 저장/Undo 뒤 목록과 선택·초점을 갱신한다. 실행 중 중복 조작을 막고 중단·창 닫기는 기존 저장의 안전 지점을 따른다. 교체가 끝난 뒤 목록 갱신만 취소/실패한 경우 저장 실패로 오인하지 않는 문구를 표시한다.

보존 파일의 검토가 필요한 오류에는 위치를 남기고 Finder에서 확인하는 명시적 버튼을 제공한다. 모든 복구 기록을 탐색하는 화면·Redo·실패 출력 정리 기능은 아직 연결하지 않았다. 한국어/영어 레이블과 접근성 이름/완료 알림을 추가했으며 실제 VoiceOver 수용은 남아 있다.

형식의 update capability는 ZIP/7z를 true로 바꿨다. 이는 연결된 편집 동작의 가용성을 뜻하며 전체 F23 수용 완료를 뜻하지 않는다. 실제 창은 검증된 SDK·단일 ZIP/7z·읽은 원본의 version이 있을 때만 편집을 활성화한다. RAR/분할 7z/확인할 수 없는 원본은 편집하지 않는다. 포맷 지원 창도 설치된 SDK 확인 후 update 상태를 표시한다. 다른 볼륨/압축 저장 metadata 등에 대한 API 제한은 아직 남아 있다.

## 읽은 목록과 실제 원본 연결

새 `ArchiveEditSourceVersion`은 목록 읽기 전후의 regular file identity·크기·mode·소유자·link 수·flags·mtime/ctime/생성 시각을 비교한다. UI의 변경 요청은 해당 version을 저장 transaction에 전달하고 source FD의 실제 snapshot과 두 번 확인한다. 창을 열어둔 동안 외부에서 다른 archive로 교체되면 이전 경로 선택을 새 데이터에 적용하지 않는다. 그 경우 현재 파일을 보존하고 다시 열어 확인하도록 안내한다.

## 마지막 항목 삭제 후 7z 암호

기존 SDK writer는 database가 비면 header 자체를 생략했다. encrypted-header 7z에서 마지막 항목을 지우면 헤더 암호 상태가 사라져 372의 검증이 이를 거부했다. 원본 SDK pin을 유지하며 `7zOut.cpp`의 빈 database 조건에 password-defined header를 쓰는 경로를 포함시켰다. 기존 encode-header/AES 경로로 빈 header를 기록하며 보이는 가짜 항목을 추가하지 않는다.

이 변경도 이전 두 변경과 함께 SDKChanges v2의 original/modified hash로 고정하고 bundle/runtime 검증과 BUILD.md의 재빌드 안내에 포함한다. 빈 암호 7z의 목록은 암호 없이 열리지 않고, 다시 파일을 추가할 수 있으며 두 번의 Undo로 원래 archive bytes까지 돌아오는 실제 API 검증이 통과했다. 빈 ZIP의 별도 암호 정책 등 나머지 경계 수용은 아직 완료하지 않았다.

## 로컬 검증과 원격 계획

| 범위 | 결과 |
|---|---|
| Debug / Release | 32.83초 / 36.96초 빌드 통과 |
| Swift 클라이언트·번들 | 71개 통과 |
| 실제 격리 helper / 비격리 진단 | 113개 / 205개 통과 |
| native 편집 / OS 권한 probe | 85개 / 15개 통과 |
| 패키지 fixture | 9개 통과 |

빈 암호 7z 삭제·재추가·다중 Undo와 오래된 선택 version 거부, 바뀐 format capability도 headless 검사에 포함했다. Xcode 프로젝트는 새 파일을 포함하도록 재생성했고 같은 결과가 재생성됨을 확인했다. 로컬 Xcode license를 수락하거나 native Xcode build를 실행하지 않았다.

새 원격 AppKit 검증 정의는 편집 가용성/메뉴 라우팅·이름 오류·CRUD/선택·중복/삭제 취소·Undo·암호 재입력/추가/취소·외부 교체 거부의 21개를 추가한다. 총 조건은 332→353개이며 기존 조건을 제거하지 않았다. `archive-edit-invalid-name`, `archive-edit-actions` 캡처를 추가했다. QA 확장과 임시 journal 경로 override는 DEBUG에만 포함한다. 이 정의/컴파일 자체를 해당 검사 통과로 집계하지 않는다.

로컬 GUI·전체 AppKit·장시간 시험 앱은 실행하지 않았다. 이 소스의 push 기본 CI를 중복 실행하지 않도록 [skip ci]로 커밋하고 같은 소스의 양 CPU full AppKit workflow를 한 번 dispatch한다. 원격 결과와 실제 이미지 검토는 별도 수용으로 남긴다. [최종 소스/보고서 기록](archive-ui-375.json).
