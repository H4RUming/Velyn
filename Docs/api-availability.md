# M0-01 · 설치 SDK 확인

확인일: 2026-09-28. 실제 설치된 헤더·Swift interface와 컴파일 결과를 근거로 기록합니다.

## 환경

| 항목 | 확인 결과 |
| --- | --- |
| Xcode | 27.0, 27A266a |
| Swift | Apple Swift 6.4, swiftlang-6.4.0.34.1 |
| iPhoneOS SDK | 27.0, 24A430 |
| macOS 호스트 | 27.0, 26A428 |
| 연결 가능한 기기 | iPhone 15 Pro (A17 Pro), iOS 27.0 / 24A437, 개발자 모드 활성 |
| 실행 검증 | Mac 엔진 테스트, iPhone 18 Pro / iOS 27 시뮬레이터 시작 화면 |
| 실기기 상태 | 연결과 OS만 조회. 앱 설치·가져오기·성능 측정은 수행하지 않음 |

기기 이름, 일련번호, UDID는 공유용 증거에 넣지 않습니다.

## API 확인표

| API | 설치 SDK 확인 | 현재 검증 범위 |
| --- | --- | --- |
| `GenerateIterativeSegmentationRequest(seedPoint:)` | iOS 27.0+, 결과 `PixelBufferObservation?` | arm64 device 및 arm64/x86_64 simulator 컴파일 |
| `seedBox:`, `seedScribbleBuffer:` | 설치 Vision Swift interface에 존재 | 선언 확인 |
| `addIncludedPoint`, `addExcludedPoint` | throwing 메서드 | 선언 확인 |
| `qualityLevel` | fast / balanced / accurate | balanced 컴파일 |
| `DownloadableAssetsRequest.assetStatus` | async, notReady / downloading / ready / error(Error) | 상태 조회 메서드 컴파일, 실제 모델 상태 미조회 |
| `downloadAssets()` | async throws, progress overload 존재 | 컴파일, 실행·다운로드 안 함 |
| `CIRAWDecoderVersion.version9`, `.version9DNG` | SDK에 존재 | 컴파일. 합성 DNG에서 `9.dng` 지원 조회 |
| `CIRAWFilter.supportedDecoderVersions`, `nativeSize` | 파일별 지원 조회 | 합성 DNG 640×480, 6.dng–9.dng 확인 |
| `CIRAWFilter.downloadResources(timeout:completionHandler:)` | iOS 27.0+ | 헤더 확인, 후속 RAW 현상 단계에서 준비 흐름 필요 |
| Core Image 메모리 옵션 | 헤더 `kCIContextMemoryLimit`, Swift **`CIContextOption.memoryTarget`** | 양 플랫폼 컴파일. `.memoryLimit`는 실제 빌드 실패 |
| ImageIO / CryptoKit / security-scoped URL | 현재 import 서비스 사용 | Mac 통합 테스트 및 iOS 컴파일 |

`SDKCapabilityProbe.swift`는 API 표기 검증용입니다. 가져오기 중 모델을 준비하거나 사진을 분석하지 않습니다. RAW 디코더를 임의 선택하지 않고 파일별 지원 목록만 저장합니다. 실제 디코더 선택·기본 현상 설정 저장은 M1-02에서 구현합니다.

## 증거와 재현

- `Docs/Evidence/simulator-build.txt`: 시뮬레이터 빌드 요약
- `Docs/Evidence/device-build.txt`: 서명 없는 iPhone 아키텍처 빌드 요약
- 전체 로컬 로그: `.work/xcode-build.log`, `.work/device-build.log`

```sh
xcodebuild -project Velyn.xcodeproj -scheme Velyn \
  -destination 'generic/platform=iOS' \
  -derivedDataPath .work/DeviceBuild CODE_SIGNING_ALLOWED=NO build
```

## 후속 실기기 확인

- Xcode에서 개발 팀 지정 후 설치·실행
- Vision 모델 상태, 최초 다운로드, 오프라인 재실행
- 12/48MP ProRAW의 실제 지원 디코더, 필요 자산, nativeSize, 색·방향
- 30장 표본의 이용 권리와 입력 hash 확보
- 저장 공간, 메모리·열·지연 측정

이 항목들이 남아 있으므로 M0-01의 실기기 수락 조건은 완료로 표시하지 않습니다.

## 공식 문서와 설치 인터페이스

- [Vision iterative segmentation](https://developer.apple.com/documentation/vision/generateiterativesegmentationrequest)
- [CIRAWFilter](https://developer.apple.com/documentation/coreimage/cirawfilter)
- 설치 SDK `Vision.framework/Modules/Vision.swiftmodule/arm64e-apple-ios.swiftinterface`, 402–480행
- 설치 SDK `CoreImage.framework/Headers/CIRAWFilter.h`, `CIContext.h`

웹 문서 본문은 이번 도구에서 JavaScript/Markdown 전달 제약으로 읽히지 않았습니다. API 표의 근거는 로컬 설치 SDK와 실제 컴파일입니다.
