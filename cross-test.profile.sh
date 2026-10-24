# Optional cross-test runner profile.
CROSS_BUILD_STEP=cross-test
CROSS_MATRIX=(
    'x86_64-linux|auto'
    'aarch64-linux|auto'
    'powerpc64-linux|auto'
)
CROSS_REQUIRE_RUNNERS=1
CROSS_JOBS=2
CROSS_BUILD_JOBS=2
CROSS_BUILD_TIMEOUT=3600
CROSS_TIMEOUT=600
