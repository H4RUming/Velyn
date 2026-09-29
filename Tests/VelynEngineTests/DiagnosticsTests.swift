import Foundation
import Testing
@testable import VelynEngine

struct DiagnosticsTests {
    @Test func floatingPointStatsKeepHDRAndIgnoreTransparentPixels() {
        let result = EditingService.measure([0,0,0,1, 2,1,0.5,1, 0.1,0.2,0.3,0.5, 10,10,10,0])
        #expect(result.sampleCount == 3 && result.peak == 2)
        #expect(abs(result.aboveSDRFraction-1.0/3) < 0.00001)
        #expect(abs(result.shadowFraction-1.0/3) < 0.00001)
        #expect(result.red.reduce(0,+) == 3 && result.green.reduce(0,+) == 3 && result.blue.reduce(0,+) == 3)
        #expect(result.red[127] == 1)
        let empty = EditingService.measure([.nan,0,0,1,0,0,0,0])
        #expect(empty.sampleCount == 0 && empty.peak == 0 && empty.averageLuminance == 0)
    }
}
