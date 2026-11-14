# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(personal_ink_vault LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "personal_ink_vault")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(SET CMP0063 NEW)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100" /utf-8)
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")

# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)

# Build the common engine from the pinned Rust source before packaging the app.
set(INK_VAULT_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/..")
set(INK_VAULT_NATIVE_DLL "${INK_VAULT_ROOT}/build/native/windows/ink_vault_native.dll")
find_program(INK_VAULT_POWERSHELL NAMES pwsh powershell)
if(NOT INK_VAULT_POWERSHELL)
  message(FATAL_ERROR "PowerShell is required to build the common engine")
endif()
file(GLOB_RECURSE INK_VAULT_RUST_SOURCES CONFIGURE_DEPENDS "${INK_VAULT_ROOT}/packages/ink_vault_native/src/*.rs")
add_custom_command(OUTPUT "${INK_VAULT_NATIVE_DLL}"
  COMMAND "${INK_VAULT_POWERSHELL}" -NoProfile -ExecutionPolicy Bypass -File "${INK_VAULT_ROOT}/scripts/build-native.ps1" -Platform windows
  DEPENDS ${INK_VAULT_RUST_SOURCES}
    "${INK_VAULT_ROOT}/packages/ink_vault_native/Cargo.toml"
    "${INK_VAULT_ROOT}/packages/ink_vault_native/Cargo.lock"
    "${INK_VAULT_ROOT}/scripts/build-native.ps1"
  VERBATIM)
add_custom_target(ink_vault_native_build DEPENDS "${INK_VAULT_NATIVE_DLL}")
add_dependencies(${BINARY_NAME} ink_vault_native_build)

set(INK_HWP_NATIVE_DLL "${INK_VAULT_ROOT}/build/native/windows/ink_hwp_native.dll")
file(GLOB_RECURSE INK_HWP_RUST_SOURCES CONFIGURE_DEPENDS "${INK_VAULT_ROOT}/packages/ink_hwp_native/src/*.rs")
add_custom_command(OUTPUT "${INK_HWP_NATIVE_DLL}"
  COMMAND "${INK_VAULT_POWERSHELL}" -NoProfile -ExecutionPolicy Bypass -File "${INK_VAULT_ROOT}/scripts/build-hwp-native.ps1" -Platform windows
  DEPENDS ${INK_HWP_RUST_SOURCES}
    "${INK_VAULT_ROOT}/packages/ink_hwp_native/Cargo.toml"
    "${INK_VAULT_ROOT}/packages/ink_hwp_native/Cargo.lock"
    "${INK_VAULT_ROOT}/scripts/build-hwp-native.ps1"
  VERBATIM)
add_custom_target(ink_hwp_native_build DEPENDS "${INK_HWP_NATIVE_DLL}")
add_dependencies(${BINARY_NAME} ink_hwp_native_build)

set(INK_VAULT_MCP_EXE "${INK_VAULT_ROOT}/build/native/windows/ink_vault_mcp.exe")
file(GLOB_RECURSE INK_VAULT_MCP_SOURCES CONFIGURE_DEPENDS "${INK_VAULT_ROOT}/packages/ink_vault_mcp/src/*.rs")
add_custom_command(OUTPUT "${INK_VAULT_MCP_EXE}"
  COMMAND "${INK_VAULT_POWERSHELL}" -NoProfile -ExecutionPolicy Bypass -File "${INK_VAULT_ROOT}/scripts/build-mcp.ps1"
  DEPENDS ${INK_VAULT_MCP_SOURCES}
    "${INK_VAULT_ROOT}/packages/ink_vault_mcp/Cargo.toml"
    "${INK_VAULT_ROOT}/packages/ink_vault_mcp/Cargo.lock"
    "${INK_VAULT_ROOT}/scripts/build-mcp.ps1"
    "${INK_VAULT_ROOT}/packages/ink_vault_mcp/THIRD_PARTY_LICENSES.txt"
  VERBATIM)
add_custom_target(ink_vault_mcp_build DEPENDS "${INK_VAULT_MCP_EXE}")
add_dependencies(${BINARY_NAME} ink_vault_mcp_build)

set(INK_HWP_FONT "${INK_VAULT_ROOT}/build/native/fonts/NotoSansCJKkr-Regular.otf")
add_custom_command(OUTPUT "${INK_HWP_FONT}" "${INK_VAULT_ROOT}/build/native/fonts/OFL.txt"
  COMMAND "${INK_VAULT_POWERSHELL}" -NoProfile -ExecutionPolicy Bypass -File "${INK_VAULT_ROOT}/scripts/prepare-hwp-fonts.ps1"
  DEPENDS "${INK_VAULT_ROOT}/scripts/prepare-hwp-fonts.ps1"
    "${INK_VAULT_ROOT}/packages/ink_hwp_native/fonts/manifest.json"
  VERBATIM)
add_custom_target(ink_hwp_fonts DEPENDS "${INK_HWP_FONT}")
add_dependencies(flutter_assemble ink_hwp_fonts)

set(INK_PORTABLE_FONT "${INK_VAULT_ROOT}/build/native/fonts/NotoSansKR-Portable.ttf")
add_custom_command(OUTPUT "${INK_PORTABLE_FONT}"
  COMMAND "${INK_VAULT_POWERSHELL}" -NoProfile -ExecutionPolicy Bypass -File "${INK_VAULT_ROOT}/scripts/prepare-hwp-fonts.ps1" -ManifestName portable-export.json
  DEPENDS "${INK_VAULT_ROOT}/scripts/prepare-hwp-fonts.ps1"
    "${INK_VAULT_ROOT}/packages/ink_hwp_native/fonts/portable-export.json"
  VERBATIM)
add_custom_target(ink_portable_fonts DEPENDS "${INK_PORTABLE_FONT}")
add_dependencies(ink_portable_fonts ink_hwp_fonts)
add_dependencies(flutter_assemble ink_portable_fonts)

set(INK_VAULT_OFFICE_RUNTIME "${INK_VAULT_ROOT}/build/windows-office-engine/runtime")
add_custom_command(OUTPUT "${INK_VAULT_OFFICE_RUNTIME}/program/soffice.exe"
  COMMAND "${INK_VAULT_POWERSHELL}" -NoProfile -ExecutionPolicy Bypass -File "${INK_VAULT_ROOT}/scripts/prepare-windows-office.ps1"
  DEPENDS "${INK_VAULT_ROOT}/scripts/prepare-windows-office.ps1"
    "${CMAKE_CURRENT_SOURCE_DIR}/office_engine/prepare_runtime.py"
    "${CMAKE_CURRENT_SOURCE_DIR}/office_engine/runtime.lock.json"
  VERBATIM)
add_custom_target(ink_vault_office_runtime DEPENDS "${INK_VAULT_OFFICE_RUNTIME}/program/soffice.exe")
add_dependencies(${BINARY_NAME} ink_vault_office_runtime)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

# Deploy release CRT files from the compiler's redistributable directory.
set(CMAKE_INSTALL_DEBUG_LIBRARIES FALSE)
set(CMAKE_INSTALL_DEBUG_LIBRARIES_ONLY FALSE)
set(CMAKE_INSTALL_SYSTEM_RUNTIME_DESTINATION "${INSTALL_BUNDLE_LIB_DIR}")
set(CMAKE_INSTALL_SYSTEM_RUNTIME_COMPONENT Runtime)
include(InstallRequiredSystemLibraries)
if(MSVC AND NOT CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS)
  message(FATAL_ERROR "Visual C++ redistributable runtime files are required to package the application")
endif()

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)
install(FILES "${INK_VAULT_NATIVE_DLL}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)
install(FILES "${INK_HWP_NATIVE_DLL}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)
install(FILES "${INK_VAULT_MCP_EXE}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)
install(FILES "${INK_VAULT_ROOT}/packages/ink_vault_mcp/THIRD_PARTY_LICENSES.txt"
  DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" RENAME "ink-vault-mcp-THIRD-PARTY-LICENSES.txt" COMPONENT Runtime)
install(DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/office_engine/"
  DESTINATION "${INSTALL_BUNDLE_LIB_DIR}/office_engine" COMPONENT Runtime)
install(DIRECTORY "${INK_VAULT_OFFICE_RUNTIME}/"
  DESTINATION "${INSTALL_BUNDLE_LIB_DIR}/office_engine/runtime" COMPONENT Runtime)
install(PROGRAMS ${CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS}
  DESTINATION "${INSTALL_BUNDLE_LIB_DIR}/office_engine/runtime/program" COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
