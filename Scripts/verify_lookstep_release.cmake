if(NOT DEFINED APP_BUNDLE)
    message(FATAL_ERROR "APP_BUNDLE is required")
endif()
if(NOT DEFINED EXPECT_TEAM_SIGNING)
    message(FATAL_ERROR "EXPECT_TEAM_SIGNING is required")
endif()

get_filename_component(repository_root "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
include("${CMAKE_CURRENT_LIST_DIR}/verify_third_party_notices.cmake")

set(preview_bundle
    "${APP_BUNDLE}/Contents/PlugIns/StepLookPreview.appex")
set(thumbnail_bundle
    "${APP_BUNDLE}/Contents/PlugIns/StepLookThumbnail.appex")

if(NOT IS_DIRECTORY "${APP_BUNDLE}")
    message(FATAL_ERROR "LookSTEP app bundle does not exist: ${APP_BUNDLE}")
endif()
if(NOT IS_DIRECTORY "${preview_bundle}")
    message(FATAL_ERROR "LookSTEP must embed its Finder Preview extension")
endif()
if(IS_DIRECTORY "${thumbnail_bundle}")
    message(FATAL_ERROR "LookSTEP Release must not embed the thumbnail experiment")
endif()

function(require_macos26_bundle bundle binary role)
    set(info_plist "${bundle}/Contents/Info.plist")
    execute_process(
        COMMAND /usr/bin/plutil
            -extract LSMinimumSystemVersion raw -o - "${info_plist}"
        RESULT_VARIABLE plist_status
        OUTPUT_VARIABLE minimum_system
        ERROR_VARIABLE plist_error
        OUTPUT_STRIP_TRAILING_WHITESPACE
    )
    if(NOT plist_status EQUAL 0 OR NOT minimum_system STREQUAL "26.0")
        message(FATAL_ERROR
            "${role} must require macOS 26.0 in Info.plist; "
            "found '${minimum_system}': ${plist_error}")
    endif()

    execute_process(
        COMMAND /usr/bin/lipo -archs "${binary}"
        RESULT_VARIABLE architecture_status
        OUTPUT_VARIABLE architectures
        ERROR_VARIABLE architecture_error
        OUTPUT_STRIP_TRAILING_WHITESPACE
    )
    if(NOT architecture_status EQUAL 0 OR NOT architectures STREQUAL "arm64")
        message(FATAL_ERROR
            "${role} must ship as Apple Silicon arm64 only; "
            "found '${architectures}': ${architecture_error}")
    endif()

    execute_process(
        COMMAND /usr/bin/xcrun vtool -show-build "${binary}"
        RESULT_VARIABLE build_status
        OUTPUT_VARIABLE build_details
        ERROR_VARIABLE build_error
    )
    if(NOT build_status EQUAL 0
       OR NOT build_details MATCHES
          "platform MACOS[\n\r\t ]+minos 26\\.0([\n\r\t ]|$)")
        message(FATAL_ERROR
            "${role} Mach-O must target macOS 26.0: "
            "${build_details}${build_error}")
    endif()
endfunction()

function(require_signpost binary role)
    execute_process(
        COMMAND /usr/bin/nm -u "${binary}"
        RESULT_VARIABLE nm_status
        OUTPUT_VARIABLE nm_output
        ERROR_VARIABLE nm_error
    )
    if(NOT nm_status EQUAL 0)
        message(FATAL_ERROR
            "Could not inspect ${role} telemetry symbols: ${nm_error}")
    endif()
    if(NOT nm_output MATCHES "__os_signpost_emit_with_name_impl")
        message(FATAL_ERROR
            "${role} must emit Apple performance signposts")
    endif()
endfunction()

execute_process(
    COMMAND /usr/bin/codesign --verify --deep --strict "${APP_BUNDLE}"
    RESULT_VARIABLE deep_verify_status
    OUTPUT_VARIABLE deep_verify_output
    ERROR_VARIABLE deep_verify_error
)
if(NOT deep_verify_status EQUAL 0)
    message(FATAL_ERROR
        "LookSTEP must pass strict deep signature verification: "
        "${deep_verify_output}${deep_verify_error}")
endif()

function(inspect_sandboxed_bundle bundle role require_group)
    execute_process(
        COMMAND /usr/bin/codesign --verify --strict "${bundle}"
        RESULT_VARIABLE verify_status
        OUTPUT_VARIABLE verify_output
        ERROR_VARIABLE verify_error
    )
    if(NOT verify_status EQUAL 0)
        message(FATAL_ERROR
            "${role} must pass strict signature verification: "
            "${verify_output}${verify_error}")
    endif()

    execute_process(
        COMMAND /usr/bin/codesign -d --verbose=4 "${bundle}"
        RESULT_VARIABLE details_status
        OUTPUT_VARIABLE details_output
        ERROR_VARIABLE details_error
    )
    if(NOT details_status EQUAL 0)
        message(FATAL_ERROR "Could not inspect ${role} signing details")
    endif()
    set(signing_details "${details_output}${details_error}")
    if(NOT signing_details MATCHES "flags=[^\n]*\\(.*runtime.*\\)")
        message(FATAL_ERROR "${role} must enable the hardened runtime")
    endif()
    string(REGEX MATCH "TeamIdentifier=([^\n]+)" team_match "${signing_details}")
    set(team "${CMAKE_MATCH_1}")
    if(EXPECT_TEAM_SIGNING AND (team STREQUAL "" OR team STREQUAL "not set"))
        message(FATAL_ERROR "${role} must have a TeamIdentifier")
    endif()

    execute_process(
        COMMAND /usr/bin/codesign -d --entitlements - "${bundle}"
        RESULT_VARIABLE entitlement_status
        OUTPUT_VARIABLE entitlement_output
        ERROR_VARIABLE entitlement_error
    )
    if(NOT entitlement_status EQUAL 0)
        message(FATAL_ERROR "Could not inspect ${role} entitlements")
    endif()
    set(entitlements "${entitlement_output}${entitlement_error}")
    if(NOT entitlements MATCHES "com\\.apple\\.security\\.app-sandbox")
        message(FATAL_ERROR "${role} must opt into App Sandbox")
    endif()
    if(entitlements MATCHES "com\\.apple\\.security\\.get-task-allow")
        message(FATAL_ERROR "${role} Release must not contain get-task-allow")
    endif()

    set(group "")
    if(require_group)
        string(REGEX MATCH
            "<key>com\\.apple\\.security\\.application-groups</key>[\n\r\t ]*<array>[\n\r\t ]*<string>([^<]+)</string>"
            group_match "${entitlements}")
        set(group "${CMAKE_MATCH_1}")
        if(group STREQUAL "")
            string(REGEX MATCH
                "\\[Key\\] com\\.apple\\.security\\.application-groups[\n\r\t ]*\\[Value\\][\n\r\t ]*\\[Array\\][\n\r\t ]*\\[String\\] ([^\n\r]+)"
                group_match "${entitlements}")
            set(group "${CMAKE_MATCH_1}")
        endif()
        # A team-signed release must share one real App Group. An unsigned
        # ad-hoc build has no Team ID to derive one and deliberately uses the
        # sandbox-local cache fallback, so structural mode accepts a group-less
        # bundle while still requiring host/preview consistency below.
        if(group STREQUAL "" AND EXPECT_TEAM_SIGNING)
            message(FATAL_ERROR "${role} must contain an application group")
        endif()
    endif()

    set("${role}_TEAM" "${team}" PARENT_SCOPE)
    set("${role}_GROUP" "${group}" PARENT_SCOPE)
endfunction()

inspect_sandboxed_bundle("${APP_BUNDLE}" host TRUE)
inspect_sandboxed_bundle("${preview_bundle}" preview TRUE)
require_macos26_bundle(
    "${APP_BUNDLE}"
    "${APP_BUNDLE}/Contents/MacOS/LookSTEP"
    "LookSTEP host")
require_macos26_bundle(
    "${preview_bundle}"
    "${preview_bundle}/Contents/MacOS/StepLookPreview"
    "Finder Preview")
require_signpost(
    "${APP_BUNDLE}/Contents/MacOS/LookSTEP"
    "LookSTEP host")
require_signpost(
    "${preview_bundle}/Contents/MacOS/StepLookPreview"
    "Finder Preview")
if(NOT host_GROUP STREQUAL preview_GROUP)
    message(FATAL_ERROR
        "LookSTEP host and Finder Preview must use the same application group")
endif()
if(EXPECT_TEAM_SIGNING AND NOT host_TEAM STREQUAL preview_TEAM)
    message(FATAL_ERROR
        "LookSTEP host and Finder Preview TeamIdentifiers must match")
endif()

file(GLOB_RECURSE xpc_bundles LIST_DIRECTORIES TRUE
    "${APP_BUNDLE}/Contents/*.xpc")
list(FILTER xpc_bundles INCLUDE REGEX "\\.xpc$")
list(LENGTH xpc_bundles xpc_count)
if(NOT xpc_count EQUAL 2)
    message(FATAL_ERROR
        "LookSTEP must contain one import service for the host and one for "
        "Finder Preview; found ${xpc_count}")
endif()

set(xpc_index 0)
foreach(xpc_bundle IN LISTS xpc_bundles)
    math(EXPR xpc_index "${xpc_index} + 1")
    set(role "xpc${xpc_index}")
    inspect_sandboxed_bundle("${xpc_bundle}" "${role}" FALSE)
    require_macos26_bundle(
        "${xpc_bundle}"
        "${xpc_bundle}/Contents/MacOS/StepImportService"
        "LookSTEP ${role}")
    require_signpost(
        "${xpc_bundle}/Contents/MacOS/StepImportService"
        "LookSTEP ${role}")
    verify_third_party_release(
        "${xpc_bundle}/Contents/Resources"
        "${xpc_bundle}/Contents/Frameworks"
        "${repository_root}"
        "LookSTEP ${role}")
    if(EXPECT_TEAM_SIGNING AND NOT "${${role}_TEAM}" STREQUAL host_TEAM)
        message(FATAL_ERROR
            "Import service TeamIdentifier does not match LookSTEP: ${xpc_bundle}")
    endif()
endforeach()

file(GLOB_RECURSE framework_libraries "${APP_BUNDLE}/Contents/*.dylib")
if(framework_libraries STREQUAL "")
    message(FATAL_ERROR "LookSTEP must contain its redistributable dylib closure")
endif()
list(LENGTH framework_libraries library_count)
foreach(library IN LISTS framework_libraries)
    execute_process(
        COMMAND /usr/bin/codesign --verify --strict "${library}"
        RESULT_VARIABLE library_verify_status
        OUTPUT_QUIET
        ERROR_QUIET
    )
    if(NOT library_verify_status EQUAL 0)
        message(FATAL_ERROR "Nested library signature is invalid: ${library}")
    endif()
    if(EXPECT_TEAM_SIGNING)
        execute_process(
            COMMAND /usr/bin/codesign -d --verbose=4 "${library}"
            RESULT_VARIABLE library_details_status
            OUTPUT_VARIABLE library_output
            ERROR_VARIABLE library_error
        )
        if(NOT library_details_status EQUAL 0)
            message(FATAL_ERROR "Could not inspect nested library: ${library}")
        endif()
        set(library_details "${library_output}${library_error}")
        string(REGEX MATCH "TeamIdentifier=([^\n]+)"
            library_team_match "${library_details}")
        if(NOT CMAKE_MATCH_1 STREQUAL host_TEAM)
            message(FATAL_ERROR
                "Nested library TeamIdentifier does not match LookSTEP: ${library}")
        endif()
    endif()
endforeach()

if(host_GROUP STREQUAL "")
    set(host_group_display "sandbox-local-fallback")
else()
    set(host_group_display "${host_GROUP}")
endif()
message(STATUS
    "LookSTEP release signing contract passed; "
    "team_signing=${EXPECT_TEAM_SIGNING}; app_group=${host_group_display}; "
    "xpc_bundles=${xpc_count}; libraries=${library_count}")
