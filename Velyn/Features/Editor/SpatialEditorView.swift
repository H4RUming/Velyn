import SwiftUI

struct SpatialEditorView: View {
    let editor: EditorStore
    let image: CGImage
    let tool: EditorTool?
    @State private var stroke: [PhotoPoint] = []
    private var mask: LocalMask? { editor.recipe.enhancements.masks.first { $0.id == editor.activeMask } }

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width/Double(image.width),geo.size.height/Double(image.height))
            let size = CGSize(width: Double(image.width)*scale,height: Double(image.height)*scale)
            ZStack {
                Image(decorative: image,scale: 1).resizable().allowedDynamicRange(.high).frame(width: size.width,height: size.height)
                Canvas { context, _ in
                    if tool == .crop {
                        let rect = RenderPipeline.cropRect(in: CGRect(origin: .zero,size: size),recipe: editor.recipe)
                        let box = CGRect(x: rect.minX,y: size.height-rect.maxY,width: rect.width,height: rect.height)
                        var outside = Path(CGRect(origin: .zero,size: size)); outside.addRect(box)
                        context.fill(outside,with: .color(.black.opacity(0.5)),style: FillStyle(eoFill: true))
                        context.stroke(Path(box),with: .color(.white),lineWidth: 2)
                        for i in 1...2 { var grid = Path(); let t = Double(i)/3; grid.move(to: CGPoint(x: box.minX+box.width*t,y: box.minY)); grid.addLine(to: CGPoint(x: box.minX+box.width*t,y: box.maxY)); grid.move(to: CGPoint(x: box.minX,y: box.minY+box.height*t)); grid.addLine(to: CGPoint(x: box.maxX,y: box.minY+box.height*t)); context.stroke(grid,with: .color(.white.opacity(0.5)),lineWidth: 0.5) }
                    }
                    if tool == .masks, let mask {
                        let points = (stroke.isEmpty ? mask.points : stroke).map { CGPoint(x: $0.x*size.width,y: $0.y*size.height) }
                        var path = Path()
                        if mask.kind == .radial, points.count > 1 {
                            path.addEllipse(in: CGRect(x: min(points[0].x,points.last!.x),y: min(points[0].y,points.last!.y),width: abs(points[0].x-points.last!.x),height: abs(points[0].y-points.last!.y)))
                        } else { path.addLines(points) }
                        if mask.kind == .brush { context.stroke(path,with: .color(.red.opacity(0.35)),style: StrokeStyle(lineWidth: mask.radius*max(size.width,size.height)*2,lineCap: .round,lineJoin: .round)) }
                        else if mask.kind == .linear || mask.kind == .radial { context.stroke(path,with: .color(.red),style: StrokeStyle(lineWidth: 2,dash: [5,3])) }
                    }
                }.frame(width: size.width,height: size.height).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        let point = normalized(value.location,size: size)
                        if tool == .masks && !editor.pickingWhiteBalance && !editor.pickingDetail {
                            if stroke.isEmpty { stroke.append(normalized(value.startLocation,size: size)) }
                            if mask?.kind == .brush { if stroke.count < 20_000 { stroke.append(point) } }
                            else { stroke = [stroke[0],point] }
                        }
                    }.onEnded { value in
                        let point = normalized(value.location,size: size)
                        if editor.pickingDepth { Task { await editor.focusDepth(at: point) }; return }
                        if editor.pickingWhiteBalance { editor.pickingWhiteBalance = false; Task { await editor.sampleWhiteBalance(at: point) }; return }
                        if editor.pickingDetail { editor.pickingDetail = false; Task { await editor.loadDetail(at: point) }; return }
                        if tool == .masks && (editor.pickingObject || mask?.kind == .object) { Task { await editor.selectObject(at: point) }; stroke = []; return }
                        if tool == .masks {
                            let captured = stroke
                            if !captured.isEmpty, let kind = mask?.kind, [.brush,.linear,.radial].contains(kind) {
                                editor.editMask { mask in
                                    if kind == .brush {
                                        let used = mask.points.count + (mask.strokes?.reduce(0) { $0 + $1.points.count } ?? 0)
                                        guard used+captured.count <= 20_000,(mask.strokes?.count ?? 0) < 200 else { return }
                                        let item = MaskStroke(points: captured,radius: mask.radius,feather: mask.feather,erasing: editor.erasingBrush)
                                        mask.strokes = (mask.strokes ?? []) + [item]
                                    } else { mask.points = captured }
                                }
                            }
                            stroke = []
                        } else if tool == .crop {
                            let start = normalized(value.startLocation,size: size)
                            let width = abs(point.x-start.x), height = abs(point.y-start.y)
                            guard width > 0.02, height > 0.02 else { return }
                            let current = RenderPipeline.cropRect(in: CGRect(origin: .zero,size: size),recipe: { var r = editor.recipe; r[.cropScale] = 100; return r }())
                            let fraction = min(width*size.width/current.width,height*size.height/current.height)
                            let percentage = min(100,max(25,fraction*100))
                            let cropW = current.width*percentage/100/size.width, cropH = current.height*percentage/100/size.height
                            editor.mutate { r in
                                r[.cropScale] = percentage
                                r[.cropX] = ((start.x+point.x)/2-cropW/2)/max(0.001,1-cropW)*100
                                r[.cropY] = ((start.y+point.y)/2-cropH/2)/max(0.001,1-cropH)*100
                            }
                        }
                    })
            }.frame(width: geo.size.width,height: geo.size.height)
        }
    }
    private func normalized(_ p: CGPoint,size: CGSize) -> PhotoPoint { PhotoPoint(min(1,max(0,p.x/size.width)),min(1,max(0,p.y/size.height))) }
    private func drawCircle(_ p: PhotoPoint,radius: Double,color: Color,context: GraphicsContext,size: CGSize) {
        let r = radius*max(size.width,size.height)
        context.stroke(Path(ellipseIn: CGRect(x: p.x*size.width-r,y: p.y*size.height-r,width: r*2,height: r*2)),with: .color(color),lineWidth: 1)
    }
}

struct HistogramView: View {
    let analysis: ImageAnalysis
    var body: some View {
        HStack(spacing: 12) {
            Canvas { context,size in
                let maxBin = max(1,analysis.histogram.max() ?? 1)
                var path = Path(); path.move(to: CGPoint(x: 0,y: size.height))
                for i in analysis.histogram.indices { path.addLine(to: CGPoint(x: Double(i)/255*size.width,y: size.height*(1-Double(analysis.histogram[i])/Double(maxBin)))) }
                path.addLine(to: CGPoint(x: size.width,y: size.height)); path.closeSubpath()
                context.fill(path,with: .color(.white.opacity(0.55)))
            }
            VStack(alignment: .trailing,spacing: 4) {
                Text(L10n.format("밝은 영역 %.1f%%",analysis.highlights*100))
                Text(L10n.format("어두운 영역 %.1f%%",analysis.shadows*100))
            }.font(.system(size: 9,design: .monospaced)).foregroundStyle(.secondary)
        }.frame(height: 38).padding(.horizontal,16).padding(.vertical,6).background(.black)
    }
}
