#!/usr/bin/env bash
# Get an updated config.sub and config.guess
cp $BUILD_PREFIX/share/gnuconfig/config.* .

export XDG_DATA_DIRS=${XDG_DATA_DIRS}:$PREFIX/share

GDKTARGET=""
if [[ "${target_platform}" == osx-* ]]; then
    export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:${PREFIX}/share/pkgconfig:${BUILD_PREFIX}/lib/pkgconfig${PKG_CONFIG_PATH:+:}${PKG_CONFIG_PATH}"
    export GDKTARGET="quartz"
    export LDFLAGS="${LDFLAGS} -Wl,-rpath,${PREFIX}/lib -framework Carbon"
    # https://discourse.llvm.org/t/clang-16-notice-of-potentially-breaking-changes/65562
    export CFLAGS="${CFLAGS} -Wno-error=incompatible-function-pointer-types"
    mkdir -p "${SRC_DIR}/local_bin"
    export PATH="${SRC_DIR}/local_bin:$PATH"
    cp "${PREFIX}/bin/glib-mkenums" "${SRC_DIR}/local_bin"
    _python=$(which python)
    sed -i.bak "s|/usr/bin/env python|${_python}|" "${SRC_DIR}/local_bin/glib-mkenums"
elif [[ "${target_platform}" == linux-* ]]; then
    export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:${PREFIX}/share/pkgconfig:${BUILD_PREFIX}/lib/pkgconfig${PKG_CONFIG_PATH:+:}${PKG_CONFIG_PATH}"
    export GDKTARGET="x11"
    export LDFLAGS="${LDFLAGS} -Wl,-rpath=${PREFIX}/lib"
elif [[ "${target_platform}" == win-* ]]; then
    _pkg_config="$(which pkg-config | sed 's|^/\(.\)|\1:|g' | sed 's|/|\\|g')"
    export PKG_CONFIG="${_pkg_config}"

    _pkg_config_path="$(echo ${PKG_CONFIG_PATH} | sed 's|:|;|g' | sed 's|^/\(.\)|\1:|g' | sed 's|/|\\|g')"
    PKG_CONFIG_PATH="${_pkg_config_path}"

    _pkg_config_path="$(echo ${PREFIX}/Library/lib/pkgconfig | sed 's|:|;|g' | sed 's|^/\(.\)|\1:|g' | sed 's|/|\\|g')"
    PKG_CONFIG_PATH="${_pkg_config_path}${PKG_CONFIG_PATH:+;}${PKG_CONFIG_PATH}"

    _pkg_config_path="$(echo ${BUILD_PREFIX}/Library/lib/pkgconfig | sed 's|:|;|g' | sed 's|^/\(.\)|\1:|g' | sed 's|/|\\|g')"
    PKG_CONFIG_PATH="${_pkg_config_path};${PKG_CONFIG_PATH}"

    export PKG_CONFIG_PATH
    export PKG_CONFIG_LIBDIR="${PKG_CONFIG_PATH}"

    export PERL5LIB="${BUILD_PREFIX}/lib/perl5/site-perl:${PERL5LIB}"
    export GDKTARGET="win32"
fi

configure_args=(
    --disable-dependency-tracking
    --disable-silent-rules
    --disable-glibtest
    --enable-introspection=yes
    --with-gdktarget="${GDKTARGET}"
    --disable-visibility
    --with-html-dir="${SRC_DIR}/html"
)

if [[ "$CONDA_BUILD_CROSS_COMPILATION" == 1 ]]; then
  unset _CONDA_PYTHON_SYSCONFIGDATA_NAME
  (
    mkdir -p native-build
    pushd native-build

    export CC=$CC_FOR_BUILD
    export AR=($CC_FOR_BUILD -print-prog-name=ar)
    export NM=($CC_FOR_BUILD -print-prog-name=nm)
    export LDFLAGS=${LDFLAGS//$PREFIX/$BUILD_PREFIX}
    export PKG_CONFIG_PATH=${BUILD_PREFIX}/lib/pkgconfig

    # Unset them as we're ok with builds that are either slow or non-portable
    unset CFLAGS
    unset CPPFLAGS
    export host_alias=$build_alias
    export PKG_CONFIG_PATH=$BUILD_PREFIX/lib/pkgconfig

    ../configure --prefix=$BUILD_PREFIX "${configure_args[@]}"

    echo "DBG: glib-mkenums in native build"
    grep glib-mkenums config.status

    # This script would generate the functions.txt and dump.xml and save them
    # This is loaded in the native build. We assume that the functions exported
    # by glib are the same for the native and cross builds
    export GI_CROSS_LAUNCHER=$BUILD_PREFIX/libexec/gi-cross-launcher-save.sh
    make -j${CPU_COUNT}
    make install
    popd
  )
  export GI_CROSS_LAUNCHER=$BUILD_PREFIX/libexec/gi-cross-launcher-load.sh
fi

export PKG_CONFIG_PATH=$PKG_CONFIG_PATH:$BUILD_PREFIX/lib/pkgconfig

./configure \
    --prefix="${PREFIX}" \
    "${configure_args[@]}"

    echo "DBG: glib-mkenums in cross build"
    echo "DBG: $(/usr/bin/env python -V)"
    grep glib-mkenums config.status

make V=0 -j$CPU_COUNT
# make check -j$CPU_COUNT
make install -j$CPU_COUNT

# We use the GTK 3 version of gtk-update-icon-cache
# https://github.com/conda-forge/gtk2-feedstock/issues/24
rm -f ${PREFIX}/bin/gtk-update-icon-cache
rm -f ${PREFIX}/share/man/man1/gtk-update-icon-cache.1
