# 실제 DNG 파일 엔진 검증

2026-09-29. 사용자가 명시적으로 제공한 DNG 1개를 로컬 macOS에서 Velyn 엔진으로 처리했습니다. 실사진과 파생 이미지는 저장소에 넣지 않았습니다. 사진 파일은 업로드하지 않았습니다.

## 표본과 환경

- ImageIO 카메라 메타데이터: iPhone 15 Pro. DNG, 26,499,319 bytes, 5712×4284, 방향 1. `sips`의 bitsPerSample은 16.
- CIRAWFilter 지원 decoder: 6.dng / 7.dng / 8.dng / 9.dng. 앱과 같은 마지막 지원 decoder 선택 경로 사용.
- 실행은 Mac의 CLI이며 아이폰/시뮬레이터에서 실행하지 않았습니다. 실제 DNG 디코딩 증거이며 Apple ProRAW 특성 전체 검증이나 C01–C10 수락 통과를 의미하지 않습니다.

## 결과

- RAW 인식, 가져온 복사본의 SHA-256 일치, RAW 현상 설정 생성 성공.
- 1536px 미리보기, 노출 -1/0/+1 EV의 픽셀 밝기 증가 확인.
- 노출·하이라이트·그림자·색온도·P3 색역 확장 보정 경로 실행. 기본/보정 미리보기 직접 확인.
- undo/redo, 저장 후 새 서비스로 재열기 일치.
- JPEG / PNG / HEIC 모두 전체 5712×4284, Display P3, GPS 없음, 출력 재디코딩 성공. JPEG/HEIC 품질 설정 0.92, SDR 출력.
- JPEG 3,859,121 bytes / PNG 33,921,831 bytes / HEIC 4,979,775 bytes. 용량 순서는 표본과 인코더에 따라 달라집니다.
- 입력 원본·내부 복사본·원본 내보내기의 SHA-256 일치. 입력 원본 변경 없음.

[수치 결과](raw-file-report-2026-09-29.json). 기록된 시간은 단일 Mac 실행값이며 기기 벤치마크가 아닙니다.

## 재실행

`Scripts/check-raw.swift`를 `Velyn/Engine`의 Swift 소스들과 함께 `xcrun swiftc -parse-as-library -O`로 컴파일합니다. 생성한 실행 파일에 입력 DNG와 저장소 밖 출력 디렉터리 두 인자를 전달합니다. 개인 사진 경로는 코드에 고정하지 않습니다. 이번 결과는 `/private/tmp/velyn-raw-2209/`에 있으며 OS가 임시 파일을 정리할 수 있습니다.

자동 회귀 테스트 수는 기존 62개로 유지됩니다. 이번 스크립트는 명시적으로 실행하는 실사진 검사이고, 개인 사진을 테스트 fixture로 추가하지 않습니다.
