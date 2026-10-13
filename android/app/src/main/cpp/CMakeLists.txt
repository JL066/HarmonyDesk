cmake_minimum_required(VERSION 3.22.1)
project(harmonydesk_android LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(HDCORE_LIBRARY "${CMAKE_CURRENT_LIST_DIR}/../jniLibs/${ANDROID_ABI}/libhdcore.so")
if(NOT EXISTS "${HDCORE_LIBRARY}")
    message(FATAL_ERROR "Missing hdcore for ${ANDROID_ABI}: ${HDCORE_LIBRARY}")
endif()

add_library(hdcore SHARED IMPORTED GLOBAL)
set_target_properties(hdcore PROPERTIES IMPORTED_LOCATION "${HDCORE_LIBRARY}")

add_library(androidbridge SHARED core_bridge.cpp)
target_link_libraries(androidbridge PRIVATE hdcore)

# Align this JNI library for devices using 16 KB memory pages. The imported
# Rust core must be built with the same linker alignment before packaging.
target_link_options(androidbridge PRIVATE
    "-Wl,-z,max-page-size=16384"
    "-Wl,-z,common-page-size=16384"
)
