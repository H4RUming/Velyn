# 전문 편집 확장 검증

2026-09-28 · Xcode 27A266a / Swift 6.4 / macOS 27 · iOS 27 iPhone 18 Pro Simulator.

## 자동 검증

`./Scripts/verify.sh`: Swift Testing **45개 테스트 / 5개 suite 통과**, iOS Simulator build 성공. 매개변수 케이스는 별도입니다. 전체 로그는 `.work/final-verify.log`, `.work/swift-test.log`, `.work/xcode-build.log`.

주요 검증:

- 원본 SHA·형식·EXIF 1–8·HEIC·합성 CFA DNG·취소 중 staging 정리.
- 이전 문서 읽기·history 직렬화·revision 순서·손상 데이터 보존.
- 선형 노출·색온도 방향·RGB curve 수치·HDR curve extrapolation.
- HSL 변경 시 1 초과 HDR highlight 유지.
- 실제 JPEG/HEIC gain map 존재, TIFF 16bit, 원본 출력 바이트 동일.
- 마스크 좌표·반전·브러시 누적/빼기·복제 opacity·힐링의 양/음 질감.
- 깊이에 따른 선명/흐림 영역 분리.
- 앨범·휴지통 복원·일괄 보정에서 원본 geometry 보존.
- **실제 AOT-GAN 추론**: 합성 빨간 표식을 제거하고 선택 밖 값의 오차 < 0.0001 (선형 RGB), history 복원.
- **실제 Depth Anything V2 추론**: 합성 이미지 → 518×392 depth, focus sample, resource 저장·재열기.

입력은 코드 생성 표본입니다. 생성기 위치: `Tests/VelynEngineTests/` 및 `Velyn/Platform/EditorSmokeFixture.swift`. 실제 사용자 사진은 테스트/증거에 포함하지 않습니다.

## 시뮬레이터 앱 경로

```sh
xcrun simctl launch booted devplaceholder.WLK1NVU6.Velyn --editor-smoke-test --editor-smoke-pro
```

Debug Simulator 전용 분리 저장소 `Application Support/Velyn/EditorSmoke`에서 아래 결과를 기록했습니다.

```json
{"depth":true,"error":"","hdr":true,"history":true,"removal":true,"saved":true,"tiff":true}
```

실제 앱의 EditorStore → EditingService 경로를 실행한 smoke test입니다. 버튼/슬라이더를 사람이 조작한 UI 테스트를 대신하지 않습니다. Device Hub UI 자동화가 timeout을 반환해 터치 동작을 자동 검증하지 못했습니다. 화면은 simctl screenshot으로 확인했습니다.

## 기기 컴파일

`xcodebuild -destination 'generic/platform=iOS' -derivedDataPath .work/DeviceBuild CODE_SIGNING_ALLOWED=NO build`: 성공. 로그 `.work/professional-device-build.log`. iPhone에 설치/촬영했다는 뜻이 아닙니다.

## 남은 실기기 수락

- 12/48MP 실제 ProRAW 디코더, 색·방향·HDR 화면, 출력의 육안 품질.
- Vision 실제 피사체·탭 선택, 모델 준비/취소/오프라인 실행.
- 카메라 RAW/ProRAW, 회전·수동 설정·권한 거부·중단.
- PhotoKit/Files 다중 선택 및 저장 UI, 제한 접근, 디스크 부족.
- A17 Pro 메모리·열·지연, 장시간 반복 편집, 접근성.

기획서 C01–C10 또는 출시 완료 판정을 하지 않습니다. 모델 공개자의 속도 수치나 Mac 테스트 시간을 Velyn의 iPhone 벤치마크로 사용하지 않습니다.

## 화면

[깊이 흐림 화면](professional-depth.png) · [마스크 표시 화면](professional-masks.png). 모두 코드로 만든 합성 색상표입니다.
