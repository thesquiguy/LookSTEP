#include <STEPControl_Reader.hxx>
#include <IFSelect_ReturnStatus.hxx>
#include <TopAbs_ShapeEnum.hxx>
#include <TopExp_Explorer.hxx>
#include <TopoDS_Shape.hxx>

#include <cstdlib>
#include <iostream>

int main(int argc, char* argv[]) {
    if (argc != 2) {
        std::cerr << "usage: step-import-smoke <file.step>\n";
        return EXIT_FAILURE;
    }

    STEPControl_Reader reader;
    const IFSelect_ReturnStatus status = reader.ReadFile(argv[1]);
    if (status != IFSelect_RetDone) {
        std::cerr << "STEP read failed with status " << static_cast<int>(status) << "\n";
        return EXIT_FAILURE;
    }

    if (reader.TransferRoots() == 0) {
        std::cerr << "STEP read produced no transferable roots\n";
        return EXIT_FAILURE;
    }

    const TopoDS_Shape shape = reader.OneShape();
    if (shape.IsNull()) {
        std::cerr << "STEP read produced a null shape\n";
        return EXIT_FAILURE;
    }

    int solids = 0;
    int faces = 0;
    for (TopExp_Explorer explorer(shape, TopAbs_SOLID); explorer.More(); explorer.Next()) {
        ++solids;
    }
    for (TopExp_Explorer explorer(shape, TopAbs_FACE); explorer.More(); explorer.Next()) {
        ++faces;
    }

    std::cout << "STEP import OK: solids=" << solids << " faces=" << faces << "\n";
    return EXIT_SUCCESS;
}
