set(VERSION 2.1.3)
set(COPYRIGHT_YEAR "1991-2022")
string(REPLACE "." ";" VERSION_TRIPLET ${VERSION})
list(GET VERSION_TRIPLET 0 VERSION_MAJOR)
list(GET VERSION_TRIPLET 1 VERSION_MINOR)
list(GET VERSION_TRIPLET 2 VERSION_REVISION)
function(pad_number NUMBER OUTPUT_LEN)
    string(LENGTH "${${NUMBER}}" INPUT_LEN)
    if(INPUT_LEN LESS OUTPUT_LEN)
        math(EXPR ZEROES "${OUTPUT_LEN} - ${INPUT_LEN} - 1")
        set(NUM ${${NUMBER}})
        foreach(C RANGE ${ZEROES})
            set(NUM "0${NUM}")
        endforeach()
        set(${NUMBER}
            ${NUM}
            PARENT_SCOPE
        )
    endif()
endfunction()
pad_number(VERSION_MINOR 3)
pad_number(VERSION_REVISION 3)
set(LIBJPEG_TURBO_VERSION_NUMBER ${VERSION_MAJOR}${VERSION_MINOR}${VERSION_REVISION})

# Detect CPU type and whether we're building 64-bit or 32-bit code
math(EXPR BITS "${CMAKE_SIZEOF_VOID_P} * 8")
string(TOLOWER ${CMAKE_SYSTEM_PROCESSOR} CMAKE_SYSTEM_PROCESSOR_LC)
set(COUNT 1)
foreach(ARCH ${CMAKE_OSX_ARCHITECTURES})
    if(COUNT GREATER 1)
        message(
            FATAL_ERROR "The libjpeg-turbo build system does not support multiple values in CMAKE_OSX_ARCHITECTURES."
        )
    endif()
    math(EXPR COUNT "${COUNT}+1")
endforeach()
if(CMAKE_SYSTEM_PROCESSOR_LC MATCHES "x86_64"
   OR CMAKE_SYSTEM_PROCESSOR_LC MATCHES "amd64"
   OR CMAKE_SYSTEM_PROCESSOR_LC MATCHES "i[0-9]86"
   OR CMAKE_SYSTEM_PROCESSOR_LC MATCHES "x86"
   OR CMAKE_SYSTEM_PROCESSOR_LC MATCHES "ia32"
)
    if(BITS EQUAL 64 OR CMAKE_C_COMPILER_ABI MATCHES "ELF X32")
        set(CPU_TYPE x86_64)
    else()
        set(CPU_TYPE i386)
    endif()
    if(NOT CMAKE_SYSTEM_PROCESSOR STREQUAL ${CPU_TYPE})
        set(CMAKE_SYSTEM_PROCESSOR ${CPU_TYPE})
    endif()
elseif(CMAKE_SYSTEM_PROCESSOR_LC STREQUAL "aarch64" OR CMAKE_SYSTEM_PROCESSOR_LC MATCHES "^arm")
    if(BITS EQUAL 64)
        set(CPU_TYPE arm64)
    else()
        set(CPU_TYPE arm)
    endif()
elseif(CMAKE_SYSTEM_PROCESSOR_LC MATCHES "^ppc" OR CMAKE_SYSTEM_PROCESSOR_LC MATCHES "^powerpc")
    set(CPU_TYPE powerpc)
else()
    set(CPU_TYPE ${CMAKE_SYSTEM_PROCESSOR_LC})
endif()
if(CMAKE_OSX_ARCHITECTURES MATCHES "x86_64"
   OR CMAKE_OSX_ARCHITECTURES MATCHES "arm64"
   OR CMAKE_OSX_ARCHITECTURES MATCHES "i386"
)
    set(CPU_TYPE ${CMAKE_OSX_ARCHITECTURES})
endif()
if(CMAKE_OSX_ARCHITECTURES MATCHES "ppc")
    set(CPU_TYPE powerpc)
endif()
if(MSVC_IDE AND CMAKE_GENERATOR_PLATFORM MATCHES "arm64")
    set(CPU_TYPE arm64)
endif()

# ######################################################################################################################
# CONFIGURATION OPTIONS
# ######################################################################################################################

