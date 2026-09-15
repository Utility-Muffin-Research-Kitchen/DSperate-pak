# Cross-compile DSperate for the Miniloong Pocket 1 (aarch64 / RK3566) with the
# pinned mlp1-toolchain image. Every path here is inside that image, not on the
# host, so this file is only ever read by build-in-container.sh.
#
# CMAKE_SYSTEM_PROCESSOR=aarch64 is what makes DSperate build its AArch64 JIT
# and NEON renderer kernels rather than the portable interpreter.
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

set(MLP1_TOOLCHAIN_PREFIX "aarch64-buildroot-linux-gnu" CACHE STRING "Cross tool prefix")
set(MLP1_SYSROOT "/opt/mlp1-toolchain/aarch64-buildroot-linux-gnu/sysroot" CACHE PATH "Target sysroot")

set(CMAKE_C_COMPILER "${MLP1_TOOLCHAIN_PREFIX}-gcc")
set(CMAKE_CXX_COMPILER "${MLP1_TOOLCHAIN_PREFIX}-g++")
set(CMAKE_SYSROOT "${MLP1_SYSROOT}")
set(CMAKE_FIND_ROOT_PATH "${MLP1_SYSROOT}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
