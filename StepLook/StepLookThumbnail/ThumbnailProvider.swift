import AppKit
import OSLog
import QuickLookThumbnailing

final class ThumbnailProvider: QLThumbnailProvider {
    private static let lifecycleLog = Logger(
        subsystem: "com.local.stepviewer.StepLook",
        category: "ThumbnailLifecycle"
    )

    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        Task(priority: .userInitiated) {
            let requestStart = ProcessInfo.processInfo.systemUptime
            let url = request.fileURL
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let budget = StepPreviewImportBudget(for: url)
                let cache = StepPreviewCache(profileIdentifier: budget.cacheProfileIdentifier)
                let loaded = try await cache.loadOrImport(for: url) {
                    let preflight = try await budget.preflightColdImport(for: url)
                    let result = try await StepImportClient().importFile(
                        at: url,
                        maxSeconds: budget.seconds,
                        maxTriangles: budget.maximumTriangles,
                        relativeDeflection: budget.relativeDeflection,
                        minimumDeflection: budget.minimumDeflection,
                        maximumDeflection: budget.maximumDeflection,
                        startingSimplificationLevel:
                            preflight?.startingSimplificationLevel ?? 0
                    )
                    return result.archive
                }
                let pixels = CGSize(
                    width: request.maximumSize.width * request.scale,
                    height: request.maximumSize.height * request.scale
                )
                let image = try await StepThumbnailRenderer.render(loaded.model, pixelSize: pixels)
                let reply = QLThumbnailReply(contextSize: request.maximumSize, drawing: { context in
                    context.setFillColor(CGColor(gray: 1, alpha: 1))
                    context.fill(CGRect(origin: .zero, size: request.maximumSize))
                    let rect = Self.aspectFit(
                        imageSize: CGSize(width: image.width, height: image.height),
                        inside: CGRect(origin: .zero, size: request.maximumSize)
                    )
                    context.interpolationQuality = .high
                    context.draw(image, in: rect)
                    return true
                })
                reply.extensionBadge = "STEP"
                Self.lifecycleLog.info(
                    "thumbnail_ready source=\(loaded.source.rawValue, privacy: .public) seconds=\(ProcessInfo.processInfo.systemUptime - requestStart, format: .fixed(precision: 3)) triangles=\(loaded.model.triangleCount) definitions=\(loaded.model.definitions.count) occurrences=\(loaded.model.occurrences.count) missing_faces=\(loaded.model.missingFaceCount) pixel_width=\(Int(pixels.width)) pixel_height=\(Int(pixels.height))"
                )
                handler(reply, nil)
            } catch {
                let nsError = error as NSError
                Self.lifecycleLog.error(
                    "thumbnail_fallback category=\(StepTelemetryFailureCategory.label(for: error), privacy: .public) seconds=\(ProcessInfo.processInfo.systemUptime - requestStart, format: .fixed(precision: 3)) domain=\(nsError.domain, privacy: .public) code=\(nsError.code)"
                )
                let reply = Self.fallbackReply(size: request.maximumSize)
                reply.extensionBadge = "STEP"
                handler(reply, nil)
            }
        }
    }

    private static func fallbackReply(size: CGSize) -> QLThumbnailReply {
        QLThumbnailReply(contextSize: size, drawing: { context in
            let bounds = CGRect(origin: .zero, size: size)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(bounds)
            let side = min(size.width, size.height) * 0.42
            let cube = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
            context.setStrokeColor(CGColor(gray: 0.55, alpha: 1))
            context.setLineWidth(max(1.5, side * 0.025))
            context.stroke(cube.insetBy(dx: side * 0.08, dy: side * 0.08))
            context.move(to: CGPoint(x: cube.minX + side * 0.08, y: cube.midY))
            context.addLine(to: CGPoint(x: cube.midX, y: cube.maxY - side * 0.08))
            context.addLine(to: CGPoint(x: cube.maxX - side * 0.08, y: cube.midY))
            context.strokePath()
            return true
        })
    }

    private static func aspectFit(imageSize: CGSize, inside bounds: CGRect) -> CGRect {
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
}
