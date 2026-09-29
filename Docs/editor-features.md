# 편집 엔진과 저장 계약

2026-09-29. 현재 기능 목록 및 미구현 항목은 [기능 현황](professional-roadmap.md)을 참조합니다.

## 서비스 경계

- Foundation/Codable/Sendable: EditRecipe, AdvancedEdits, LocalMask, MaskStroke, RemovalPatch, DepthEffect, EditHistory, EditVersion, LibraryCatalog.
- EditingService actor: 원본 검증, 현상, 렌더, 히스토그램/WB, Vision/Core ML 추론, 리소스/버전/출력 저장.
- LibraryService actor: 앨범/별점/선별/휴지통, 로컬 분류, 보정 붙여넣기, 순차 출력.
- CameraService actor: AVCaptureSession 구성·수동 설정·촬영. 원본 fileDataRepresentation을 보관.
- EditorStore/LibraryOrganizer/ImportStore: MainActor UI 상태, 작업 취소, 오래된 결과 무시.

렌더는 한 번에 하나씩 처리하고 다음 요청은 최신 값 하나만 유지합니다. 드래그 중 렌더 시작 간격을 최소 33.334ms로 제한해 최대 초당 30회만 처리합니다. 새 입력은 대기 시간을 다시 시작하지 않으며 손을 떼거나 원본 비교/undo를 요청하면 대기를 취소하고 정밀 렌더로 넘어갑니다. 입력이 없으면 반복 렌더하지 않습니다. 조작 중 768px, 종료/180ms 대기 뒤 1536px 미리보기로 전환합니다. 디코딩 프록시는 RGBAh로 캐시하며 출력에는 사용하지 않습니다. 비교/undo/종료로 바뀐 이전 세대의 결과는 무시합니다. 보정 지표는 기본으로 표시하며 정밀 렌더 뒤 256px 표본으로 계산합니다. 드래그 중에는 이전 지표를 유지하고 계산 대기 표시를 보여줍니다. 메뉴에서 숨길 수 있습니다. 진행 중 시스템 렌더/ML prediction은 반환 시까지 취소가 지연될 수 있습니다. 슬라이더 한 제스처·브러시 한 획은 history 한 단계입니다. [UI 및 반응성 검증](Evidence/focused-editor-verification.md)을 참조하세요.

## 색과 처리 순서

작업 공간은 extended linear sRGB, 중간 Core Image 표현은 RGBA half float입니다. SDR 화면과 원본 픽셀 확인은 Display P3 RGBA8, HDR 화면은 extended linear Display P3 RGBAh와 높은 dynamic range 표시를 사용합니다.

1. RAW/래스터 현상, 방향 한 번 적용. RAW는 기록한 decoder/baseline/WB를 기본으로 사용하고, 선택한 RAW 현상 override를 디코더에 적용합니다.
2. 저장된 제거 패치를 원본 좌표에 합성. RAW에서 패치에는 현재 노출을 맞춤.
3. 노출·색온도/색조·명암·생동감·기본 커브·8색 HSL.
4. 룩·개별 RGB 포인트 커브·그레이딩·안개·텍스처·색 노이즈·입자.
5. 일반 노이즈·명료도·선명도.
6. 복제/힐링·부분 보정·피사체 배경 흐림·추정 깊이 흐림, 선택한 P3 색역 확장.
7. 왜곡·원근·회전·반전·수평·자르기·비네팅.
8. 출력 색 공간·워터마크·형식 변환.

포인트 커브는 화면과 같은 선형 구간 보간입니다. HDR은 0–8 선형 domain을 사용하고 커브의 마지막 기울기를 연장합니다. HSL HDR 경로는 logarithmic shaper → LUT → inverse shaper로 SDR 1 초과 값을 보존합니다. 8 이상의 headroom 보존은 보장하지 않습니다. 모든 조절이 Adobe와 같은 수치/알고리즘은 아닙니다.

안개 제거는 전역 veil 근사, 색 번짐 완화는 chroma smoothing, 왜곡은 수동 방사형 근사입니다. 카메라별 렌즈 프로파일·AI RAW 노이즈 제거로 표기하지 않습니다. 미리보기와 전체 해상도 출력의 공간 필터가 픽셀 단위로 같지는 않습니다.

## 마스크와 요소 지우기

위치는 원본 구도의 정규화된 좌상단 좌표입니다. 마스크/요소 지우기 화면에서는 geometry를 잠시 해제하고, 저장된 출력에는 보정 후 geometry를 적용합니다. 마스크 32개, 누적 브러시 200획/총 20,000점, 복제/힐링 200개, 제거 30회로 제한합니다.

