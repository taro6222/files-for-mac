# M7 Increment 78 — 인덱싱된 위치 전체 검색

Spotlight 콘텐츠 검색의 범위 메뉴에 **모든 인덱싱된 위치**를 추가했다. 이 범위에서는 현재 폴더 밖의 결과도 표시한다. 로컬 볼륨과 홈 디렉터리, 사용자에게 마운트된 네트워크 볼륨의 Spotlight 인덱스를 조회한다. 이름을 직접 열거하는 방법으로 돌아가면 선택 범위를 하위 폴더 포함으로 되돌린다. [Apple Foundation의 검색 범위](https://developer.apple.com/documentation/foundation/nsmetadataquerylocalcomputerscope)

현재 폴더와 하위 폴더 검색은 각각 상위 경로 및 경로 구분자를 확인한다. 루트 볼륨의 하위 범위도 처리한다. 기존 파일 종류, 숨김, 태그, 크기, 수정일 필터는 전체 범위에도 적용된다.

실제 인덱스 검사는 임시 폴더에서 시작해 작업공간의 `LocalSearch.swift`가 본문 검색에 반환되는지 전체 경로로 확인한다. 같은 창을 파일 이름 검색으로 바꾼 뒤 폴더 범위가 복원되는지도 확인한다. 인덱싱된 원격 볼륨에서의 검색은 별도 환경 검증 항목이다.

Apple Silicon macOS 27.2에서 Swift 테스트 213개와 한국어·영어 × 밝게·어둡게의 AppKit 검사 각각 228개를 통과했다. 이 환경에서 자동으로 로드되지 않은 Swift Testing 매크로는 설치된 Command Line Tools 라이브러리를 직접 지정해 실행했다.
