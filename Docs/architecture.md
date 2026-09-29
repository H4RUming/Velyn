# 원본 가져오기 구조

## 경계

- `SourceAsset`: Foundation 기반 Codable/Sendable 값. 픽셀 자원 없음.
- `ImportStore`: MainActor에서 UI 상태와 취소를 관리. 가져오기 중 중복 실행 차단.
- `AssetImporting`: UI와 서비스 경계.
- `OriginalImportService`: 별도 actor에서 파일 조정, 복사, hash, 메타데이터, 확정 처리.
- `ImageMetadataReader`: ImageIO와 Core Image를 감춘 파일 메타데이터 adapter.
- `SDKCapabilityProbe`: 새 API의 컴파일 검증. 앱 흐름에서 실행하지 않음.

## 저장 순서

1. security scope 획득, 작업 취소 확인.
2. Application Support 저장 폴더 생성 및 백업 제외.
3. `.import-<UUID>/original/source`에 1MiB 단위로 복사하면서 입력 hash 계산.
4. 복사본을 독립적으로 다시 읽어 hash 계산. 바이트 수·hash가 다르면 폐기.
5. ImageIO로 형식·방향·메타데이터 조회. RAW는 CIRAWFilter의 nativeSize 확인.
6. 임시 패키지에 `manifest.json`을 atomic write.
7. 취소 확인 후 같은 파일시스템의 `<UUID>/`로 디렉터리 rename.
8. rename과 취소가 경합하면 해당 새 패키지만 제거. 이미 확정된 다른 원본은 유지.
9. 다음 가져오기 때 중단된 `.import-*`만 정리.

```text
Application Support/Velyn/Projects/
  <UUID>/
    manifest.json
    original/source
```

확장자가 없는 고정 경로를 사용합니다. 원본 파일명은 manifest의 표시용 필드이며 디스크 경로에 삽입하지 않습니다. 입력 확장자를 신뢰하지 않습니다. SHA-256은 원본의 모든 바이트를 대상으로 하며, 기존 원본 파일에 쓰기 작업을 하지 않습니다. 원본 파일을 읽는 동안 공급자가 내용을 바꾸지 않도록 NSFileCoordinator로 조정합니다.

## 메타데이터 계약

- `pixelWidth/Height`: 회전하지 않은 native dimensions.
- `orientation`: EXIF 1–8, 없으면 1. 5–8이면 표시 크기의 가로·세로를 교환.
- `typeIdentifier`: ImageIO가 읽은 실제 컨테이너 UTI.
- `colorProfile`: ImageIO가 보고한 profile name. ICC blob 원본은 원본 파일에 그대로 있음.
- `supportedRAWDecoders`: 지원 목록만 기록. 이 단계에서는 렌더 디코더를 선택하지 않음.
- `sourceSHA256/sha256`: 입력 스트림·복사본 검증 값. PhotoKit 원본 취득 증거는 아님.

기본 스키마가 아닌 manifest는 목록에서 건너뛰고 파일을 보존합니다. 재열기는 전체 hash를 확인합니다. 프로젝트 패키지의 외부 가져오기와 스키마 migration은 아직 지원하지 않습니다.

## 범위와 제약

파일 provider의 지연 자체를 즉시 중단하지 못할 수 있으며, 다음 취소 확인 지점에서 정리합니다. 디스크가 실제로 가득 찬 상황, 파일 공급자가 강제 종료되는 상황, 전원 차단에 대한 crash durability는 실기기 테스트가 필요합니다. CRC·SHA 검증은 디코딩 및 사진 품질 검증을 대신하지 않습니다. 엔진 인스턴스 하나가 저장소 하나를 소유해야 합니다.

## 전문 편집 확장

현재 편집·마스크·깊이·제거·카탈로그 저장 구조는 [편집 엔진 계약](editor-features.md)에 기록합니다. 위 설명은 원본 가져오기 경계이며 그대로 유지됩니다.
