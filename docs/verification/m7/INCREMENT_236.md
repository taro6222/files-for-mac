# M7 Increment 236 — Windows 탭 드롭 시험의 실행 권한

[원본 Windows 실행](https://github.com/taro6222/files-for-mac/actions/runs/43669168609)에서 포인터가 원본 탭에서 오른쪽 패널로 이동했다. Files와 입력 스크립트 모두 관리자 권한으로 실행되었고, 탭은 이동하지 않았다. [원본 권한 검사](https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Services/Windows/WindowsSecurityService.cs)는 관리자 권한일 때 드래그 앤 드롭을 비활성화한다.

탭 드롭 전용 실행은 임시 작업 스케줄러 작업을 현재 사용자의 대화형 세션과 제한된 실행 수준으로 등록한다. 실행 작업은 관리자 권한 여부를 확인하고 [Windows 패키지 활성화 API](https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nn-shobjidl_core-iapplicationactivationmanager)로 설치된 패키지를 열어 결과 JSON을 남긴다. 캡처 스크립트도 포인터를 움직이기 전에 Files 프로세스의 실제 권한을 확인한다.

로컬에서 Python 문법, YAML 연결, 대응표를 검사했다. [Windows 재시험](https://github.com/taro6222/files-for-mac/actions/runs/43670687792)에서 임시 작업은 시작됐고, 실제 실행 토큰의 관리자 그룹 검사를 통과하지 못해 패키지 활성화 전에 중단됐다. 일반 권한으로 활성화된 Windows 앱에서 탭 드롭을 검증해야 한다.