브러시 획은 최대값 합성으로 더하고 inverse-mask 곱셈으로 뺍니다. 힐링은 signed high-frequency texture와 대상의 low-frequency color를 합칩니다. 마스크의 붉은 표시와 clipping 경고는 preview 전용이며 export에는 포함되지 않습니다.

요소 지우기는 독립적인 임시 선택 영역을 사용합니다. 1–8× 확대 상태에서 한 손가락으로 칠하거나 선택을 지우고, 두 손가락으로 확대·이동합니다. 이동 모드에서는 한 손가락 이동도 가능합니다. 브러시 크기는 확대 배율에 맞춰 원본 좌표로 변환됩니다. 최대 100획/10,000점이고, 실행 전에는 사진 렌더나 모델 추론을 요청하지 않습니다. 원본 구도에서 작업하며 조절 화면으로 돌아오면 자르기/회전이 다시 표시됩니다.

실행 버튼을 누르면 번들 AOT-GAN을 CPU/GPU에서 실행하고 선택한 부분만 합성합니다. 모델은 서비스에 캐시하며 NPU 사용을 보장하지 않습니다. 선택 비율 60% 이상/빈 영역은 오류로 안내합니다. 성공할 때만 history에 한 번 추가하고 임시 선택을 비웁니다. 실패/취소 시 선택은 유지하고 생성 중인 파일을 정리합니다. 취소는 실행 중인 Core ML 호출이 끝난 뒤 반영될 수 있습니다. 결과는 상단 실행 취소/다시 실행으로 복원합니다. 선택 초안은 편집 세션을 닫으면 사라지며 사진 보정 기록에는 저장하지 않습니다. 이전 복제/힐링 편집은 계속 렌더하지만 새로 만드는 UI는 제공하지 않습니다.

Vision foreground instance segmentation과 iOS 27 iterative segmentation을 연결했습니다. 탭 모델의 downloadAssets는 명시적 준비 버튼에서만 호출합니다. 모델 미준비·대상 없음은 오류로 안내합니다.

## SDR 사진의 HDR 확장

도구 → HDR에서 **HDR 밝기 지도 만들기**를 누르면 GMNet이 픽셀별 밝기 배율을 예측합니다. 강도 0–100%, 최대 배율 1–5×를 조절하며 재예측·제거·undo/redo를 지원합니다. 생성 직후 HDR 편집과 HDR 내보내기 기본값이 켜집니다. 새 지도는 중간톤 보호가 켜지며 기존 지도는 설정을 유지합니다. SDR로 비교 버튼은 화면만 전환하고 저장 설정을 변경하지 않습니다. 화면의 실제 밝기 범위는 디스플레이와 OS headroom에 따라 달라집니다.

원본 HDR gain map, ISO gain map 또는 HDR headroom이 있는 사진과 RAW에는 새 지도를 예측하지 않습니다. 사진별 16-bit PNG 지도는 원본 좌표로 저장하며 색 관리 없이 수치로 읽습니다. 색/디테일/마스크 보정 후, 기하 변환과 비네트 전에 선형 RGB에 같은 배율을 곱합니다. 사진을 편집한 뒤 재예측할 수 있으며 자동으로 재추론하지 않습니다. 최초 모델 사용 시 알려진 회색 입력의 출력을 검증하고 CPU/GPU 실행이 실패하면 CPU로 재시도합니다. 두 경로 모두 실패하면 지도를 저장하지 않습니다. 지도 UUID는 프리셋/사진 간 복사에서 제외하고 대상 사진의 지도는 유지합니다.

날아간 하이라이트의 실제 디테일을 복원하지 않습니다. 작은 밝은 물체, 피부, 벽, 광원 구분과 경계의 후광에 대한 실제 사진 평가가 남아 있습니다. 현재 지도 확대는 선형 보간이며 경계 보존 모델은 아닙니다.

## 로컬 모델

| 모델 | 입력/출력 | 용도·한계 |
| --- | --- | --- |
| Apple DepthAnythingV2SmallF16 | RGB 518×392 → depth image | 상대 깊이. 절대 거리/실측 depth 아님. 백분위 정규화 PNG를 저장하고 초점 범위로 CIMaskedVariableBlur 적용 |
| GMNet real-world FP16 | RGB 512² + global 256² → log2 gain 512² | 약 1.92M 파라미터, 약 3.9MB. CPU/GPU 로컬 추론, 5× 이내 확장. 실제 장면 휘도를 복원한다는 보장 없음 |
| AOT-GAN Core ML conversion | Float32 1×4×512×512 → 1×3×512×512 | 선택 crop의 RGB+mask로 보간. 원본에서 2048px 분석본 사용, crop 경계 밖은 보존. SDR 생성이며 큰 영역·반복 무늬·HDR 하이라이트의 품질은 제한적 |

