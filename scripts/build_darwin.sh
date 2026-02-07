#!/bin/sh
export VERSION=${VERSION:-$(git describe --tags --first-parent --abbrev=7 --long --dirty --always | sed -e "s/^v//g")}
export GOFLAGS="'-ldflags=-w -s \"-X=github.com/ollama/ollama/internal/version.Version=${VERSION#v}\" \"-X=github.com/ollama/ollama/server.mode=release\"'"
export CGO_CFLAGS="-O3 -mmacosx-version-min=14.0"
export CGO_CXXFLAGS="-O3 -mmacosx-version-min=14.0"
export CGO_LDFLAGS="-mmacosx-version-min=14.0"

set -e

status() { echo >&2 ">>> $@"; }
usage() {
    echo "usage: $(basename $0) [build [sign]]"
    exit 1
}

mkdir -p dist


ARCHS="arm64 amd64"
while getopts "a:h" OPTION; do
    case $OPTION in
        a) ARCHS=$OPTARG ;;
        h) usage ;;
    esac
done

shift $(( $OPTIND - 1 ))

_build_darwin() {
    for ARCH in $ARCHS; do
        status "Building darwin $ARCH"
        INSTALL_PREFIX=dist/darwin-$ARCH/        

        if [ "$ARCH" = "amd64" ]; then
            status "Building darwin $ARCH dynamic backends"
            BUILD_DIR=build/darwin-$ARCH
            cmake -B $BUILD_DIR \
                -DCMAKE_OSX_ARCHITECTURES=x86_64 \
                -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
                -DCMAKE_INSTALL_PREFIX=$INSTALL_PREFIX \
                -DMLX_ENGINE=ON \
                -DMLX_ENABLE_X64_MAC=ON \
                -DOLLAMA_RUNNER_DIR=./
            cmake --build $BUILD_DIR --target ggml-cpu -j
            cmake --build $BUILD_DIR --target mlx mlxc -j
            cmake --install $BUILD_DIR --component CPU
            cmake --install $BUILD_DIR --component MLX
            # Override CGO flags to point to the amd64 build directory
            MLX_CGO_CFLAGS="-O3 -I$(pwd)/$BUILD_DIR/_deps/mlx-c-src -mmacosx-version-min=14.0"
            MLX_CGO_LDFLAGS="-ldl -lc++ -framework Accelerate -mmacosx-version-min=14.0"
        else
            BUILD_DIR=build
            cmake --preset MLX \
                -DOLLAMA_RUNNER_DIR=./ \
                -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
                -DCMAKE_INSTALL_PREFIX=$INSTALL_PREFIX
            cmake --build --preset MLX --parallel
            cmake --install $BUILD_DIR --component MLX
            # Use default CGO flags from mlx.go for arm64
            MLX_CGO_CFLAGS="-O3 -I$(pwd)/$BUILD_DIR/_deps/mlx-c-src -mmacosx-version-min=14.0"
            MLX_CGO_LDFLAGS="-lc++ -framework Metal -framework Foundation -framework Accelerate -mmacosx-version-min=14.0"
        fi
        GOOS=darwin GOARCH=$ARCH CGO_ENABLED=1 CGO_CFLAGS="$MLX_CGO_CFLAGS" CGO_LDFLAGS="$MLX_CGO_LDFLAGS" go build -tags mlx -o $INSTALL_PREFIX .
        # Copy MLX libraries to same directory as executable for dlopen
        cp $INSTALL_PREFIX/lib/ollama/libmlxc.dylib $INSTALL_PREFIX/
        cp $INSTALL_PREFIX/lib/ollama/libmlx.dylib $INSTALL_PREFIX/
    done
}

_sign_darwin() {
    status "Creating universal binary..."
    mkdir -p dist/darwin
    lipo -create -output dist/darwin/ollama dist/darwin-*/ollama
    chmod +x dist/darwin/ollama

    if [ -n "$APPLE_IDENTITY" ]; then
        for F in dist/darwin/ollama dist/darwin-*/lib/ollama/*; do
            codesign -f --timestamp -s "$APPLE_IDENTITY" --identifier ai.ollama.ollama --options=runtime $F
        done

        # create a temporary zip for notarization
        TEMP=$(mktemp -u).zip
        ditto -c -k --keepParent dist/darwin/ollama "$TEMP"
        xcrun notarytool submit "$TEMP" --wait --timeout 20m --apple-id $APPLE_ID --password $APPLE_PASSWORD --team-id $APPLE_TEAM_ID
        rm -f "$TEMP"
    fi

    status "Creating universal tarball..."
    tar -cf dist/ollama-darwin.tar --strip-components 2 dist/darwin/ollama
    tar -rf dist/ollama-darwin.tar --strip-components 4 dist/darwin-amd64/lib/
    gzip -9vc <dist/ollama-darwin.tar >dist/ollama-darwin.tgz
}

if [ "$#" -eq 0 ]; then
    _build_darwin
    _sign_darwin
    exit 0
fi

for CMD in "$@"; do
    case $CMD in
        build) _build_darwin ;;
        sign) _sign_darwin ;;
        *) usage ;;
    esac
done
