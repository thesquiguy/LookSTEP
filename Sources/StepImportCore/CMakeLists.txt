cmake_minimum_required(VERSION 3.25)

project(StepImportCore LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# OpenCascade is intentionally kept behind the importer boundary. The XPC
# service will consume this core; Finder rendering must not depend on OCCT.
find_package(OpenCASCADE REQUIRED)

add_executable(step-import-smoke step_import_smoke.cpp)
target_link_libraries(step-import-smoke PRIVATE TKDESTEP)

# Homebrew's OCCT dylibs use @rpath for their transitive links. Use the
# discovered package location for this local developer smoke executable.
set_target_properties(step-import-smoke PROPERTIES
    BUILD_RPATH "${OpenCASCADE_LIBRARY_DIR}"
)
