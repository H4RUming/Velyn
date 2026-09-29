# README 이미지와 재현

2026-09-29. 이 폴더의 사진은 공개 소개용 합성 자료입니다. 실제 사용자 사진은 없습니다.

## 출처

- 앱 아이콘: `Velyn/Assets.xcassets/AppIcon.appiconset/AppIcon.png`. 기존 Velyn 아이콘을 그대로 사용했습니다. [생성 기록](../app-icon.md).
- `sample-alpine.png`: OpenAI 이미지 생성 도구로 만든 1536×1024 SDR 합성 사진. 카메라 촬영물이나 RAW 검증 표본이 아닙니다. 소스 SHA-256은 `report.json`에 기록합니다.
- `alpine-before.jpg`, `alpine-after.jpg`: 같은 입력을 Velyn의 실제 `EditingService.export`로 출력했습니다. 후처리로 보정 효과를 꾸며내지 않았습니다.
- `alpine-hdr.jpg`, `alpine-hdr.heic`: 번들 GMNet으로 밝기 지도를 예측하고 실제 앱 엔진으로 HDR gain map을 포함해 저장한 파일입니다.
- `app-*.png`: iOS 27 Simulator의 실제 Velyn 화면입니다. 위 합성 입력과 엔진에서 저장한 보정 이력을 로드했습니다. 상태 표시줄 시간은 simctl로 9:41로 고정했습니다. HDR 화면의 스크린샷은 물리적인 HDR 밝기의 증거가 아닙니다.
- 앱 아이콘·합성 샘플·이로부터 생성한 README 이미지는 저장소의 MIT 라이선스로 제공하며, 적용 가능한 권리 범위에서 사용을 허용합니다. 포함된 모델에는 각 원래 라이선스가 적용됩니다.

## 실행

macOS, Xcode 27 / Swift 6.4에서 실행했습니다. 처리 시간이나 화면 결과를 A17 Pro 실기기 검증으로 간주하지 않습니다. 모델은 로컬에서 컴파일·추론하며 사진을 업로드하지 않습니다.

새 출력 디렉터리를 사용합니다. 스크립트는 생성한 프로젝트와 중간 문서도 보관하므로 `.work/` 아래를 권장합니다.

```sh
mkdir -p .work
swiftc -O -parse-as-library \
  $(find Velyn/Engine -name '*.swift' -print) \
  Scripts/make-readme-examples.swift -o .work/readme-examples

.work/readme-examples \
  Docs/Images/sample-alpine.png \
  .work/readme-examples-output \
  Velyn/Models/VelynGainMap.mlpackage
```

`report.json`에 실제 보정 값, 출력 크기, gain map 존재 여부, 원본 보존, 실행 환경을 기록합니다. 예제 재실행 시 UUID·파일 용량·부동소수점 수치가 달라질 수 있습니다.

## HDR의 웹 표시

`hdr-reference-sdr.jpg`와 `hdr-reference-hdr.jpg`는 SDR와 HDR 선형 출력에 **동일하게 −2 EV**를 적용한 설명용 이미지입니다. 디스플레이의 실제 HDR/SDR 비교 화면이 아닙니다. 정규화된 밝기 차이를 일반 웹 화면에서 읽을 수 있도록 만든 것입니다.

`hdr-applied-gain.png`는 실제 처리된 HDR/SDR RGB 합의 비율을 계산해 `log2(gain) / 2`로 표시합니다. 검정은 1×, 흰색은 4×입니다. 중간톤 보호까지 적용된 배율이며 원시 모델 출력과 구분됩니다.

HDR 예제 파일에는 gain map이 존재함을 ImageIO로 확인했습니다. 다시 HDR로 디코딩한 256×170 표본의 최대 RGB 채널 값은 JPEG 2.3613×, HEIC 2.3574×였습니다. README 수치의 최대 RGB 값과 화면의 EDR 여유는 다른 측정량입니다. 샘플의 최대 적용 배율은 약 2.44×이며, 256px 표본에서 최대 RGB 값은 약 2.39×입니다. 실제 표시 결과는 기기·뷰어·화면 밝기에 따라 달라집니다.

## 입력 생성 프롬프트

> Use case: photorealistic-natural. Asset type: synthetic sample photograph for an open-source iPhone photo editor README, used as INPUT for actual code-based photo editing and HDR gain-map demonstrations. Generate a single realistic landscape photograph, landscape 3:2 composition, 1536x1024 if possible. Quiet alpine lake at dawn, small weathered dark timber cabin on the left bank, tall fir trees, layered mountains in the background, softly illuminated clouds with a small bright sun just above the ridge, fine silver-gold highlights reflected across rippling water, detailed stones and grasses in the foreground. Natural camera rendering, subtly cool white balance, slightly subdued saturation and underexposed shadow detail that remains visible and can be lifted in editing. Rich but restrained realistic texture, no dramatic baked-in color grading or excessive HDR effect, no clipped large white sky regions. The photo should feel coherent and usable as an unedited SDR sample. No humans, no trademarks, no text, no borders, no labels, no split view, no comparison, no UI.
