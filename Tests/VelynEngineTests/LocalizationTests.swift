import Foundation
import Testing
@testable import VelynEngine

struct LocalizationTests {
    @Test func languageResolutionAndUnknownPreferenceFallback() {
        #expect(AppLanguage.system.resolvedCode(preferredLanguages: ["ko-KR","en-US"]) == "ko")
        #expect(AppLanguage.system.resolvedCode(preferredLanguages: ["ja-JP","en-US"]) == "en")
        #expect(AppLanguage.system.resolvedCode(preferredLanguages: ["fr-FR"]) == "en")
        #expect(AppLanguage.english.resolvedCode(preferredLanguages: ["ko-KR"]) == "en")
        #expect(AppLanguage.korean.resolvedCode(preferredLanguages: ["en-US"]) == "ko")
        #expect((AppLanguage(rawValue: "unsupported") ?? .system) == .system)
    }
    @Test func resourcesTranslateLabelsAndErrorsWithoutChangingStoredValues() throws {
        #expect(L10n.tr("사진 추가",language: .english) == "Add photos")
        #expect(L10n.tr("사진 추가",language: .korean) == "사진 추가")
        #expect(L10n.tr("HDR 밝기 지도 만들기",language: .english) == "Create HDR gain map")
        #expect(L10n.tr("사진을 처리하지 못했습니다. 다시 시도해 주세요.",language: .english) == "Couldn't process the photo. Try again.")
        #expect(L10n.tr("unknown-key",language: .english) == "unknown-key")
        // Language is presentation only. Old documents retain their Korean enum values.
        let data = try JSONEncoder().encode(CropAspect.original)
        #expect(String(decoding: data,as: UTF8.self) == "\"원본\"")
        #expect(try JSONDecoder().decode(PhotoProfile.self,from: Data("\"풍경\"".utf8)) == .landscape)
        #expect(MaskKind.subject.rawValue == "피사체")
        var mask = LocalMask(kind: .brush)
        mask.name = "브러시 2"
        #expect(L10n.maskName(mask,language: .english) == "Brush 2")
        #expect(mask.name == "브러시 2")
        mask.name = "여행 100%"
        #expect(L10n.maskName(mask,language: .english) == "여행 100%")
    }
    @Test func localizedNumbersAndArgumentsArePreserved() {
        #expect(L10n.format("%ld장 선택됨",arguments: [3],language: .english) == "3 selected")
        #expect(L10n.format("%ld장 선택됨",arguments: [3],language: .korean) == "3장 선택됨")
        #expect(L10n.format("%@ 삭제",arguments: ["여행 100%"],language: .english) == "Delete 여행 100%")
        #expect(L10n.format("SDR 초과 %.1f%% · 암부 %.1f%%",arguments: [6.25,1.0],language: .english) == "Above SDR 6.2% · Shadows 1.0%")
        #expect(L10n.format("%ld장 완료, %ld장 실패\n",arguments: [2,1],language: .english) == "Completed: 2, failed: 1\n")
    }
}
