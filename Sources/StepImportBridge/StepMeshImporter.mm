#import "StepMeshImporter.h"

#include "../StepImportCore/StepXCAFInterpretation.hxx"

#include <BRepBndLib.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRep_Tool.hxx>
#include <Bnd_Box.hxx>
#include <DESTEP_Parameters.hxx>
#include <IFSelect_ReturnStatus.hxx>
#include <IMeshTools_Parameters.hxx>
#include <Poly_Triangulation.hxx>
#include <Quantity_ColorRGBA.hxx>
#include <STEPCAFControl_Reader.hxx>
#include <Standard_Failure.hxx>
#include <TDataStd_Name.hxx>
#include <TDF_Tool.hxx>
#include <TDocStd_Document.hxx>
#include <TopAbs_Orientation.hxx>
#include <TopExp_Explorer.hxx>
#include <TopoDS_Iterator.hxx>
#include <TopoDS.hxx>
#include <TopTools_DataMapOfShapeInteger.hxx>
#include <XCAFApp_Application.hxx>
#include <XCAFDoc_DocumentTool.hxx>
#include <XCAFDoc_ShapeTool.hxx>
#include <XCAFDoc_VisMaterial.hxx>
#include <XCAFPrs.hxx>
#include <XCAFPrs_DocumentExplorer.hxx>
#include <XCAFPrs_IndexedDataMapOfShapeStyle.hxx>
#include <XCAFPrs_Style.hxx>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <exception>
#include <limits>
#include <string>
#include <unordered_map>
#include <vector>

namespace {

constexpr uint32_t kArchiveVersion = 4;
constexpr uint32_t kLinearSRGBColorEncoding = 1;
constexpr double kAngularDeflection = 12.0 * M_PI / 180.0;
// Past roughly 45 degrees a cylinder reads as an octagon, which is a worse
// answer than an honest refusal.
constexpr double kMaximumAngularDeflection = 45.0 * M_PI / 180.0;
constexpr uint64_t kMaximumDefinitions = 20'000;
constexpr uint64_t kMaximumOccurrences = 200'000;
constexpr uint64_t kMaximumHierarchyNodes = 250'000;

// Graceful degradation tiers. Each retry multiplies the linear deflections by
// this factor, which is the ratio between the shared budget's own small,
// medium, and large tiers, so a coarsened preview looks like one the next size
// class would have produced rather than an arbitrary reduction.
constexpr double kSimplificationDeflectionFactor = 4.0;
// Linear deflection alone does not reduce a curved face below what angular
// deflection demands, and an assembly of many small curved faces is exactly the
// case that overruns the mesh budget. Measured on the local corpus: coarsening
// only the linear terms left two 60+ MB assemblies failing at the identical
// triangle count. Each retry therefore also relaxes the angle.
constexpr double kSimplificationAngularFactor = 2.0;
constexpr int kMaximumSimplificationLevel = 2;
// Archive header flag bits.
constexpr uint32_t kArchiveFlagIncompleteGeometry = 1;
constexpr uint32_t kArchiveFlagExplicitLengthUnit = 2;
constexpr uint32_t kArchiveFlagSimplified = 4;
constexpr size_t kMaximumMetadataStringBytes = 64 * 1'024;
constexpr uint32_t kNoIndex = UINT32_MAX;

enum class ImportErrorCode : NSInteger {
    unreadable = 1,
    transferFailed = 2,
    emptyGeometry = 3,
    tooComplex = 4,
    importerFailure = 5,
};

struct Float3 { float x, y, z; };

struct MaterialGroup {
    uint32_t indexOffset = 0;
    uint32_t indexCount = 0;
    bool hasFaceColor = false;
    std::array<float, 4> linearColor{0.72f, 0.74f, 0.77f, 1.0f};
};

struct Mesh {
    std::string stableID;
    std::string name;
    std::vector<Float3> positions;
    std::vector<Float3> normals;
    std::vector<uint32_t> indices;
    std::vector<MaterialGroup> materialGroups;
    std::array<float, 6> bounds{};
    uint32_t faceCount = 0;
    uint32_t missingFaceCount = 0;
};

struct Occurrence {
    uint32_t nodeIndex = kNoIndex;
    uint32_t definitionIndex = 0;
    std::array<float, 12> transform{};
    bool hasColor = false;
    std::array<float, 4> color{0.72f, 0.74f, 0.77f, 1.0f};
};

struct HierarchyNode {
    std::string stableID;
    std::string name;
    uint32_t parentIndex = kNoIndex;
    uint32_t definitionIndex = kNoIndex;
    bool isAssembly = false;
    std::array<float, 12> localTransform{};
};

class PreviewLimitExceeded final : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

struct XCAFDocumentScope {
    Handle(XCAFApp_Application) application;
    Handle(TDocStd_Document) document;

    ~XCAFDocumentScope() { close(); }

