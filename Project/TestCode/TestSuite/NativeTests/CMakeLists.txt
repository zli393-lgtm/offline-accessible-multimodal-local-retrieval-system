cmake_minimum_required(VERSION 3.20)
project(retrieval_native_tests LANGUAGES CXX)

if(NOT WIN32)
  message(FATAL_ERROR "The current native test target covers the Windows runner.")
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
enable_testing()

find_package(GTest CONFIG QUIET)
if(NOT GTest_FOUND)
  if(NOT DEFINED GTEST_SOURCE_DIR OR NOT EXISTS "${GTEST_SOURCE_DIR}/CMakeLists.txt")
    message(FATAL_ERROR "Set GTEST_SOURCE_DIR to an existing Google Test source directory.")
  endif()
  set(GOOGLETEST_VERSION "1.10.0")
  set(INSTALL_GTEST OFF CACHE BOOL "" FORCE)
  set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
  add_subdirectory("${GTEST_SOURCE_DIR}" "${CMAKE_BINARY_DIR}/googletest" EXCLUDE_FROM_ALL)
endif()

add_executable(retrieval_native_tests
  utf_conversion_test.cpp
  "../../../ReleaseCode/windows/runner/utf_conversion.cpp"
)
target_include_directories(retrieval_native_tests PRIVATE
  "../../../ReleaseCode/windows/runner"
)
target_compile_definitions(retrieval_native_tests PRIVATE NOMINMAX)
target_link_libraries(retrieval_native_tests PRIVATE GTest::gtest_main)

include(GoogleTest)
gtest_discover_tests(retrieval_native_tests)
