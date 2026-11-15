# M7 Increment 216 — SMB 복사 수정 시각 진단

[macOS 15 SMB 3.1.1 재시험](https://github.com/taro6222/files-for-mac/actions/runs/43663777956)에서 인증 마운트와 생성·읽기·이름 변경·삭제 사전 검사를 통과했다. 앱의 교차 볼륨 복사는 수정 시각 검증에서 중단됐다. 원본의 데이터가 유지됐고 대상 폴더에 복사본이 게시되지 않았다.

실패 시 실행하는 별도 Foundation 복사 진단에서 경로마다 원본과 복사본의 수정 시각 및 초 단위 차이를 기록한다. 서버에서 발생한 차이의 범위와 항목 유형은 후속 실마운트 시험으로 확인한다.

Apple Silicon에서 `ExternalVolumeTests.swift`를 Swift Testing 매크로와 함께 타입 검사했다. 실마운트 실행은 macOS CI에서 확인한다.
