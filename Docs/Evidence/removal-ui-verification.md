# 요소 지우기 검증

2026-09-29 · Xcode 27 / Swift 6.4. 모든 테스트 입력은 코드로 생성한 합성 표본입니다.

## 변경

- 리터칭 UI를 요소 지우기 하나로 통합. 기존 clone/heal DTO 및 렌더링은 호환성을 위해 유지.
- UIScrollView에서 사진과 선택 표시를 함께 1–8배 확대. 칠하기/선택 지우기/이동, 브러시 크기, 마지막 획 취소, 전체 비우기, 화면 맞춤 제공.
- 선택은 임시 Foundation 값. 드래그는 사진 렌더/신경망 추론을 호출하지 않음. 명시적 실행 때 기존 번들 AOT-GAN을 CPU/GPU로 호출.
- 결과는 한 번의 편집 기록으로 저장. 실패/취소 때 초안 유지. 늦게 도착한 결과는 버리고 새 미확정 파일만 정리. 저장 파일은 스테이징 후 이동.

## 자동 검증

`./Scripts/verify.sh`: **62 tests / 9 suites 통과**, iOS Simulator 빌드 성공. 서명된 iOS Release 빌드 성공.

- 선택 도메인: 칠하기/빼기/획 취소/전체 비우기, 잘못된 좌표, 점 수/획 수 제한.
- Core Image 마스크: 위쪽의 브러시 좌표, 지우개 구멍, 반대편 보존.
- 실제 AOT-GAN 추론: 중앙과 위쪽의 빨간 합성 사각형 제거. 선택 밖 및 지우개로 뺀 픽셀 보존, history undo/redo, 미확정 리소스 삭제 확인.
- iOS 27 Simulator의 전용 합성 사진 라이브러리에서 프로그램으로 UI 흐름 실행. 선택 시 recipe/사진 프레임 갱신 없음, 취소 시 선택/recipe 유지, 실행 성공, 선택 비우기, undo/redo, 저장/재열기 모두 성공. [원시 결과](removal-workflow-2026-09-29.json).

`EditorSmokeFixture.create()`가 생성한 1200×900 색상 차트. `--editor-smoke-test --editor-smoke-removal --editor-smoke-removal-zoom`은 3배 확대 선택 화면, `--editor-smoke-removal-run`을 더하면 취소/실행/저장 검증. 디버그 시뮬레이터에서만 존재하는 진입점입니다.

- [확대·칠하기·선택 지우기 화면](removal-selection-2026-09-29.png)
- [실행 후 화면](removal-result-2026-09-29.png)

## 기기 설치

iPhone 15 Pro에 동일 bundle ID의 서명 Release 빌드 업데이트 설치 및 앱 실행 성공. 설치 로그 `.work/removal-device-install.json`, 실행 로그 `.work/removal-device-launch.json`. 이는 기기에서 모델 품질/성능이나 터치 조작을 검증했다는 뜻은 아닙니다.

## 검증 경계

스크린샷과 자동 흐름은 실제 손가락의 핀치/드래그 테스트가 아닙니다. iPhone 터치 조작성, 실제 사진의 복잡한 배경/머리카락/반복 무늬 품질, 발열/지연 측정은 남아 있습니다. 현재 모델은 2048px 분석본의 선택 crop을 512×512로 추론하는 SDR 모델이며 HDR 하이라이트나 큰 선택에서 품질이 제한됩니다. A17 Pro 성능이나 Lightroom/Retouch 품질 동등성을 주장하지 않습니다.
