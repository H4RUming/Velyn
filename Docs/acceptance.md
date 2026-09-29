# M0 / M1 검증 기록 (초기 단계)

최신 편집 엔진·저장·출력 구현 및 검증은 [편집 기능 기록](editor-features.md)을 참조하세요. 아래 표는 초기 가져오기 단계의 기록입니다.

후속 UI 개편과 탐색용 미리보기 추가 결과는 [UI 변경 기록](ui-redesign.md)을 참조하세요. 아래는 첫 구현 단계의 검증 기록입니다.

2026-09-28 · 기획서 20장에 지정된 첫 작업의 구현·검증 기록입니다. 전체 편집 PoC나 출시 완료를 뜻하지 않습니다.

## 변경과 요구사항

| ID | 산출물 | 판정 |
| --- | --- | --- |
| M0-01 | SDK·OS·연결 기기 확인, API compile spike, 지원표 | 컴파일 확인 완료. 실기기 모델 상태·실행은 남음 |
| M1-01 | 원본 복사, SHA-256, 메타데이터, 취소·오류, 로컬 재열기 | Files 경로 구현. Mac의 JPEG·HEIC·합성 DNG 통과. 실제 ProRAW 미검증 |
| M0-02 | 30장 실사진 표본 | 미확보. 사용자 사진은 사용하지 않음 |
| M1-02 이후 | 기본 현상·프리뷰, PhotoKit 원본 경로, 선택·보정·출력 | 후속 작업 |

## 자동 테스트

실행: macOS 27.0 / 26A428, Xcode 27A266a, Swift 6.4. `swift test --scratch-path .work/swift-build`.

Swift Testing **10개 테스트**, 그중 EXIF 테스트는 **8개 매개변수 케이스**, 실패 0. 모든 이미지가 코드로 생성된 표본입니다.

| 테스트 | 결과 | 의미와 한계 |
| --- | --- | --- |
| JPEG bytes·SHA·형식·방향 1–8 | PASS | 입력 파일 유지, 내부 사본 동일, 가로세로 교환 확인. 실제 픽셀 회전은 M1-02 |
| HEIC 보존 | PASS | 합성 24×16 이미지. 실제 12/24/48MP HEIC는 남음 |
| 합성 DNG 보존 | PASS | CFA 640×480, EXIF 6, DNG 판정·nativeSize·지원 디코더. ProRAW 결과 아님 |
| 손상 파일 | PASS | 잘못된 데이터 거부, 임시 파일·commit 없음 |
| 지원하지 않는 PNG | PASS | 다른 형식으로 위장해도 실제 컨테이너로 거부 |
| 저장 원본 변조 | PASS | 같은 용량의 바이트 변조도 재열기에서 감지 |
| 진행 중 취소 | PASS | 128MiB trailing data로 복사를 진행시켜 취소, staging 제거, 기존 원본 보존 |
| 중단된 staging 복구·백업 제외 | PASS | 임시 작업만 정리, committed package 보존 |
| 실제 파일 읽기 권한 거부 | PASS | 임시 파일 mode 000에서 permissionDenied 반환 |
| 공급자 오류 분류 | PASS | 취소·공간 부족·권한 거부 오류 매핑. 실제 디스크 부족 실험은 아님 |

증거: `Docs/Evidence/engine-tests.txt`. 테스트 전체 원본 로그는 `.work/swift-test.log`.

## 빌드와 화면

- iOS 27 시뮬레이터 arm64 / x86_64: **BUILD SUCCEEDED**.
- iPhone arm64, 서명 없이 컴파일: **BUILD SUCCEEDED**. 실기기 설치를 의미하지 않음.
- iPhone 18 Pro / iOS 27 시뮬레이터: 설치·실행, 시작 화면 확인.
- AppIntents를 사용하지 않는 앱에 대한 metadata extraction 생략 warning만 남음.
- UI 자동 조작 도구가 Device Hub에서 timeout을 반환하여 실제 파일 선택·취소 버튼 UI 흐름은 검증하지 못함. 시작 화면은 simctl screenshot으로 확인.
- 저장 결과·취소·권한 거부는 엔진 통합 테스트로 확인. 파일 공급자의 security scope 만료·iCloud 다운로드 실패, 큰 글자·VoiceOver는 수동 확인 필요.

## 기획서 수락 기준

| 기준 | 현재 상태 |
| --- | --- |
| C01 원본 보존 | 부분 증거 확보: 합성 HEIC·DNG, JPEG. 실제 ProRAW·PhotoKit 원본은 미검증 |
| C02 객체 선택 | 미구현 |
| C03 마스크 정렬 | 미구현. EXIF 메타데이터 단위 검증만 완료 |
| C04 부분 보정 | 미구현 |
| C05 비교·편집 복구 | 미구현. 가져온 원본 재열기만 확인 |
| C06 전체 출력 | 미구현 |
| C07 출력 색·방향·메타데이터 | 미구현 |
| C08 오프라인 편집 완료 | 미검증 |
| C09 A17 Pro 성능 | 미측정 |
| C10 오류·자원 회수 | 가져오기 취소·권한·staging 일부 검증. 실기기 장애 검증은 남음 |

## 다음 구현 단위

1. 실제 ProRAW 12/48MP와 HEIC 표본을 사용해 M1-01 실기기 수락을 확인합니다.
2. PhotoKit 원본 리소스 가져오기를 추가합니다. RAW alternatePhoto를 놓치거나 picker의 JPEG 표현을 원본으로 저장하지 않도록 합니다. `isNetworkAccessAllowed=false`가 기본입니다.
3. M1-02: 프리뷰 긴 변 2048, 파일별 RAW 디코더 선택·기록, 방향·ICC·기본 현상 검증.
4. M2-01: 모델 준비 상태 및 사용자 요청 다운로드, 탭 분할.

초기 구현 순서 이후 사용자가 전문 기능 전체 구현을 요청해 범위를 확장했습니다. 현재 상태는 [전문 편집 검증](Evidence/professional-verification.md)과 [기능 현황](professional-roadmap.md)을 참조합니다.