Core ML 모델은 앱에 번들되며 추론에 네트워크를 사용하지 않습니다. 모델 출력은 mask/patch PNG로 저장되어 재열기·undo·export 때 재추론하지 않습니다. 모델 파일 출처·라이선스는 앱 설정 및 Velyn/Notices, SHA는 model-integrity.json에 있습니다. 원본 데이터/모델 입력은 서버로 보내지 않습니다.

## 영속화

```text
Projects/
  catalog.json
  presets.json
  <UUID>/
    manifest.json
    original/source
    edits.json
    versions.json
    masks/<UUID>.png
```

원본은 import 시 양쪽 SHA를 검사하고 디렉터리 rename으로 확정합니다. edits.json은 atomic write이며 낮은 revision이 높은 revision을 덮어쓰지 않습니다. 새 advanced optional 필드를 통해 이전 전역 편집 문서를 읽습니다. 손상된 문서를 덮어쓰지 않습니다.

마스크/깊이/제거 리소스 경로는 UUID로만 구성하고 파일 symlink를 거부합니다. history/버전이 참조할 수 있으므로 이전 리소스를 즉시 삭제하지 않습니다. 아직 reference 기반 리소스 정리 기능은 없습니다.

프리셋과 일괄 복사는 색·톤을 옮기고 각 사진의 geometry·mask·retouch·depth·removal을 유지합니다. 다른 사진의 공간 리소스 ID를 복사하지 않습니다. Velyn 프리셋은 XMP와 호환되지 않습니다.

## P3 색역 확장

조절 목록의 ‘색역 확장’에서 0–100%를 선택합니다. 기본은 0이며 원본 비교에서 제외되고, history/프리셋/일괄 보정에 포함됩니다. 기기 안에서 계산하는 분석적 보간 방식입니다. 학습 모델/사진별 의미 추론/NPU를 사용하지 않으며 잃어버린 원래 색을 복원한다고 주장하지 않습니다.

선형 Display P3에서 휘도 Y를 유지하며 중성점에서 색역 경계 쪽으로 색을 확장합니다. sRGB 경계와 P3 경계 사이 여유의 일부를 사용하며 낮은 채도와 따뜻한 주황 계열은 덜 변경합니다. 피부 보호는 색상 범위에 의한 휴리스틱이며 얼굴 인식이 아닙니다. 한 번 생성한 33³ RGBA Float LUT(약 0.55MiB)를 재사용하고 강도만 혼합합니다. CIColorCubeWithColorSpace의 extrapolate를 켜 HDR 입력을 1에서 자르지 않습니다. HDR 밝기 지도는 색역 확장 뒤에 적용합니다.

기본/원본 픽셀 미리보기는 P3 색 공간을 유지합니다. 색역 확장 사용 시 단일 사진 저장의 초기 색 공간은 Display P3이고, 일괄 저장도 Display P3를 기본으로 합니다. 사용자가 sRGB를 선택하면 색역 축소 안내를 표시합니다. 저장 형식은 JPEG·PNG·HEIC·원본 네 가지 그대로입니다.

[합성 색상 및 출력 검증](Evidence/gamut-expansion-verification.md)을 참조하세요.

## 출력

- JPEG/HEIC: SDR 8bit 또는 HDR gain map. 기존 HDR은 tone-mapped SDR base와 HDR image를 writer에 전달합니다. 예측 HDR은 동일 편집의 SDR 렌더를 별도로 사용해 SDR fallback을 유지합니다.
- 저장 선택지는 JPEG·PNG·HEIC·원본 네 가지입니다. PNG는 8bit 무손실 SDR/투명 배경 유지, 원본은 바이트 복사입니다. WebP는 가져오기·원본 내보내기 지원이며 보정본 인코더는 포함하지 않습니다.
- TIFF 8/16bit와 AVIF 8bit SDR 인코더는 엔진에 유지하지만 일반 저장 선택지에서 제외합니다.
- sRGB/Display P3, 품질, 긴 변 64–20,000px 입력. 업스케일하지 않으며 원본 크기까지만 출력.
- 텍스트 워터마크는 우하단에 합성. 새 렌더는 GPS·촬영 메타데이터를 제거하고 새 색 프로파일/방향을 사용.
- 파일 형식·크기·방향·색 프로파일·GPS 부재를 재확인한 뒤 공유/저장 UI로 전달.
- 단일 사진 저장 화면은 설정 변경 후 550ms 동안 대기하고 실제 출력 파일을 준비해 용량·출력 해상도·확장자를 표시합니다. 준비한 파일을 저장에 재사용하며 설정 변경/화면 종료 때 임시 파일을 정리합니다. 색 공간·투명도·손실 압축·호환성 설명을 함께 표시합니다. JPEG/HEIC의 투명 영역은 흰색으로 합성합니다.
- 일괄 처리 중 취소는 완료된 결과를 보존하고 나머지를 중단. 파일별 오류 표시.

