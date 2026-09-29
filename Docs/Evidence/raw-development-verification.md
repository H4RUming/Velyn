# RAW 현상 개선 검증

2026-09-29 · Xcode 27 / Swift 6.4.

## 확인한 문제와 변경

기존 RAW 경로는 노출을 CIRAWFilter에 전달하지만 WB는 촬영 시 값으로 고정하고, 일반 색온도/색조는 후처리 CITemperatureAndTint를 사용했습니다. 디코더의 하이라이트 복구 기본값은 지원 표본에서 이미 켜져 있었습니다. 이전 DNG 테스트는 입출력 무결성 검증이며 현상 조절 품질 전체의 증거가 아니었습니다.

- 도구 → RAW 현상. 켈빈 WB/색조, 현상 톤 커브/그림자, 파일별 지원 로컬 톤/노이즈/선명도/디테일/복구/렌즈 보정을 디코더에 연결.
- RAWControls는 지원 여부와 기본값만 담는 Foundation 값. 필터는 EditingService actor가 소유. 모델 자동 다운로드 없음.
- optional RAWAdjustments를 recipe/history에 저장. 기존 설정 없는 recipe의 동작 유지, 프리셋/붙여넣기는 대상의 RAW 설정 유지, 캐시 키에 모든 RAW override 포함.
- PNG 8/16비트 선택. RAW 저장 UI는 PNG 16비트 및 Display P3를 기본으로 제안. 기존 네 가지 저장 포맷 유지.

## SDK 근거

설치된 macOS/iOS 27 SDK `CoreImage.framework/Headers/CIRAWFilter.h`: neutralTemperature 2000–50000 K, neutralTint -150–150, boostAmount 0–1, boostShadowAmount 0–2, 노이즈/로컬 톤의 지원 여부, highlightRecovery iOS/macOS 26 이상. 읽은 헤더의 속성 철자를 Mac 및 iOS 컴파일로 확인했습니다. 런타임 지원 여부에 따라 항목을 표시합니다.

## 통과한 검증

- `./Scripts/verify.sh`: **65 tests / 10 suites**, iOS Simulator build 성공.
- RAWDevelopmentTests: 이전 JSON decode, 유효 범위/boolean/NaN 검증, native filter에 온도/색조/톤이 전달됨, 실제 픽셀 변화, 캐시 초기 결과 복원, undo/redo/저장/재열기, 프리셋 붙여넣기의 RAW 설정 보존.
- ImageFormatTests: PNG 8/16비트 파일 재디코딩 후 실제 bitsPerComponent 확인, 알파와 크기 보존.
- 사용자 DNG를 Mac에서 앱과 같은 엔진으로 처리: native WB 변화/초기화, 전체 5712×4284 JPEG/PNG/HEIC, P3, GPS 제거, 원본 및 원본 내보내기 해시 일치. [수치 보고서](raw-development-report-2026-09-29.json).
- 해당 DNG 지원: WB, 톤, 그림자, 로컬 톤, 밝기 노이즈 감소, 선명도, 하이라이트 복구. RAW 색 노이즈/디테일/렌즈 보정은 지원하지 않아 숨김.
- 실제 파일의 16비트 PNG는 129,685,301 bytes. 8비트보다 정밀하지만 압축률/용량이 크게 달라짐. 16비트가 곧 원시 센서 데이터 또는 HDR 저장이라는 뜻은 아님.
- 서명된 iPhone Release build 및 기존 앱 업데이트 설치 성공. 실행 시도는 기기 잠금(Locked)으로 거부됨. `.work/raw-development-install.json`, `.work/raw-development-launch.json` 참조.

## 통과로 처리하지 않은 항목

시뮬레이터에서 합성 DNG를 가져오고 RAWControls 조회까지 성공했지만 CIRAWFilter outputImage를 얻지 못해 RAW 미리보기가 실패했습니다. RAW UI 전체 흐름 통과로 표시하지 않습니다. 원인이 시뮬레이터 디코더/자산인지 별도 확인이 필요하며 SDK 27 자산 준비 API는 이번 변경에서 자동 호출하지 않았습니다.

실사진 데이터는 저장소에 넣지 않았으며 로컬 `/private/tmp/velyn-raw-development-final/`에만 처리 결과가 있습니다. Mac 실행은 A17 Pro 성능/품질 수락이 아닙니다. 실제 기기 RAW 조작성·미리보기·발열, ProRAW 특징별 검증, 복잡한 장면의 디노이즈/하이라이트 복구 품질은 남아 있습니다. 요소 제거 후 RAW WB/톤을 크게 바꾸는 경우 기존 SDR 패치의 색 일치도 추가 검증이 필요합니다.
