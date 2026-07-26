#pragma once

#include <Quantity_ColorRGBA.hxx>
#include <TCollection_ExtendedString.hxx>
#include <TDataStd_Name.hxx>
#include <TDF_Label.hxx>
#include <XCAFDoc_VisMaterial.hxx>
#include <XCAFPrs_DocumentExplorer.hxx>
#include <XCAFPrs_Style.hxx>

#include <string>
#include <vector>

// Product-independent XCAF interpretation shared by LookSTEP's mesh importer
// and Caliper's exact-document importer. Output policy remains consumer-owned:
// LookSTEP may simplify or retain incomplete tessellation diagnostics, while
// Caliper retains exact XCAF/B-rep ownership and fails incomplete documents.
namespace stepviewer::xcaf {

inline std::u16string LabelNameUTF16(const TDF_Label &label) {
    if (label.IsNull()) return {};
    Handle(TDataStd_Name) attribute;
    if (!label.FindAttribute(TDataStd_Name::GetID(), attribute)
        || attribute.IsNull()) {
        return {};
    }
    const TCollection_ExtendedString &name = attribute->Get();
    if (name.IsEmpty()) return {};
    const auto *characters =
        reinterpret_cast<const char16_t *>(name.ToExtString());
    return {characters, characters + name.Length()};
}

inline std::string LabelNameUTF8(const TDF_Label &label) {
    Handle(TDataStd_Name) attribute;
    if (label.IsNull()
        || !label.FindAttribute(TDataStd_Name::GetID(), attribute)
        || attribute.IsNull()) {
        return {};
    }
    const TCollection_ExtendedString &value = attribute->Get();
    const Standard_Integer length = value.LengthOfCString();
    if (length <= 0) return {};
    std::vector<char> buffer(static_cast<std::size_t>(length) + 1, '\0');
    Standard_PCharacter destination = buffer.data();
    const Standard_Integer written = value.ToUTF8CString(destination);
    return written > 0
        ? std::string(buffer.data(), static_cast<std::size_t>(written))
        : std::string{};
}

inline bool SourceColor(
    const XCAFPrs_Style &style,
    Quantity_ColorRGBA &color) {
    if (style.IsSetColorSurf()) {
        color = style.GetColorSurfRGBA();
        return true;
    }
    if (!style.Material().IsNull()
        && (style.Material()->HasPbrMaterial()
            || style.Material()->HasCommonMaterial())) {
        color = style.Material()->BaseColor();
        return true;
    }
    return false;
}

inline TDF_Label DefinitionLabel(const XCAFPrs_DocumentNode &node) {
    return node.RefLabel.IsNull() ? node.Label : node.RefLabel;
}

} // namespace stepviewer::xcaf
