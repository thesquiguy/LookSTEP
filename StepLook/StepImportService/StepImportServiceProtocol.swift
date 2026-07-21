import Foundation

@objc nonisolated protocol StepImportServiceProtocol {
    func importSTEP(
        sourceFile: FileHandle,
        sourceExtension: String,
        maxSeconds: Double,
        maxTriangles: Int,
        relativeDeflection: Double,
        minimumDeflection: Double,
        maximumDeflection: Double,
        with reply: @escaping (Data?, NSDictionary?, NSError?) -> Void
    )
    func cancelCurrentImport()
}
