cmake_minimum_required(VERSION 3.20)
project(NppBeads VERSION 0.9.7 LANGUAGES CXX OBJCXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_OSX_DEPLOYMENT_TARGET "12.0")
set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64")

set(NPP_MACOS_DIR      "${CMAKE_SOURCE_DIR}/../../notepad-plus-plus-macos")
set(NPP_WIN_DIR        "${CMAKE_SOURCE_DIR}/../../notepad-plus-plus")
set(SCINTILLA_INCLUDE  "${NPP_WIN_DIR}/scintilla/include")
set(NPP_PLUGIN_INCLUDE "${NPP_MACOS_DIR}/src")

# Build-target switches. Both default ON so a clean checkout produces both
# artifacts; turn either off (-DNPPBEADS_BUILD_PLUGIN=OFF or
# -DNPPBEADS_BUILD_APP=OFF) to skip one when only one is wanted.
option(NPPBEADS_BUILD_PLUGIN "Build the NppBeads.dylib Notepad++ plugin" ON)
option(NPPBEADS_BUILD_APP    "Build the standalone Beads.app"             ON)

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

# ─────────────────────────────────────────────────────────────────────────
#  Shared core sources — compiled into both targets.
# ─────────────────────────────────────────────────────────────────────────
#  These files have no Notepad++ dependency. They make up the data layer,
#  the WKWebView panel, the bd CLI runner, the project scanner, the
#  filesystem watcher, the live-sync poll, and the bead-id indicator
#  (which already takes its sendMessage as a function pointer, so it's
#  host-agnostic by construction). The plugin shell ships these alongside
#  NppBeads.mm; the standalone shell ships them alongside the shell-app/
#  files.
set(BEADS_CORE_SOURCES
    src/BeadsPanel.mm
    src/JsonlDataSource.mm
    src/BeadsProjectScanner.mm
    src/BeadsWatcher.mm
    src/BeadsSchemeHandler.mm
    src/BdCommandRunner.mm
    src/BdDataSource.mm
    src/BeadsPoll.mm
    src/BdEventsTail.mm
    src/BeadIdIndicator.mm)