if(WITH_JPEG8)
  set(JPEG_LIB_VERSION 80)
elseif(WITH_JPEG7)
  set(JPEG_LIB_VERSION 70)
else()
  set(JPEG_LIB_VERSION 62)
endif()

set(C_ARITH_CODING_SUPPORTED 1)
set(D_ARITH_CODING_SUPPORTED 1)
set(BITS_IN_JSAMPLE 8)
set(MEM_SRCDST_SUPPORTED 1)
set(MEM_SRCDST_FUNCTIONS "global:  jpeg_mem_dest;  jpeg_mem_src;")
set(WITH_SIMD 1)

# ######################################################################################################################
# COMPILER SETTINGS
# ######################################################################################################################

include(CheckCSourceCompiles)
include(CheckIncludeFiles)
include(CheckTypeSize)

check_type_size("size_t" SIZE_T)
check_type_size("unsigned long" UNSIGNED_LONG)

if(SIZE_T EQUAL UNSIGNED_LONG)
    check_c_source_compiles(
        "int main(int argc, char **argv) { unsigned long a = argc;  return __builtin_ctzl(a); }" HAVE_BUILTIN_CTZL
    )
endif()
if(MSVC)
    check_include_files("intrin.h" HAVE_INTRIN_H)
endif()

if(UNIX)
    if(CMAKE_CROSSCOMPILING)
        set(RIGHT_SHIFT_IS_UNSIGNED 0)
    else()
        include(CheckCSourceRuns)
        check_c_source_runs(
            "
      #include <stdio.h>
      #include <stdlib.h>
      int is_shifting_signed (long arg) {
        long res = arg >> 4;
        if (res == -0x7F7E80CL)
          return 1; /* right shift is signed */
        /* see if unsigned-shift hack will fix it. */
        /* we can't just test exact value since it depends on width of long... */
        res |= (~0L) << (32-4);
        if (res == -0x7F7E80CL)
          return 0; /* right shift is unsigned */
        printf(\"Right shift isn't acting as I expect it to.\\\\n\");
        printf(\"I fear the JPEG software will not work at all.\\\\n\\\\n\");
        return 0; /* try it with unsigned anyway */
      }
      int main (void) {
        exit(is_shifting_signed(-0x7F7E80B1L));
      }"
            RIGHT_SHIFT_IS_UNSIGNED
        )
    endif()
endif()

if(MSVC)
    set(INLINE_OPTIONS "__inline;inline")
else()
    set(INLINE_OPTIONS "__inline__;inline")
endif()
option(FORCE_INLINE "Force function inlining" TRUE)
if(FORCE_INLINE)
    if(MSVC)
        list(INSERT INLINE_OPTIONS 0 "__forceinline")
    else()
        list(INSERT INLINE_OPTIONS 0 "inline __attribute__((always_inline))")
        list(INSERT INLINE_OPTIONS 0 "__inline__ __attribute__((always_inline))")
    endif()
endif()
foreach(inline ${INLINE_OPTIONS})
    check_c_source_compiles(
        "${inline} static int foo(void) { return 0; } int main(void) { return foo(); }" INLINE_WORKS
    )
    if(INLINE_WORKS)
        set(INLINE ${inline})
        break()
    endif()
endforeach()
if(NOT INLINE_WORKS)
    message(FATAL_ERROR "Could not determine how to inline functions.")
endif()

# Generate files
configure_file(../jconfig.h.in "${CMAKE_CURRENT_BINARY_DIR}/libjpeg/jconfig.h")
configure_file(../jconfigint.h.in "${CMAKE_CURRENT_BINARY_DIR}/libjpeg/jconfigint.h")
configure_file(../jversion.h.in "${CMAKE_CURRENT_BINARY_DIR}/libjpeg/jversion.h")

if(CPU_TYPE STREQUAL "arm64" OR CPU_TYPE STREQUAL "arm")
configure_file(../simd/arm/neon-compat.h.in "${CMAKE_CURRENT_BINARY_DIR}/libjpeg/neon-compat.h")
endif()

if(UNIX)
    configure_file(../libjpeg.map.in "${CMAKE_CURRENT_BINARY_DIR}/libjpeg/libjpeg.map")
endif()
