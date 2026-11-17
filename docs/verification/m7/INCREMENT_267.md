# M7 Increment 267 — SMB 재연결 시험의 CI 컴파일 호환성

[교체 이동 재연결 시험](INCREMENT_265.md)의 첫 [실마운트 실행](https://github.com/taro6222/files-for-mac/actions/runs/44078813510)은 Xcode 26.3의 Swift 타입 검사에서 중단됐다. `smbutil statshares`의 출력을 파싱하는 표현식을 행 단위 검사로 바꿨다. 재연결 카운터가 없는 출력은 시험 오류로 처리한다.

로컬 Swift 6 언어 모드에서 통합 시험 다섯 개를 컴파일했고 SMB 전용 환경이 없는 실행에서는 건너뛰었다. 대응표와 패치 검증도 통과했다. CI에서 실제 재연결과 파일 보존을 다시 검증한다.
