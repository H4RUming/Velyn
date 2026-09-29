import Testing
import Foundation
import CoreImage
@testable import VelynEngine

struct RemovalSelectionTests {
    @Test func paintEraseUndoAndLimits() {
        var selection = RemovalSelection()
        #expect(!selection.hasPaint)
        let paint = MaskStroke(points: [.init(0.2,0.3),.init(0.4,0.3)],radius: 0.04,feather: 0,erasing: false)
        let accepted = selection.append(paint); #expect(accepted)
        let erased = selection.append(MaskStroke(points: [.init(0.3,0.3)],radius: 0.01,feather: 0,erasing: true)); #expect(erased)
        #expect(selection.hasPaint && selection.mask.points.isEmpty && selection.mask.isValid)
        selection.undo(); #expect(selection.strokes == [paint])
        let invalid = selection.append(MaskStroke(points: [.init(-1,0)],radius: 0.02,feather: 0,erasing: false)); #expect(!invalid)
        let oversized = selection.append(MaskStroke(points: Array(repeating: .init(0.5,0.5),count: 10_001),radius: 0.02,feather: 0,erasing: false)); #expect(!oversized)
        selection.clear(); #expect(selection.strokes.isEmpty && !selection.hasPaint)
        for _ in 0..<100 { let added = selection.append(paint); #expect(added) }
        let excess = selection.append(paint); #expect(!excess)
    }
    @Test func selectionKeepsTopLeftCoordinatesAndErasedHole() {
        var selection = RemovalSelection()
        selection.append(MaskStroke(points: [.init(0.15,0.2),.init(0.45,0.2)],radius: 0.04,feather: 0,erasing: false))
        selection.append(MaskStroke(points: [.init(0.3,0.2)],radius: 0.02,feather: 0,erasing: true))
        let mask = AdvancedPipeline.selection(selection.mask,image: CIImage(color: .white).cropped(to: CGRect(x: 0,y: 0,width: 400,height: 300)),resources: [:])
        let context = CIContext()
        func pixel(_ x: Double,_ y: Double) -> UInt8 {
            var value: UInt8 = 0
            context.render(mask,toBitmap: &value,rowBytes: 1,bounds: CGRect(x: x,y: y,width: 1,height: 1),format: .L8,colorSpace: nil)
            return value
        }
        #expect(pixel(80,240) > 240)
        #expect(pixel(120,240) < 10)
        #expect(pixel(80,60) < 10)
    }
}
