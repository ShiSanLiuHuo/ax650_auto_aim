CMAKE_MINIMUM_REQUIRED(VERSION 3.12)

set(CMAKE_MODULE_PATH ${CMAKE_CURRENT_SOURCE_DIR})

find_package(OpenCV REQUIRED)
find_package(Eigen3 REQUIRED)
find_package(Threads REQUIRED)

include_directories(${OpenCV_INCLUDE_DIRS})
include_directories(${EIGEN3_INCLUDE_DIR})

aux_source_directory(video video_src)

if(USE_MINDVISION)
    # MindVision MVSDK (迈德威视): 头文件随仓库放在 sensor/mindvision/include，
    # 共享库由 AX650 EnvCfg 离线安装（sources/mindvision_arm64_v2.1.0.37.tar.gz）。
    aux_source_directory(mindvision mindvision_src)

    find_library(MVSDK_LIBRARY
        NAMES MVSDK
        PATHS
            ${MINDVISION_PATH}
            ${MINDVISION_PATH}/lib
            $ENV{MINDVISION_PATH}
            $ENV{MINDVISION_PATH}/lib
            /usr/lib/aarch64-linux-gnu
            /usr/lib/arm64
            /usr/local/lib
            /usr/lib
            /lib
            /lib/aarch64-linux-gnu)
    if(NOT MVSDK_LIBRARY)
        message(FATAL_ERROR
            "libMVSDK.so not found. Install the MindVision SDK "
            "(EnvCfg sources/mindvision_arm64_*.tar.gz) or set MINDVISION_PATH "
            "to the directory containing libMVSDK.so.")
    endif()
    message(STATUS "MindVision MVSDK library: ${MVSDK_LIBRARY}")

    get_filename_component(MVSDK_LIBRARY_DIR ${MVSDK_LIBRARY} DIRECTORY)

    # Build the sensor submodule and video wrappers.
    ADD_LIBRARY(sensor OBJECT sensor_submodule.cpp ${video_src} ${mindvision_src})

    target_include_directories(sensor PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/mindvision/include)
    target_compile_definitions(sensor PRIVATE ENABLE_MINDVISION=1)
    target_link_libraries(sensor ${OpenCV_LIBS} ${MVSDK_LIBRARY})
    set_target_properties(sensor PROPERTIES LINK_FLAGS "-Wl,-rpath,${MVSDK_LIBRARY_DIR}")

elseif(USE_HIKCAM)
    aux_source_directory(hikcam hikcam_src)
    #Hik Cam Supporting libraries
    SET(MVS_LD_FLAGS "-Wl,-rpath,")
    SET(MVS_LD_FLAGS ${MVS_LD_FLAGS}$ENV{MVS_PATH}" -R '"$ENV{MVS_PATH}"'")
    if(NOT DEFINED ENV{MVS_PATH})
        message(FATAL_ERROR "not defined env: MVS_PATH")
    endif()
    LINK_DIRECTORIES($ENV{MVS_PATH})

    FILE(GLOB MVS_LIBS "$ENV{MVS_PATH}/lib*.so")
    # Build the sensor submodule and video wrappers.
    ADD_LIBRARY(sensor OBJECT sensor_submodule.cpp ${video_src} ${hikcam_src})

    target_compile_definitions(sensor PRIVATE ENABLE_HIKCAM=1)
    target_link_libraries(sensor ${OpenCV_LIBS})
    target_link_libraries(sensor libMvCameraControl.so ${MVS_LIBS})
    set_target_properties(sensor PROPERTIES LINK_FLAGS ${MVS_LD_FLAGS})
else()

    # Build the sensor submodule and video wrappers.
    ADD_LIBRARY(sensor OBJECT sensor_submodule.cpp ${video_src})
    target_link_libraries(sensor ${OpenCV_LIBS})

endif()
