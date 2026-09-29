import Testing
import Foundation
import CoreML
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import VelynEngine

struct DepthModelTests {
    @Test func bundledModelRunsLocallyAndDepthPersists() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = root.appendingPathComponent("Velyn/Models/DepthAnythingV2SmallF16.mlpackage")
        let compiled = try await MLModel.compileModel(at: source)
        defer { try? FileManager.default.removeItem(at: compiled) }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("VelynDepth-\(UUID())")
        try FileManager.default.createDirectory(at: base,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let rect = CGRect(x: 0,y: 0,width: 240,height: 180)
        let image = CIImage(color: .red).cropped(to: CGRect(x: 70,y: 25,width: 90,height: 120)).composited(over: CIImage(color: .gray).cropped(to: rect))
        let path = base.appendingPathComponent("synthetic.jpg")
        try CIContext().writeJPEGRepresentation(of: image,to: path,colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let projects = base.appendingPathComponent("projects")
        let asset = try await OriginalImportService(root: projects).importFile(at: path)
        let service = EditingService(root: projects,asset: asset)
        var document = try await service.load()
        let depth = try await service.estimateDepth(document,modelURL: compiled)
        #expect(depth.isValid)
        var recipe = EditRecipe(); recipe.enhancements.depth = depth
        let focus = try await service.depthAtPoint(recipe,point: .init(0.5,0.5))
        #expect(focus.isFinite && (0...1).contains(focus))
        let resources = try await service.maskResources(recipe)
        #expect(resources[depth.resourceID]?.extent.size == CGSize(width: 518,height: 392))
        let original = try await service.render(document,recipe: EditRecipe())
        let blurred = try await service.render(document,recipe: recipe)
        #expect(original.image.width == blurred.image.width)
        document.history.commit(recipe); document.revision += 1
        try await service.save(document)
        let reopened = try await EditingService(root: projects,asset: asset).load()
        #expect(reopened.history.current.enhancements.depth?.resourceID == depth.resourceID)
        #expect(recipe.colorOnly.enhancements.depth == nil)
    }
    @Test(arguments: [false, true]) func localRemovalChangesOnlyMaskAndKeepsHistory(offCenter: Bool) async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let compiled = try await MLModel.compileModel(at: root.appendingPathComponent("Velyn/Models/aotgan.mlmodel"))
        defer { try? FileManager.default.removeItem(at: compiled) }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("VelynRemoval-\(UUID())")
        try FileManager.default.createDirectory(at: base,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let cx = offCenter ? 60.0 : 120.0, cy = offCenter ? 144.0 : 80.0
        let image = CIImage(color: .red).cropped(to: CGRect(x: cx-10,y: cy-10,width: 20,height: 20)).composited(over: CIImage(color: .gray).cropped(to: CGRect(x: 0,y: 0,width: 240,height: 180)))
        let path = base.appendingPathComponent("synthetic.jpg")
        let context = CIContext()
        try context.writeJPEGRepresentation(of: image,to: path,colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let projects = base.appendingPathComponent("projects")
        let asset = try await OriginalImportService(root: projects).importFile(at: path)
        let service = EditingService(root: projects,asset: asset)
        var document = try await service.load()
        var recipe = EditRecipe(), mask = LocalMask(kind: .radial)
        mask.points = [.init(0.42,0.5),.init(0.58,0.65)]; mask.feather = 0.1
        recipe.enhancements.masks = [mask]
        var selection = RemovalSelection()
        selection.append(MaskStroke(points: [.init(cx/240,1-cy/180)],radius: 0.075,feather: 0,erasing: false))
        selection.append(MaskStroke(points: [.init((cx+10)/240,1-cy/180)],radius: 0.01,feather: 0,erasing: true))
        let patch = try await service.removeSelection(document,recipe: recipe,selection: selection.mask,modelURL: compiled)
        #expect(patch.topLeft.y < 1-cy/180 && patch.bottomRight.y > 1-cy/180)
        #expect(patch.isValid)
        recipe.enhancements.removals = [patch]
        let a = try await service.render(document,recipe: EditRecipe()), b = try await service.render(document,recipe: recipe)
        func sample(_ cg: CGImage,_ x: Double,_ y: Double) -> [Float] {
            var pixel = [Float](repeating: 0,count: 4)
            pixel.withUnsafeMutableBytes { context.render(CIImage(cgImage: cg),toBitmap: $0.baseAddress!,rowBytes: 16,bounds: CGRect(x: x,y: y,width: 1,height: 1),format: .RGBAf,colorSpace: RenderPipeline.linearSpace) }
            return pixel
        }
        #expect(zip(sample(a.image,10,10),sample(b.image,10,10)).allSatisfy { abs($0-$1) < 0.0001 })
        let before = sample(a.image,cx,cy), after = sample(b.image,cx,cy)
        #expect(after[0]-after[1] < (before[0]-before[1])*0.5)
        document.history.commit(recipe); document.history.undo(); #expect(document.history.current.enhancements.removals == nil)
        document.history.redo(); #expect(document.history.current.enhancements.removals?.count == 1)
        #expect(zip(sample(a.image,cx+10,cy),sample(b.image,cx+10,cy)).allSatisfy { abs($0-$1) < 0.003 })
        let patchURL = projects.appendingPathComponent("\(asset.id)/masks/\(patch.imageID).png")
        #expect(FileManager.default.fileExists(atPath: patchURL.path))
        await service.discardUncommittedRemoval(patch)
        #expect(!FileManager.default.fileExists(atPath: patchURL.path))
    }

}
