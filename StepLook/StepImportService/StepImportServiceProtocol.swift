import Foundation

@objc nonisolated protocol StepImportServiceProtocol {
    func importSTEP(
        requestIdentifier: String,
        sourceFile: FileHandle,
        sourceExtension: String,
        maxSeconds: Double,
        maxTriangles: Int,
        maxResidentBytes: Int64,
        relativeDeflection: Double,
        minimumDeflection: Double,
        maximumDeflection: Double,
        startingSimplificationLevel: Int,
        with reply: @escaping (Data?, NSDictionary?, NSError?) -> Void
    )
    func cancelImport(requestIdentifier: String, with reply: @escaping (Bool) -> Void)
}
