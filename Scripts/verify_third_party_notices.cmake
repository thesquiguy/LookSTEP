function(verify_third_party_release resources_dir frameworks_dir source_root role)
    if(NOT IS_DIRECTORY "${resources_dir}")
        message(FATAL_ERROR "${role} resources are missing: ${resources_dir}")
    endif()
    if(NOT IS_DIRECTORY "${frameworks_dir}")
        message(FATAL_ERROR "${role} frameworks are missing: ${frameworks_dir}")
    endif()

    set(expected_notices
        "FREETYPE-LICENSE.txt"
        "LIBPNG-LICENSE.txt"
        "LICENSE_LGPL_21.txt"
        "OCCT_LGPL_EXCEPTION.txt"
        "ONETBB-LICENSE.txt"
        "README.md")
    list(SORT expected_notices)

    set(bundled_notice_dir "${resources_dir}/ThirdPartyNotices")
    file(GLOB bundled_notices
        RELATIVE "${bundled_notice_dir}"
        "${bundled_notice_dir}/*")
    list(SORT bundled_notices)
    if(NOT bundled_notices STREQUAL expected_notices)
        message(FATAL_ERROR
            "${role} third-party notice set is stale or incomplete; "
            "expected=${expected_notices}; actual=${bundled_notices}")
    endif()

    foreach(notice IN LISTS expected_notices)
        set(source_notice "${source_root}/ThirdPartyNotices/${notice}")
        set(bundled_notice "${bundled_notice_dir}/${notice}")
        if(NOT EXISTS "${source_notice}" OR NOT EXISTS "${bundled_notice}")
            message(FATAL_ERROR "${role} is missing third-party notice ${notice}")
        endif()
        file(SHA256 "${source_notice}" source_digest)
        file(SHA256 "${bundled_notice}" bundled_digest)
        if(NOT source_digest STREQUAL bundled_digest)
            message(FATAL_ERROR
                "${role} bundles a modified or stale third-party notice: ${notice}")
        endif()
    endforeach()

    set(source_summary "${source_root}/THIRD_PARTY.md")
    set(bundled_summary "${resources_dir}/THIRD_PARTY.md")
    if(NOT EXISTS "${source_summary}" OR NOT EXISTS "${bundled_summary}")
        message(FATAL_ERROR "${role} must bundle THIRD_PARTY.md")
    endif()
    file(SHA256 "${source_summary}" source_summary_digest)
    file(SHA256 "${bundled_summary}" bundled_summary_digest)
    if(NOT source_summary_digest STREQUAL bundled_summary_digest)
        message(FATAL_ERROR "${role} bundles a stale THIRD_PARTY.md")
    endif()

    file(GLOB framework_paths "${frameworks_dir}/*.dylib")
    set(framework_names "")
    foreach(framework_path IN LISTS framework_paths)
        get_filename_component(framework_name "${framework_path}" NAME)
        list(APPEND framework_names "${framework_name}")
    endforeach()
    list(SORT framework_names)
    if(framework_names STREQUAL "")
        message(FATAL_ERROR "${role} has no redistributable dylib closure")
    endif()

    file(GLOB manifest_paths "${resources_dir}/.*bundled-dylibs")
    list(LENGTH manifest_paths manifest_count)
    if(NOT manifest_count EQUAL 1)
        message(FATAL_ERROR
            "${role} must contain exactly one bundled-dylib manifest; "
            "found ${manifest_count}")
    endif()
    list(GET manifest_paths 0 manifest_path)
    file(STRINGS "${manifest_path}" manifest_names)
    list(SORT manifest_names)
    if(NOT manifest_names STREQUAL framework_names)
        message(FATAL_ERROR
            "${role} dylib manifest does not match its Frameworks closure")
    endif()

    foreach(library_name IN LISTS manifest_names)
        if(library_name MATCHES "^libTK[A-Za-z0-9]+\\.[0-9]+\\.[0-9]+\\.dylib$"
           OR library_name MATCHES "^libfreetype\\.[0-9]+\\.dylib$"
           OR library_name MATCHES "^libpng[0-9]+\\.[0-9]+\\.dylib$"
           OR library_name MATCHES "^libtbb(malloc)?\\.[0-9]+\\.dylib$")
            continue()
        endif()
        message(FATAL_ERROR
            "${role} bundles an unregistered redistributable library: "
            "${library_name}")
    endforeach()
endfunction()