## 확인한 것과 남은 검증

[기존 전문 편집 검증](Evidence/professional-verification.md) 및 [50개 테스트와 밝기 지도 검증](Evidence/gain-map-verification.md)를 참조하세요. 실제 카메라, 12/48MP ProRAW, 탭 모델·Vision 실제 사진, PhotoKit/파일 저장 UI 전체 조작, A17 Pro 메모리/열·HDR 디스플레이 수락은 남아 있습니다. Mac/Simulator 결과를 기기 성능이나 출시 품질로 사용하지 않습니다.

## 실제 DNG 표본 검증

사용자 제공 DNG 1개(5712×4284)의 Mac 엔진 가져오기·현상·보정·history·JPEG/PNG/HEIC 전체 해상도 출력·원본 해시 보존을 확인했습니다. [2026-09-29 결과](Evidence/raw-file-verification-2026-09-29.md). 아이폰 성능/발열 및 ProRAW 전체 수락 검증은 별도로 남아 있습니다.

## RAW 현상 도구 (2026-09-29)

RAW를 열면 도구 → RAW 현상이 나타납니다. 한 번에 항목 하나를 골라 켈빈 화이트밸런스, RAW 색조, 현상 톤 커브/그림자, 로컬 톤, 디코더 노이즈 감소/선명도/디테일, 하이라이트 복구 및 렌즈 보정을 조절합니다. 디코더가 해당 파일에 지원한다고 보고한 항목만 표시합니다. 일반 조절의 색온도/색조는 이후의 색 보정이며 RAW 현상 WB와 별도입니다.

`RAWAdjustments`는 recipe의 optional 값으로 저장해 undo/redo/버전/재열기에 포함합니다. 값이 없으면 기존 결과를 유지합니다. 촬영 시 설정은 RAW override를 지웁니다. 캐시 키에 모든 RAW 값이 포함되어 다른 현상 결과를 재사용하지 않습니다. 색 프리셋 및 붙여넣기는 대상 사진의 RAW 현상을 보존하며 다른 사진의 절대 WB/현상 설정을 복사하지 않습니다.

하이라이트 복구는 지원되는 SDK/파일에만 표시합니다. 이전에도 디코더 기본값이 켜져 있는 파일에서는 동작했습니다. 클리핑된 센서 정보의 복원이나 학습 기반 RAW 디노이즈로 표기하지 않습니다. 원본별 로컬 톤/색 노이즈/렌즈 보정 지원이 다릅니다.

PNG에 8/16비트 저장 선택을 추가했습니다. RAW의 저장 UI는 Display P3 및 PNG 16비트를 초기값으로 선택합니다. 포맷 목록은 JPEG/PNG/HEIC/원본 네 개 그대로입니다. 16비트 PNG는 보정 결과의 채널 정밀도이며 원시 센서 정보 보존이나 HDR gain map을 의미하지 않습니다. 원시 데이터는 원본 내보내기로 보존합니다.

제거 패치는 생성 당시의 RAW 현상으로 합성됩니다. 이후 RAW WB/톤을 크게 바꾸면 이미 생성된 SDR 제거 패치의 색 연결이 달라질 수 있어 검증이 더 필요합니다. RAW 현상을 먼저 마치고 요소 지우기를 적용하는 순서를 권장합니다.

## 보정 지표 및 HDR 재현 검증 (2026-09-29)

RGB 히스토그램, SDR 범위 초과 비율, 암부 비율, 사진의 최대 RGB 채널 값 및 현재 화면 EDR 여유를 표시합니다. 선형 Display P3의 256px 표본이며 니트나 원본 전체 픽셀 측정이 아닙니다. HDR 프리뷰는 지원 SDK의 HDR 통계 계산을 사용하고 클리핑 표시도 부동소수점 HDR을 유지합니다. [67개 테스트 및 실제 파일 검증](Evidence/hdr-diagnostics-verification.md)을 참조하세요. 실기기에서 색과 밝기의 시각적 수락은 남아 있습니다.

HDR 밝기 지도는 Rf의 R 값을 스칼라로 읽고 RGB 세 채널에 복제한 뒤 적용합니다. 이전 버전이 저장한 R 전용 PNG도 같은 방식으로 처리하므로 붉은 색조 수정에 재예측은 필요하지 않습니다. [68개 테스트 및 붉은 HDR 수정 검증](Evidence/hdr-red-cast-verification.md).