# ─────────────────────────────────────────────────────────────────────────
#  Target 1 — NppBeads.dylib (the Notepad++ plugin)
# ─────────────────────────────────────────────────────────────────────────
if(NPPBEADS_BUILD_PLUGIN)
    add_library(NppBeads SHARED
        src/NppBeads.mm
        ${BEADS_CORE_SOURCES})
    target_include_directories(NppBeads PRIVATE
        ${NPP_PLUGIN_INCLUDE}
        ${SCINTILLA_INCLUDE}
        src)
    target_link_libraries(NppBeads PRIVATE
        "-framework Cocoa"
        "-framework WebKit"
        "-framework UniformTypeIdentifiers")
    target_compile_options(NppBeads PRIVATE
        -Wall -Wno-unused-parameter
        -fvisibility=hidden
        $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
    set_target_properties(NppBeads PROPERTIES PREFIX "" SUFFIX ".dylib")
    # Bake the Mach-O current_version so Plugins Admin reports the installed
    # version (was 0.0.0 before). Kept in sync with the catalog's version.
    target_link_options(NppBeads PRIVATE "-Wl,-current_version,${PROJECT_VERSION}")

    set(PLUGIN_INSTALL_DIR "$ENV{HOME}/.nextpad++/plugins/NppBeads")
    install(TARGETS NppBeads DESTINATION "${PLUGIN_INSTALL_DIR}")
    install(DIRECTORY resources/ DESTINATION "${PLUGIN_INSTALL_DIR}/resources"
        PATTERN ".git"       EXCLUDE
        PATTERN ".github"    EXCLUDE
        PATTERN ".DS_Store"  EXCLUDE
        PATTERN ".gitignore" EXCLUDE
        PATTERN "beads.icns" EXCLUDE)
    install(FILES resources/toolbar.png DESTINATION "${PLUGIN_INSTALL_DIR}")
endif()

# ─────────────────────────────────────────────────────────────────────────
#  Target 2 — Beads.app (standalone macOS app, same code)
# ─────────────────────────────────────────────────────────────────────────
if(NPPBEADS_BUILD_APP)
    set(BEADS_APP_VERSION "0.9.7")

    # Walk resources/viewer/ and resources/beads.icns recursively, register
    # each file as a target source with MACOSX_PACKAGE_LOCATION pointing
    # at the right path under Contents/Resources/. CMake's bundle support
    # requires this per-file declaration — there's no equivalent of the
    # plugin's `install(DIRECTORY)` for app bundles.
    set(VIEWER_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/resources/viewer")
    file(GLOB_RECURSE BEADS_VIEWER_FILES
         RELATIVE "${CMAKE_CURRENT_SOURCE_DIR}/resources"
         "${VIEWER_ROOT}/*")
    set(BEADS_BUNDLE_RESOURCES "")
    foreach(REL ${BEADS_VIEWER_FILES})
        # Skip dotfiles and build artifacts (CMake's GLOB_RECURSE
        # doesn't honor PATTERN exclusions like install(DIRECTORY) does).
        get_filename_component(FNAME "${REL}" NAME)
        if(FNAME STREQUAL ".DS_Store" OR FNAME STREQUAL ".gitignore"
           OR FNAME STREQUAL ".npp-md-preview.html")
            continue()
        endif()
        set(ABS "${CMAKE_CURRENT_SOURCE_DIR}/resources/${REL}")
        get_filename_component(SUBDIR "${REL}" DIRECTORY)
        set_source_files_properties("${ABS}" PROPERTIES
            MACOSX_PACKAGE_LOCATION "Resources/${SUBDIR}")
        list(APPEND BEADS_BUNDLE_RESOURCES "${ABS}")
    endforeach()

    # App icon at the bundle's Resources root.
    set(BEADS_ICON_PATH "${CMAKE_CURRENT_SOURCE_DIR}/resources/beads.icns")
    if(EXISTS "${BEADS_ICON_PATH}")
        set_source_files_properties("${BEADS_ICON_PATH}" PROPERTIES
            MACOSX_PACKAGE_LOCATION "Resources")
        list(APPEND BEADS_BUNDLE_RESOURCES "${BEADS_ICON_PATH}")
    else()
        message(WARNING "Beads.app: resources/beads.icns missing — building without an icon")
    endif()

    # Tahoe Liquid Glass app icon, compiled from resources/beads.icon via actool
    # (see tools — regenerated out-of-band). CFBundleIconName=beads (set in
    # Info.plist.in) makes macOS 26+ render the glass icon from Assets.car;
    # older macOS falls back to CFBundleIconFile=beads.icns.
    set(BEADS_ASSETS_CAR "${CMAKE_CURRENT_SOURCE_DIR}/resources/Assets.car")
    if(EXISTS "${BEADS_ASSETS_CAR}")
        set_source_files_properties("${BEADS_ASSETS_CAR}" PROPERTIES
            MACOSX_PACKAGE_LOCATION "Resources")
        list(APPEND BEADS_BUNDLE_RESOURCES "${BEADS_ASSETS_CAR}")
    endif()

    # DMG background image. Ships INSIDE the bundle (Contents/Resources)
    # so the DMG root stays clean — only Beads.app + the Applications
    # symlink are visible when the DMG is mounted, even with "Show
    # Hidden Files" enabled. The build-release.sh DMG step reads it
    # from this in-bundle location via an HFS-style AppleScript path.
    set(BEADS_DMG_BG "${CMAKE_CURRENT_SOURCE_DIR}/resources/dmg-background.tiff")
    if(EXISTS "${BEADS_DMG_BG}")
        set_source_files_properties("${BEADS_DMG_BG}" PROPERTIES
            MACOSX_PACKAGE_LOCATION "Resources")
        list(APPEND BEADS_BUNDLE_RESOURCES "${BEADS_DMG_BG}")
    endif()

    add_executable(BeadsViewer MACOSX_BUNDLE
        shell-app/main.mm
        shell-app/BeadsAppDelegate.mm
        shell-app/BeadsMainWindowController.mm
        shell-app/BeadsMenuBuilder.mm
        ${BEADS_CORE_SOURCES}
        ${BEADS_BUNDLE_RESOURCES})

    target_include_directories(BeadsViewer PRIVATE src shell-app)
    target_link_libraries(BeadsViewer PRIVATE
        "-framework Cocoa"
        "-framework WebKit"
        "-framework UniformTypeIdentifiers")
    target_compile_options(BeadsViewer PRIVATE
        -Wall -Wno-unused-parameter
        # Release-only: optimize for size and let visibility=hidden
        # drop unexported symbols so the linker can dead-strip more.
        $<$<CONFIG:Release>:-Os>
        $<$<CONFIG:Release>:-fvisibility=hidden>
        $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
    target_link_options(BeadsViewer PRIVATE
        # Dead-strip unreferenced code. With -fvisibility=hidden on
        # the compile side, the linker can prove far more code is
        # unreachable. Combined with strip -x in tools/build-release.sh
        # this trims the universal binary by ~20-30%.
        $<$<CONFIG:Release>:-Wl,-dead_strip>)

    set_target_properties(BeadsViewer PROPERTIES
        OUTPUT_NAME "BeadsViewer"
        MACOSX_BUNDLE_BUNDLE_NAME           "BeadsViewer"
        MACOSX_BUNDLE_GUI_IDENTIFIER        "org.nextpadplusplus.mac.BeadsViewer"
        MACOSX_BUNDLE_BUNDLE_VERSION        "${BEADS_APP_VERSION}"
        MACOSX_BUNDLE_SHORT_VERSION_STRING  "${BEADS_APP_VERSION}"
        MACOSX_BUNDLE_EXECUTABLE_NAME       "BeadsViewer"
        MACOSX_BUNDLE_ICON_FILE             "beads.icns"
        MACOSX_BUNDLE_INFO_PLIST            "${CMAKE_CURRENT_SOURCE_DIR}/shell-app/Info.plist.in"
    )
endif()