    void close() {
        if (!document.IsNull()) {
            application->Close(document);
            document.Nullify();
        }
    }
};

NSError *MakeError(ImportErrorCode code, NSString *description, NSString *detail = nil) {
    NSMutableDictionary *info = [@{NSLocalizedDescriptionKey: description} mutableCopy];
    if (detail.length > 0) info[NSLocalizedFailureReasonErrorKey] = detail;
    return [NSError errorWithDomain:@"com.local.stepviewer.import"
                               code:static_cast<NSInteger>(code)
                           userInfo:info];
}

void AppendUInt32(NSMutableData *data, uint32_t value) {
    const uint32_t little = CFSwapInt32HostToLittle(value);
    [data appendBytes:&little length:sizeof(little)];
}

void AppendFloat(NSMutableData *data, float value) {
    uint32_t bits = 0;
    static_assert(sizeof(bits) == sizeof(value));
    std::memcpy(&bits, &value, sizeof(bits));
    AppendUInt32(data, bits);
}

void AppendDouble(NSMutableData *data, double value) {
    uint64_t bits = 0;
    static_assert(sizeof(bits) == sizeof(value));
    std::memcpy(&bits, &value, sizeof(bits));
    bits = CFSwapInt64HostToLittle(bits);
    [data appendBytes:&bits length:sizeof(bits)];
}

void AppendString(NSMutableData *data, const std::string &value) {
    if (value.size() > kMaximumMetadataStringBytes || value.size() > UINT32_MAX) {
        throw PreviewLimitExceeded("Model metadata exceeded the preview string budget.");
    }
    AppendUInt32(data, static_cast<uint32_t>(value.size()));
    [data appendBytes:value.data() length:value.size()];
}

double SecondsSince(const std::chrono::steady_clock::time_point &start) {
    return std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
}

std::string LabelID(const TDF_Label &label) {
    TCollection_AsciiString entry;
    TDF_Tool::Entry(label, entry);
    return entry.ToCString();
}

std::string LabelName(const TDF_Label &label) {
    std::string value = stepviewer::xcaf::LabelNameUTF8(label);
    if (value.size() > kMaximumMetadataStringBytes) {
        throw PreviewLimitExceeded("Model metadata exceeded the preview string budget.");
    }
    return value;
}

std::array<float, 12> TransformArray(const TopLoc_Location &location) {
    std::array<float, 12> result{};
    const gp_Trsf &transform = location.Transformation();
    for (int row = 1; row <= 3; ++row) {
        for (int column = 1; column <= 4; ++column) {
            const double value = transform.Value(row, column);
            if (!std::isfinite(value)
                || value > std::numeric_limits<float>::max()
                || value < -std::numeric_limits<float>::max()) {
                throw std::runtime_error("A component transform was not finite.");
            }
            result[(row - 1) * 4 + column - 1] = static_cast<float>(value);
        }
    }
    return result;
}

double ShapeDiagonal(const TopoDS_Shape &shape) {
    Bnd_Box box;
    BRepBndLib::Add(shape, box, Standard_False);
    if (!box.IsVoid() && !box.IsOpen()) {
        Standard_Real xmin, ymin, zmin, xmax, ymax, zmax;
        box.Get(xmin, ymin, zmin, xmax, ymax, zmax);
        return std::hypot(std::hypot(xmax - xmin, ymax - ymin), zmax - zmin);
    }

    double xmin = std::numeric_limits<double>::max();
    double ymin = std::numeric_limits<double>::max();
    double zmin = std::numeric_limits<double>::max();
    double xmax = -std::numeric_limits<double>::max();
    double ymax = -std::numeric_limits<double>::max();
    double zmax = -std::numeric_limits<double>::max();
    bool foundVertex = false;
    for (TopExp_Explorer explorer(shape, TopAbs_VERTEX); explorer.More(); explorer.Next()) {
        const gp_Pnt point = BRep_Tool::Pnt(TopoDS::Vertex(explorer.Current()));
        if (!std::isfinite(point.X()) || !std::isfinite(point.Y()) || !std::isfinite(point.Z())) continue;
        foundVertex = true;
        xmin = std::min(xmin, point.X());
        ymin = std::min(ymin, point.Y());
        zmin = std::min(zmin, point.Z());
        xmax = std::max(xmax, point.X());
        ymax = std::max(ymax, point.Y());
        zmax = std::max(zmax, point.Z());
    }
    return foundVertex ? std::hypot(std::hypot(xmax - xmin, ymax - ymin), zmax - zmin) : 0;
}

bool StyleLinearColor(const XCAFPrs_Style &style, std::array<float, 4> &result) {
    Quantity_ColorRGBA rgba;
    if (!stepviewer::xcaf::SourceColor(style, rgba)) return false;
    const Quantity_Color &rgb = rgba.GetRGB();
    result = {static_cast<float>(rgb.Red()), static_cast<float>(rgb.Green()),
              static_cast<float>(rgb.Blue()), static_cast<float>(rgba.Alpha())};
    return true;
}

void CollectInheritedFaceColors(const TopoDS_Shape &shape,
                                const XCAFPrs_IndexedDataMapOfShapeStyle &styles,
                                bool applyShapeStyle,
                                bool hasInheritedColor,
                                const std::array<float, 4> &inheritedColor,
                                TopTools_DataMapOfShapeInteger &colorIndexByFace,
                                std::vector<std::array<float, 4>> &colors) {
    bool hasColor = hasInheritedColor;
    std::array<float, 4> color = inheritedColor;
    if (applyShapeStyle && styles.Contains(shape)) {
        std::array<float, 4> shapeColor;
        if (StyleLinearColor(styles.FindFromKey(shape), shapeColor)) {
            hasColor = true;
            color = shapeColor;
        }
    }

    if (shape.ShapeType() == TopAbs_FACE) {
        if (hasColor) {
            const Standard_Integer colorIndex = static_cast<Standard_Integer>(colors.size());
            colors.push_back(color);
            if (colorIndexByFace.IsBound(shape)) {
                colorIndexByFace.ChangeFind(shape) = colorIndex;
            } else {
                colorIndexByFace.Bind(shape, colorIndex);
            }
        }
        return;
    }

    for (TopoDS_Iterator child(shape); child.More(); child.Next()) {
        CollectInheritedFaceColors(child.Value(), styles, true, hasColor, color,
                                   colorIndexByFace, colors);
    }
}

void AppendMaterialGroup(Mesh &mesh,
                         uint32_t indexOffset,
                         uint32_t indexCount,
                         bool hasFaceColor,
                         const std::array<float, 4> &linearColor) {
    if (!mesh.materialGroups.empty()) {
        MaterialGroup &previous = mesh.materialGroups.back();
        if (previous.indexOffset + previous.indexCount == indexOffset
            && previous.hasFaceColor == hasFaceColor
            && (!hasFaceColor || previous.linearColor == linearColor)) {
            previous.indexCount += indexCount;
            return;
        }
    }
    mesh.materialGroups.push_back({indexOffset, indexCount, hasFaceColor, linearColor});
}

Mesh Tessellate(const TopoDS_Shape &shape,
                const TDF_Label &definitionLabel,
                double relativeDeflection,
                double minimumDeflection,
                double maximumDeflection,
                double angularDeflection,
                uint64_t maximumTriangles,
                uint64_t maximumVertices,
                double &mesherSeconds,
                double &styleSeconds,
                double &extractSeconds) {
    const uint64_t maximumTopologyItems = maximumTriangles > (UINT64_MAX - 1'024) / 8
        ? UINT64_MAX : maximumTriangles * 8 + 1'024;
    uint64_t topologyItems = 0;
    for (TopAbs_ShapeEnum kind : {TopAbs_FACE, TopAbs_EDGE, TopAbs_VERTEX}) {
        for (TopExp_Explorer explorer(shape, kind); explorer.More(); explorer.Next()) {
            if (topologyItems == maximumTopologyItems) {
                throw PreviewLimitExceeded("The model exceeded the preview topology budget.");
            }
            ++topologyItems;
        }
    }

    const double diagonal = ShapeDiagonal(shape);
    if (!(diagonal > 0) || !std::isfinite(diagonal)) {
        throw std::runtime_error("A part has no finite bounds.");
    }

    IMeshTools_Parameters parameters;
    const double rawDeflection = diagonal * relativeDeflection;
    parameters.Deflection = std::clamp(rawDeflection,
                                       std::max(minimumDeflection, 1.0e-6),
                                       std::max(maximumDeflection, minimumDeflection));
    parameters.Angle = std::clamp(angularDeflection, kAngularDeflection,
                                  kMaximumAngularDeflection);
    parameters.Relative = Standard_False;
    // A retry asks for a deliberately worse mesh than the attempt before it.
    // OCCT's incremental mesher keeps an existing triangulation that already
    // satisfies the request, so without this a coarsening retry silently reuses
    // the finer mesh and fails at the identical triangle count.
    parameters.AllowQualityDecrease = Standard_True;
    // One helper performs one import at a time. Serial meshing avoids an
    // unbounded per-face worker fan-out and gives previews a predictable peak.
    parameters.InParallel = Standard_False;
    const auto mesherStart = std::chrono::steady_clock::now();
    BRepMesh_IncrementalMesh mesher(shape, parameters);
    mesherSeconds += SecondsSince(mesherStart);
    if (!mesher.IsDone()) throw std::runtime_error("OpenCascade tessellation did not complete.");

    const auto styleStart = std::chrono::steady_clock::now();
    XCAFPrs_IndexedDataMapOfShapeStyle styles;
    XCAFPrs::CollectStyleSettings(definitionLabel, TopLoc_Location(), styles);
    TopTools_DataMapOfShapeInteger colorIndexByFace;
    std::vector<std::array<float, 4>> faceColors;
    const std::array<float, 4> noColor{0, 0, 0, 0};
    // The definition root is the part-level fallback represented on each occurrence.
    // Only descendant subshape styles become explicit face overrides in the shared mesh.
    CollectInheritedFaceColors(shape, styles, false, false, noColor,
                               colorIndexByFace, faceColors);
    styleSeconds += SecondsSince(styleStart);

    const auto extractStart = std::chrono::steady_clock::now();
    Mesh mesh;
    uint64_t totalNodes = 0;
    uint64_t totalIndices = 0;
    for (TopExp_Explorer explorer(shape, TopAbs_FACE); explorer.More(); explorer.Next()) {
        TopLoc_Location faceLocation;
        const Handle(Poly_Triangulation) triangulation = BRep_Tool::Triangulation(
            TopoDS::Face(explorer.Current()), faceLocation);
        if (triangulation.IsNull()) continue;
        const uint64_t nodes = static_cast<uint64_t>(triangulation->NbNodes());
        const uint64_t triangles = static_cast<uint64_t>(triangulation->NbTriangles());
        if (nodes > maximumVertices - std::min(maximumVertices, totalNodes)
            || triangles > maximumTriangles - std::min(maximumTriangles, totalIndices / 3)
            || triangles > (std::numeric_limits<uint64_t>::max() - totalIndices) / 3) {
            throw PreviewLimitExceeded("Tessellation exceeded the preview mesh budget.");
        }
        totalNodes += nodes;
        totalIndices += triangles * 3;
    }
    if (totalNodes == 0 || totalIndices == 0
        || totalNodes > maximumVertices || totalIndices / 3 > maximumTriangles
        || totalNodes > UINT32_MAX || totalIndices > UINT32_MAX
        || totalNodes > std::numeric_limits<size_t>::max()
        || totalIndices > std::numeric_limits<size_t>::max()) {
        throw PreviewLimitExceeded("Tessellation exceeded the preview mesh budget.");
    }
    mesh.positions.reserve(static_cast<size_t>(totalNodes));
    mesh.normals.reserve(static_cast<size_t>(totalNodes));
    mesh.indices.reserve(static_cast<size_t>(totalIndices));
    Float3 minimum{std::numeric_limits<float>::max(), std::numeric_limits<float>::max(), std::numeric_limits<float>::max()};
    Float3 maximum{-std::numeric_limits<float>::max(), -std::numeric_limits<float>::max(), -std::numeric_limits<float>::max()};

    for (TopExp_Explorer explorer(shape, TopAbs_FACE); explorer.More(); explorer.Next()) {
        ++mesh.faceCount;
        const TopoDS_Face face = TopoDS::Face(explorer.Current());
        TopLoc_Location faceLocation;
        const Handle(Poly_Triangulation) triangulation = BRep_Tool::Triangulation(face, faceLocation);
        if (triangulation.IsNull() || triangulation->NbTriangles() == 0) {
            ++mesh.missingFaceCount;
            continue;
        }
        if (mesh.faceCount == UINT32_MAX) {
            throw PreviewLimitExceeded("The model exceeded the preview topology budget.");
        }
        if (!triangulation->HasNormals()) triangulation->ComputeNormals();

        const uint32_t base = static_cast<uint32_t>(mesh.positions.size());
        const gp_Trsf &faceTransform = faceLocation.Transformation();
        const bool reversed = face.Orientation() == TopAbs_REVERSED;
        for (Standard_Integer index = 1; index <= triangulation->NbNodes(); ++index) {
            const gp_Pnt point = triangulation->Node(index).Transformed(faceTransform);
            gp_Dir normal = triangulation->Normal(index);
            normal.Transform(faceTransform);
            if (reversed) normal.Reverse();
            const Float3 p{static_cast<float>(point.X()), static_cast<float>(point.Y()), static_cast<float>(point.Z())};
            mesh.positions.push_back(p);
            mesh.normals.push_back({static_cast<float>(normal.X()), static_cast<float>(normal.Y()), static_cast<float>(normal.Z())});
            minimum = {std::min(minimum.x, p.x), std::min(minimum.y, p.y), std::min(minimum.z, p.z)};
            maximum = {std::max(maximum.x, p.x), std::max(maximum.y, p.y), std::max(maximum.z, p.z)};
        }
        const uint32_t indexOffset = static_cast<uint32_t>(mesh.indices.size());
        for (Standard_Integer index = 1; index <= triangulation->NbTriangles(); ++index) {
            Standard_Integer a, b, c;
            triangulation->Triangle(index).Get(a, b, c);
            if (reversed) std::swap(b, c);
            mesh.indices.push_back(base + static_cast<uint32_t>(a - 1));
            mesh.indices.push_back(base + static_cast<uint32_t>(b - 1));
            mesh.indices.push_back(base + static_cast<uint32_t>(c - 1));
        }
        std::array<float, 4> faceColor{0.72f, 0.74f, 0.77f, 1.0f};
        const bool hasFaceColor = colorIndexByFace.IsBound(face);
        if (hasFaceColor) faceColor = faceColors[colorIndexByFace.Find(face)];
        AppendMaterialGroup(mesh, indexOffset,
                            static_cast<uint32_t>(mesh.indices.size()) - indexOffset,
                            hasFaceColor, faceColor);
    }
    if (mesh.indices.empty()) throw std::runtime_error("A part did not contain meshable faces.");
    mesh.bounds = {minimum.x, minimum.y, minimum.z, maximum.x, maximum.y, maximum.z};
    extractSeconds += SecondsSince(extractStart);
    return mesh;
}

Occurrence MakeOccurrence(const XCAFPrs_DocumentNode &node,
                          uint32_t nodeIndex,
                          uint32_t definitionIndex) {
    Occurrence occurrence;
    occurrence.nodeIndex = nodeIndex;
    occurrence.definitionIndex = definitionIndex;
    occurrence.transform = TransformArray(node.Location);
    // DocumentExplorer resolves inherited part and component-instance styles for this leaf.
    occurrence.hasColor = StyleLinearColor(node.Style, occurrence.color);
    return occurrence;
}

Float3 TransformPoint(const std::array<float, 12> &m, float x, float y, float z) {
    return {m[0] * x + m[1] * y + m[2] * z + m[3],
            m[4] * x + m[5] * y + m[6] * z + m[7],
            m[8] * x + m[9] * y + m[10] * z + m[11]};
}

} // namespace

@implementation StepMeshImporter

+ (nullable NSData *)importFileAtPath:(NSString *)path
                        maxTriangles:(NSUInteger)maxTriangles
                   relativeDeflection:(double)relativeDeflection
                   minimumDeflection:(double)minimumDeflection
                   maximumDeflection:(double)maximumDeflection
          startingSimplificationLevel:(NSUInteger)startingSimplificationLevel
                              metrics:(NSDictionary<NSString *, id> * _Nullable * _Nullable)metrics
                                error:(NSError * _Nullable * _Nullable)error {
    try {
        const auto parseStart = std::chrono::steady_clock::now();
        const Handle(XCAFApp_Application) application = XCAFApp_Application::GetApplication();
        Handle(TDocStd_Document) document;
        application->NewDocument("BinXCAF", document);
        XCAFDocumentScope documentScope{application, document};

        STEPCAFControl_Reader reader;
        reader.SetColorMode(Standard_True);
        reader.SetSHUOMode(Standard_False);
        reader.SetMatMode(Standard_False);
        reader.SetNameMode(Standard_True);
        reader.SetLayerMode(Standard_False);
        reader.SetPropsMode(Standard_False);
        reader.SetMetaMode(Standard_False);
        reader.SetProductMetaMode(Standard_False);
        reader.SetGDTMode(Standard_False);
        reader.SetViewMode(Standard_False);
        const auto readStart = std::chrono::steady_clock::now();
        DESTEP_Parameters readParameters;
        readParameters.InitFromStatic();
        readParameters.ReadName = true;
        readParameters.ReadLayer = false;
        readParameters.ReadProps = false;
        readParameters.ReadMetadata = false;
        readParameters.ReadProductMetadata = false;
        readParameters.ReadTessellated = DESTEP_Parameters::RWMode_Tessellated_OnNoBRep;
        if (reader.ReadFile(path.fileSystemRepresentation, readParameters) != IFSelect_RetDone) {
            if (error) *error = MakeError(ImportErrorCode::unreadable, @"This STEP file could not be read.");
            return nil;
        }
        const double readSeconds = SecondsSince(readStart);
        // Quick Look needs meshable faces, not a fully repaired editable B-rep.
        // Keep core shell/face repair while skipping expensive diagnostic cleanup.
        DE_ShapeFixParameters shapeFix = DESTEP_Parameters::GetDefaultShapeFixParameters();
        using FixMode = DE_ShapeFixParameters::FixMode;
        shapeFix.FixShellOrientationMode = FixMode::NotFix;
        shapeFix.FixFaceOrientationMode = FixMode::NotFix;
        shapeFix.FixSameParameterMode = FixMode::NotFix;
        shapeFix.FixSmallAreaWireMode = FixMode::NotFix;
        shapeFix.RemoveSmallAreaFaceMode = FixMode::NotFix;
        shapeFix.FixIntersectingWiresMode = FixMode::NotFix;
        shapeFix.FixLoopWiresMode = FixMode::NotFix;
        shapeFix.FixSplitFaceMode = FixMode::NotFix;
        shapeFix.FixSmallMode = FixMode::NotFix;
        shapeFix.FixConnectedMode = FixMode::NotFix;
        shapeFix.FixSelfIntersectionMode = FixMode::NotFix;
        shapeFix.FixNotchedEdgesMode = FixMode::NotFix;
        shapeFix.FixSelfIntersectingEdgeMode = FixMode::NotFix;
        shapeFix.FixIntersectingEdgesMode = FixMode::NotFix;
        shapeFix.FixNonAdjacentIntersectingEdgesMode = FixMode::NotFix;
        shapeFix.FixVertexToleranceMode = FixMode::NotFix;
        reader.SetShapeFixParameters(shapeFix);
        const auto transferStart = std::chrono::steady_clock::now();
        if (!reader.Transfer(document)) {
            if (error) *error = MakeError(ImportErrorCode::transferFailed, @"The STEP file did not contain transferable geometry.");
            return nil;
        }
        const double transferSeconds = SecondsSince(transferStart);
        const double parseSeconds = SecondsSince(parseStart);
        const auto meshStart = std::chrono::steady_clock::now();

        Standard_Real unitScaleToMeters = 0.001;
        const bool hasExplicitLengthUnit =
            XCAFDoc_DocumentTool::GetLengthUnit(document, unitScaleToMeters)
            && std::isfinite(unitScaleToMeters) && unitScaleToMeters > 0;
        if (!hasExplicitLengthUnit) unitScaleToMeters = 0.001;

        const Handle(XCAFDoc_ShapeTool) shapeTool = XCAFDoc_DocumentTool::ShapeTool(document->Main());
        std::unordered_map<std::string, uint32_t> definitionByID;
        std::unordered_map<std::string, uint32_t> nodeByID;
        std::vector<Mesh> definitions;
        std::vector<Occurrence> occurrences;
        std::vector<HierarchyNode> hierarchyNodes;
        uint64_t uniqueTriangleCount = 0;
        double mesherSeconds = 0;
        double styleSeconds = 0;
        double extractSeconds = 0;
        uint64_t displayedTriangles = 0;
        uint64_t totalFaces = 0;
        uint64_t missingFaces = 0;
        uint64_t materialGroups = 0;
        uint64_t coloredMaterialGroups = 0;
        Float3 globalMin{};
        Float3 globalMax{};

        // Graceful degradation. A mesh-budget overrun is a property of the
        // chosen tessellation, not of the source: the same document usually
        // fits comfortably one tier coarser. Only the mesh phase repeats — the
        // parse and XCAF transfer above dominate cost and are never redone —
        // and the service's deadline watchdog still bounds the whole attempt.
        // A coarsened result is marked simplified all the way to the badge so
        // it is never mistaken for exact geometry.
        int simplificationLevel = static_cast<int>(std::min<NSUInteger>(
            startingSimplificationLevel,
            static_cast<NSUInteger>(kMaximumSimplificationLevel)));
        for (;;) {
        const double simplificationScale =
            std::pow(kSimplificationDeflectionFactor, simplificationLevel);
        const double attemptRelativeDeflection = relativeDeflection * simplificationScale;
        const double attemptMinimumDeflection = minimumDeflection * simplificationScale;
        const double attemptMaximumDeflection = maximumDeflection * simplificationScale;
        const double attemptAngularDeflection = kAngularDeflection
            * std::pow(kSimplificationAngularFactor, simplificationLevel);
        definitionByID.clear();
        nodeByID.clear();
        definitions.clear();
        occurrences.clear();
        hierarchyNodes.clear();
        uniqueTriangleCount = 0;
        displayedTriangles = 0;
        totalFaces = 0;
        missingFaces = 0;
        materialGroups = 0;
        coloredMaterialGroups = 0;
        try {

        std::vector<uint32_t> nodeAtDepth;
        XCAFPrs_DocumentExplorer hierarchyExplorer(
            document, XCAFPrs_DocumentExplorerFlags_NoStyle);
        for (; hierarchyExplorer.More(); hierarchyExplorer.Next()) {
            if (hierarchyNodes.size() == kMaximumHierarchyNodes) {
                throw PreviewLimitExceeded("The assembly exceeded the preview hierarchy budget.");
            }
            const XCAFPrs_DocumentNode &source = hierarchyExplorer.Current();
            const Standard_Integer depth = hierarchyExplorer.CurrentDepth();
            if (depth < 0 || static_cast<size_t>(depth) > nodeAtDepth.size()) {
                throw std::runtime_error("The assembly hierarchy was not well formed.");
            }
            HierarchyNode node;
            node.stableID = source.Id.ToCString();
            node.name = LabelName(source.Label);
            if (node.name.empty() && !source.RefLabel.IsNull()) {
                node.name = LabelName(source.RefLabel);
            }
            node.parentIndex = depth == 0 ? kNoIndex : nodeAtDepth[depth - 1];
            node.isAssembly = source.IsAssembly;
            node.localTransform = TransformArray(source.LocalTrsf);
            const uint32_t nodeIndex = static_cast<uint32_t>(hierarchyNodes.size());
            if (!nodeByID.emplace(node.stableID, nodeIndex).second) {
                throw std::runtime_error("The assembly contained duplicate stable node identifiers.");
            }
            hierarchyNodes.push_back(std::move(node));
            nodeAtDepth.resize(static_cast<size_t>(depth) + 1);
            nodeAtDepth[depth] = nodeIndex;
        }

        // Count occurrence multiplicity before tessellating. A definition used
        // thousands of times consumes the displayed-triangle budget thousands
        // of times even though its vertex buffers are stored only once.
        std::unordered_map<std::string, uint64_t> occurrenceCountByDefinition;
        uint64_t occurrenceCount = 0;
        XCAFPrs_DocumentExplorer countingExplorer(
            document, XCAFPrs_DocumentExplorerFlags_OnlyLeafNodes);
        for (; countingExplorer.More(); countingExplorer.Next()) {
            if (occurrenceCount == kMaximumOccurrences) {
                throw PreviewLimitExceeded("The assembly exceeded the preview occurrence budget.");
            }
            ++occurrenceCount;
            const XCAFPrs_DocumentNode &node = countingExplorer.Current();
            const TDF_Label definitionLabel =
                stepviewer::xcaf::DefinitionLabel(node);
            const std::string id = LabelID(definitionLabel);
            auto [entry, inserted] = occurrenceCountByDefinition.emplace(id, 0);
            if (inserted && occurrenceCountByDefinition.size() > kMaximumDefinitions) {
                throw PreviewLimitExceeded("The assembly exceeded the preview definition budget.");
            }
            if (entry->second == std::numeric_limits<uint64_t>::max()) {
                throw PreviewLimitExceeded("The assembly occurrence count overflowed.");
            }
            ++entry->second;
        }

        uint64_t committedDisplayedTriangles = 0;
        XCAFPrs_DocumentExplorer explorer(
            document, XCAFPrs_DocumentExplorerFlags_OnlyLeafNodes);
        for (; explorer.More(); explorer.Next()) {
            const XCAFPrs_DocumentNode &node = explorer.Current();
            const TDF_Label definitionLabel =
                stepviewer::xcaf::DefinitionLabel(node);
            const std::string id = LabelID(definitionLabel);
            auto found = definitionByID.find(id);
            if (found == definitionByID.end()) {
                const uint64_t multiplicity = occurrenceCountByDefinition.at(id);
                const uint64_t remainingDisplayedTriangles =
                    static_cast<uint64_t>(maxTriangles) - committedDisplayedTriangles;
                const uint64_t definitionTriangleBudget =
                    remainingDisplayedTriangles / multiplicity;
                if (definitionTriangleBudget == 0) {
                    throw PreviewLimitExceeded("The assembly exceeded the preview triangle budget.");
                }
                const uint64_t definitionVertexBudget =
                    definitionTriangleBudget > UINT32_MAX / 3
                    ? UINT32_MAX : definitionTriangleBudget * 3;
                const TopoDS_Shape shape = shapeTool->GetShape(definitionLabel);
                if (shape.IsNull()) throw std::runtime_error("A referenced part has no shape.");
                Mesh mesh = Tessellate(shape, definitionLabel, attemptRelativeDeflection,
                                       attemptMinimumDeflection, attemptMaximumDeflection,
                                       attemptAngularDeflection,
                                       definitionTriangleBudget, definitionVertexBudget,
                                       mesherSeconds, styleSeconds, extractSeconds);
                mesh.stableID = id;
                mesh.name = LabelName(definitionLabel);
                const uint64_t definitionTriangles = mesh.indices.size() / 3;
                uniqueTriangleCount += definitionTriangles;
                committedDisplayedTriangles += definitionTriangles * multiplicity;
                const uint32_t index = static_cast<uint32_t>(definitions.size());
                definitions.push_back(std::move(mesh));
                found = definitionByID.emplace(id, index).first;
            }
            const auto nodeEntry = nodeByID.find(node.Id.ToCString());
            if (nodeEntry == nodeByID.end()) {
                throw std::runtime_error("A visible occurrence was missing from the hierarchy.");
            }
            occurrences.push_back(MakeOccurrence(node, nodeEntry->second, found->second));
        }

        if (definitions.empty() || occurrences.empty()) {
            if (error) *error = MakeError(ImportErrorCode::emptyGeometry, @"The STEP file did not contain visible geometry.");
            return nil;
        }

        for (const Occurrence &occurrence : occurrences) {
            HierarchyNode &node = hierarchyNodes[occurrence.nodeIndex];
            if (node.definitionIndex != kNoIndex
                && node.definitionIndex != occurrence.definitionIndex) {
                throw std::runtime_error("A hierarchy node referenced conflicting definitions.");
            }
            node.definitionIndex = occurrence.definitionIndex;
        }

        for (const Mesh &mesh : definitions) {
            totalFaces += mesh.faceCount;
            missingFaces += mesh.missingFaceCount;
            materialGroups += mesh.materialGroups.size();
            coloredMaterialGroups += std::count_if(
                mesh.materialGroups.begin(), mesh.materialGroups.end(),
                [](const MaterialGroup &group) { return group.hasFaceColor; });
        }
        if (totalFaces > UINT32_MAX || missingFaces > UINT32_MAX) {
            throw PreviewLimitExceeded("The model exceeded the preview face budget.");
        }
        for (const Occurrence &occurrence : occurrences) {
            displayedTriangles += definitions[occurrence.definitionIndex].indices.size() / 3;
            if (displayedTriangles > maxTriangles || displayedTriangles > UINT32_MAX) {
                // Retryable: this is the budget the coarser tier exists for.
                throw PreviewLimitExceeded(
                    "The assembly exceeded the displayed triangle budget.");
            }
        }
        if (displayedTriangles != committedDisplayedTriangles) {
            throw std::runtime_error("The assembly triangle accounting was inconsistent.");
        }

        globalMin = {std::numeric_limits<float>::max(), std::numeric_limits<float>::max(), std::numeric_limits<float>::max()};
        globalMax = {-std::numeric_limits<float>::max(), -std::numeric_limits<float>::max(), -std::numeric_limits<float>::max()};
        for (const Occurrence &occurrence : occurrences) {
            const auto &b = definitions[occurrence.definitionIndex].bounds;
            for (int corner = 0; corner < 8; ++corner) {
                const Float3 p = TransformPoint(occurrence.transform,
                    (corner & 1) ? b[3] : b[0], (corner & 2) ? b[4] : b[1], (corner & 4) ? b[5] : b[2]);
                globalMin = {std::min(globalMin.x, p.x), std::min(globalMin.y, p.y), std::min(globalMin.z, p.z)};
                globalMax = {std::max(globalMax.x, p.x), std::max(globalMax.y, p.y), std::max(globalMax.z, p.z)};
            }
        }

        } catch (const PreviewLimitExceeded &limit) {
            if (simplificationLevel >= kMaximumSimplificationLevel) throw;
            ++simplificationLevel;
            continue;
        }
        break;
        }

        const double meshSeconds = SecondsSince(meshStart);
        const auto serializeStart = std::chrono::steady_clock::now();
        NSMutableData *archive = [NSMutableData data];
        const char magic[4] = {'S', 'T', 'L', 'K'};
        [archive appendBytes:magic length:4];
        AppendUInt32(archive, kArchiveVersion);
        const uint32_t archiveFlags =
            (missingFaces > 0 ? kArchiveFlagIncompleteGeometry : 0u)
            | (hasExplicitLengthUnit ? kArchiveFlagExplicitLengthUnit : 0u)
            | (simplificationLevel > 0 ? kArchiveFlagSimplified : 0u);
        AppendUInt32(archive, archiveFlags);
        AppendUInt32(archive, static_cast<uint32_t>(definitions.size()));
        AppendUInt32(archive, static_cast<uint32_t>(occurrences.size()));
        AppendUInt32(archive, static_cast<uint32_t>(hierarchyNodes.size()));
        AppendUInt32(archive, static_cast<uint32_t>(displayedTriangles));
        AppendUInt32(archive, static_cast<uint32_t>(totalFaces));
        AppendUInt32(archive, static_cast<uint32_t>(missingFaces));
        AppendUInt32(archive, kLinearSRGBColorEncoding);
        for (float value : {globalMin.x, globalMin.y, globalMin.z, globalMax.x, globalMax.y, globalMax.z}) AppendFloat(archive, value);
        AppendDouble(archive, parseSeconds);
        AppendDouble(archive, meshSeconds);
        AppendDouble(archive, unitScaleToMeters);

        for (const Mesh &mesh : definitions) {
            AppendString(archive, mesh.stableID);
            AppendString(archive, mesh.name);
            AppendUInt32(archive, static_cast<uint32_t>(mesh.positions.size()));
            AppendUInt32(archive, static_cast<uint32_t>(mesh.indices.size()));
            AppendUInt32(archive, static_cast<uint32_t>(mesh.materialGroups.size()));
            for (float value : mesh.bounds) AppendFloat(archive, value);
            static_assert(sizeof(Float3) == 3 * sizeof(float));
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
            [archive appendBytes:mesh.positions.data()
                           length:mesh.positions.size() * sizeof(Float3)];
            [archive appendBytes:mesh.normals.data()
                           length:mesh.normals.size() * sizeof(Float3)];
            [archive appendBytes:mesh.indices.data()
                           length:mesh.indices.size() * sizeof(uint32_t)];
#else
            for (const Float3 &p : mesh.positions) { AppendFloat(archive, p.x); AppendFloat(archive, p.y); AppendFloat(archive, p.z); }
            for (const Float3 &n : mesh.normals) { AppendFloat(archive, n.x); AppendFloat(archive, n.y); AppendFloat(archive, n.z); }
            for (uint32_t index : mesh.indices) AppendUInt32(archive, index);
#endif
            for (const MaterialGroup &group : mesh.materialGroups) {
                AppendUInt32(archive, group.indexOffset);
                AppendUInt32(archive, group.indexCount);
                AppendUInt32(archive, group.hasFaceColor ? 1u : 0u);
                for (float value : group.linearColor) AppendFloat(archive, value);
            }
        }
        for (const Occurrence &occurrence : occurrences) {
            AppendUInt32(archive, occurrence.nodeIndex);
            AppendUInt32(archive, occurrence.definitionIndex);
            AppendUInt32(archive, occurrence.hasColor ? 1u : 0u);
            for (float value : occurrence.transform) AppendFloat(archive, value);
            for (float value : occurrence.color) AppendFloat(archive, value);
        }
        for (const HierarchyNode &node : hierarchyNodes) {
            AppendString(archive, node.stableID);
            AppendString(archive, node.name);
            AppendUInt32(archive, node.parentIndex);
            AppendUInt32(archive, node.definitionIndex);
            AppendUInt32(archive, node.isAssembly ? 1u : 0u);
            for (float value : node.localTransform) AppendFloat(archive, value);
        }

        const double serializeSeconds = SecondsSince(serializeStart);
        const auto closeStart = std::chrono::steady_clock::now();
        documentScope.close();
        const double closeSeconds = SecondsSince(closeStart);
        if (metrics) {
            *metrics = @{@"parseSeconds": @(parseSeconds), @"readSeconds": @(readSeconds),
                         @"transferSeconds": @(transferSeconds), @"meshSeconds": @(meshSeconds),
                         @"mesherSeconds": @(mesherSeconds), @"styleSeconds": @(styleSeconds),
                         @"extractSeconds": @(extractSeconds), @"serializeSeconds": @(serializeSeconds),
                         @"closeSeconds": @(closeSeconds), @"totalSeconds": @(SecondsSince(parseStart)),
                         @"triangles": @(displayedTriangles), @"uniqueTriangles": @(uniqueTriangleCount),
                         @"faces": @(totalFaces), @"missingFaces": @(missingFaces),
                         @"materialGroups": @(materialGroups),
                         @"coloredMaterialGroups": @(coloredMaterialGroups),
                         @"definitions": @(definitions.size()), @"occurrences": @(occurrences.size()),
                         @"hierarchyNodes": @(hierarchyNodes.size()),
                         @"unitScaleToMeters": @(unitScaleToMeters),
                         @"hasExplicitLengthUnit": @(hasExplicitLengthUnit),
                         @"simplificationLevel": @(simplificationLevel),
                         @"archiveBytes": @(archive.length)};
        }
        return archive;
    } catch (const PreviewLimitExceeded &exception) {
        if (error) {
            *error = MakeError(
                ImportErrorCode::tooComplex,
                @"This assembly is too complex for the current preview limit.",
                [NSString stringWithUTF8String:exception.what()]);
        }
    } catch (const Standard_Failure &failure) {
        if (error) {
            NSString *detail = failure.GetMessageString() ? [NSString stringWithUTF8String:failure.GetMessageString()] : nil;
            *error = MakeError(ImportErrorCode::importerFailure, @"The STEP importer stopped unexpectedly.", detail);
        }
    } catch (const std::exception &exception) {
        if (error) *error = MakeError(ImportErrorCode::importerFailure, @"The STEP importer stopped unexpectedly.", [NSString stringWithUTF8String:exception.what()]);
    } catch (...) {
        if (error) *error = MakeError(ImportErrorCode::importerFailure, @"The STEP importer stopped unexpectedly.");
    }
    return nil;
}

@end
