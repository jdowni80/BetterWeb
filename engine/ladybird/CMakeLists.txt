# libBetterWebEngine: Ladybird's browser-process side (LibWebView) wrapped in an AppKit view and a
# plain Objective-C API. Built inside Ladybird's CMake tree via -DBETTERWEB_ENGINE_DIR=<this dir>
# (see scripts/build_ladybird_engine.sh), so it links the exact same libraries as the helpers.

add_library(BetterWebEngine SHARED
    src/EventLoopCF.mm
    src/BWWebView.mm
    src/BWEngine.mm
)

target_compile_options(BetterWebEngine PRIVATE -fobjc-arc -fobjc-weak -Wno-unused-parameter)
# The public header lives with the Swift package that imports it.
target_include_directories(BetterWebEngine
    PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/../../macos/Sources/BWEngine
    PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src ${LADYBIRD_SOURCE_DIR} ${LADYBIRD_SOURCE_DIR}/Services
)
target_link_libraries(BetterWebEngine PRIVATE
    AK LibCore LibGfx LibIPC LibURL LibThreading LibWebView
    OpenSSL::Crypto OpenSSL::SSL
    "-framework Cocoa" "-framework QuartzCore" "-framework IOSurface" "-framework Carbon"
)
set_target_properties(BetterWebEngine PROPERTIES
    INSTALL_NAME_DIR "@rpath"
    BUILD_WITH_INSTALL_NAME_DIR ON
)

# The engine is useless without the helper processes it spawns.
add_dependencies(BetterWebEngine ${ladybird_helper_processes})
