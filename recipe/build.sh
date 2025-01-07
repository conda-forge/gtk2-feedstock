#!/usr/bin/env bash

set -uo pipefail

unique_from_last() {
  # Function to make a list unique from the last occurrence
  # Accept a single space-separated string as input
  local input_string="$1"
  local seen_l=""           # Tracking seen items for -l strings
  local seen_L=""           # Tracking seen items for -L strings
  local l_list=()           # Array for -l strings
  local L_list=()           # Array for -L strings
  local others=()           # Array for other strings

  # Convert the input string into an array
  IFS=' ' read -r -a list <<< "$input_string"

  # Traverse the list from first to last
  for item in "${list[@]}"; do
    if [[ "$item" == -L* || "$item" == -I* ]]; then
      # -L strings processed from first to last occurrence
      if [[ ! " $seen_L " =~ " $item " ]]; then
        L_list+=("$item")
        seen_L="$seen_L $item"
      fi
    elif [[ "$item" == -l* ]]; then
      # -l strings processed from last to first occurrence
      if [[ ! " $seen_l " =~ " $item " ]]; then
        l_list=("$item" "${l_list[@]}")
        seen_l="$seen_l $item"
      fi
    else
      # Other strings are appended in order of appearance
      others+=("$item")
    fi
  done

  # Assemble the final result: -L first -> others -> -l last
  local result="${L_list[*]} ${others[*]} ${l_list[*]}"

  # Trim and print result
  echo "${result% }"
}

host_conda_libs="${PREFIX}/Library/lib"
build_conda_libs="${BUILD_PREFIX}/Library/lib"

system_libs_exclude=("uuid" "gdi32" "imm32" "shell32" "usp10" "ole32" "rpcrt4" "shlwapi" "iphlpapi"
                     "dnsapi" "ws2_32" "winmm" "msimg32" "dwrite" "d2d1" "windowscodecs" "dl" "m" "dld"
                     "svld" "w" "mlib" "dnet" "dnet_stub" "nsl" "bsd" "socket" "posix" "ipc" "XextSan"
                     "ICE" "Xinerama" "papi")
exclude_regex=$(printf "|%s" "${system_libs_exclude[@]}")
exclude_regex=${exclude_regex:1} 

replace_l_flags() {
  # Function to replace -lxxx with a specific path/xxx.lib
  local input_string="$1"  # Get the input string containing linker flags

  # Initialize an empty result
  local result=""

  # Convert the input string into an array of words
  IFS=' ' read -r -a flags <<< "$input_string"

  # Process each "flag" in the input string
  for flag in "${flags[@]}"; do
    if [[ "$flag" == -l* ]] && ! [[ " ${system_libs_exclude[*]} " =~ " ${flag#-l} " ]]; then
      # Replace -lxxx with path/xxx.lib
      local lib_name="${flag#-l}"
      if [[ -f "$host_conda_libs/$lib_name.lib" ]]; then
        result+="$host_conda_libs/$lib_name.lib "
      else
        result+="$build_conda_libs/$lib_name.lib "
      fi
    else
      # Keep everything else (unchanged flags)
      result+="$flag "
    fi
  done

  # Return the modified string (trimmed)
  echo "${result% }"
}

replace_l_flag_in_file() {
  local file="$1"
  local debug="${2:-false}" # Enables debug if DEBUG is set to 'true'

  if [[ -f "$file" ]]; then
    $debug && echo "Processing file: $file"

    # Temporary file for processing
    tmpfile=$(mktemp) || { echo "Error: Failed to create temp file" >&2; exit 1; }
    $debug && echo "  Created temp file: $tmpfile"

    while IFS= read -r line; do
      if [[ "$line" =~ ^[GIL][[:alnum:]_]*IBS ]]; then
        $debug && echo "  Processing matching line (G*, L*, or I*IBS): $line"
        updated_line=""

        for word in $line; do
          if [[ $word == -l* ]]; then
            flag_name=$(echo "$word" | sed -E 's/(-l[[:alnum:]_\-\.]+)/\1/')
            lib_name=$(echo "$word" | sed -E 's/-l([[:alnum:]_\-\.]+)/\1/')
            escaped_flag_name=$(echo "$flag_name" | sed -E 's/[-\.]/\\&/g')

            $debug && echo "    Found linker flag: $flag_name (library: $lib_name)"

            if [[ $lib_name =~ ^($exclude_regex)$ ]]; then
              $debug && echo "      Library '$lib_name' is excluded. Keeping unchanged."
              updated_line+="$word "
            else
              # Verify if the library file exists before replacing
              if [[ -f "$build_conda_libs/${lib_name}.lib" ]]; then
                $debug && echo "      Found in build_conda_libs: $build_conda_libs/${lib_name}.lib"
                updated_line+=$(echo "$word" | sed -E "s|${escaped_flag_name}|$build_conda_libs/${lib_name}.lib|")
                updated_line+=" "
              elif [[ -f "$host_conda_libs/${lib_name}.lib" ]]; then
                $debug && echo "      Found in host_conda_libs: $host_conda_libs/${lib_name}.lib"
                updated_line+=$(echo "$word" | sed -E "s|${escaped_flag_name}|$host_conda_libs/${lib_name}.lib|")
                updated_line+=" "
              else
                $debug && echo "      Warning: Library file not found for '$lib_name'. Keeping unchanged."
                updated_line+="$word "
              fi
            fi
          else
            updated_line+="$word "
          fi
        done

        $debug && echo "    Updated line: $updated_line"
        echo "$updated_line" >> "$tmpfile"
      else
        # $debug && echo "  Non-matching line: $line"
        echo "$line" >> "$tmpfile"
      fi
    done < "$file"

    # Overwrite the original file with the updated content
    mv "$tmpfile" "$file" || { echo "Error: Failed to replace original file $file with $tmpfile" >&2; exit 1; }
    chmod +x "$file"
    $debug && echo "  Successfully updated file: $file"
  else
    $debug && echo "Error: File $file does not exist"
  fi
}

replace_l_flag_in_files() {
  local files=("$@")
  for file in "${files[@]}"; do
    echo "   Updating: $file"
    replace_l_flag_in_file "$file"
  done
}

# Get an updated config.sub and config.guess
cp "$BUILD_PREFIX"/share/gnuconfig/config.* .

export XDG_DATA_DIRS=${XDG_DATA_DIRS}:$PREFIX/share

GDKTARGET=""
if [[ "${target_platform}" == osx-* ]]; then
    export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:${PREFIX}/share/pkgconfig:${BUILD_PREFIX}/lib/pkgconfig${PKG_CONFIG_PATH:+:}${PKG_CONFIG_PATH}"
    export GDKTARGET="quartz"
    export LDFLAGS="${LDFLAGS} -Wl,-rpath,${PREFIX}/lib -framework Carbon"
    # https://discourse.llvm.org/t/clang-16-notice-of-potentially-breaking-changes/65562
    export CFLAGS="${CFLAGS} -Wno-error=incompatible-function-pointer-types"
elif [[ "${target_platform}" == linux-* ]]; then
    export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:${PREFIX}/share/pkgconfig:${BUILD_PREFIX}/lib/pkgconfig${PKG_CONFIG_PATH:+:}${PKG_CONFIG_PATH}"
    export GDKTARGET="x11"
    export LDFLAGS="${LDFLAGS} -Wl,-rpath=${PREFIX}/lib"
elif [[ "${target_platform}" == win-* ]]; then
    # Set the prefix to the PKG_CONFIG_PATH
    paths=(
        "${host_conda_libs}/pkgconfig"
        "${build_conda_libs}/pkgconfig"
    )

    # Loop through the paths and update PKG_CONFIG_PATH
    for path in "${paths[@]}"; do
        _pkg_config_path=$(echo "$path" | sed 's|^\(\w\):|/\1/|g')
        PKG_CONFIG_PATH="${PKG_CONFIG_PATH}${PKG_CONFIG_PATH:+:}${_pkg_config_path}"
    done

    export PKG_CONFIG_PATH
    export PKG_CONFIG_LIBDIR="${PKG_CONFIG_PATH}"
    export PATH="${BUILD_PREFIX}/Library/bin:${PREFIX}/Library/bin:${PATH}"

    export PERL5LIB="${BUILD_PREFIX}/lib/perl5/site-perl:${PERL5LIB:+:${PERL5LIB:-}}"
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

if [[ "${CONDA_BUILD_CROSS_COMPILATION:-0}" == 1 ]]; then
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

    # This script would generate the functions.txt and dump.xml and save them
    # This is loaded in the native build. We assume that the functions exported
    # by glib are the same for the native and cross builds
    export GI_CROSS_LAUNCHER=$BUILD_PREFIX/libexec/gi-cross-launcher-save.sh
    make -j${CPU_COUNT}
    make install
    popd
  )
  export GI_CROSS_LAUNCHER=$BUILD_PREFIX/libexec/gi-cross-launcher-load.sh

  # The build system needs to run glib tools like `glib-mkenums` but discovers
  # the path to them using pkg-config by default. If we let this happen, when
  # cross-compiling it will try to run a program with the wrong CPU type.
  export GLIB_COMPILE_RESOURCES=$BUILD_PREFIX/bin/glib-compile-resources
  export GLIB_GENMARSHAL=$BUILD_PREFIX/bin/glib-genmarshal
  export GLIB_MKENUMS=$BUILD_PREFIX/bin/glib-mkenums
fi

if [[ "${target_platform}" != win-* ]]; then
  PKG_CONFIG_PATH="${PKG_CONFIG_PATH}${PKG_CONFIG_PATH:+:}$BUILD_PREFIX/lib/pkgconfig"
  export PKG_CONFIG_PATH
else
  PKG_CONFIG=$(which pkg-config.exe | sed 's|^/\(\w\)|\1:|g')
  export PKG_CONFIG
  # Loop over the dependencies and get the cflags and libs
  for dep in "glib-2.0 >= 2.28.0" "atk >= 1.29.2" "pango >= 1.20" "cairo >= 1.6" "gdk-pixbuf-2.0 >= 2.21.0"; do
    cflags=$($PKG_CONFIG --cflags "$dep" 2>/dev/null)
    if [ $? -ne 0 ]; then
      echo "Error: Failed to get CFLAGS for $dep"
      exit 1
    fi
    libs=$($PKG_CONFIG --libs "$dep" 2>/dev/null)
    if [ $? -ne 0 ]; then
      echo "Error: Failed to get LIBS for $dep"
      exit 1
    fi
    BASE_DEPENDENCIES_CFLAGS="${BASE_DEPENDENCIES_CFLAGS:-} ${cflags}"
    BASE_DEPENDENCIES_LIBS="${BASE_DEPENDENCIES_LIBS:-} ${libs}"
  done
  BASE_DEPENDENCIES_CFLAGS=$(unique_from_last "${BASE_DEPENDENCIES_CFLAGS}")
  BASE_DEPENDENCIES_LIBS=$(unique_from_last "${BASE_DEPENDENCIES_LIBS}")
  BASE_DEPENDENCIES_LIBS=$(replace_l_flags "${BASE_DEPENDENCIES_LIBS}" "${host_conda_libs}" "${build_conda_libs}")

  export BASE_DEPENDENCIES_CFLAGS
  export BASE_DEPENDENCIES_LIBS

  # Odd case of pkg-config not having the --uninstalled option on windows.
  # Replace all the '$PKG_CONFIG +--uninstalled with false || $PKG_CONFIG --uninstalled
  perl -i -pe 's/\$PKG_CONFIG --uninstalled/false \&\& $PKG_CONFIG --uninstalled/g' configure

  # This test fails, let's force it to pass for now
  perl -i -pe 's/\$PKG_CONFIG --atleast-version \$min_glib_version \$pkg_config_args/test x = x/g' configure

  # -Lppp -lxxx will apparently look for ppp/libxxx.lib (or dll.a), only ppp/xxx.lib exists - Only -lintl & -liconv present
  perl -i -pe "s#-lintl#${PREFIX}/Library/lib/intl.lib#g if /^\s*[IL]\w*IBS/" configure
  perl -i -pe "s#-liconv#${BUILD_PREFIX}/Library/lib/iconv.lib#g if /^\s*[IL]\w*IBS/" configure

  export LIBRARY_PATH="${build_conda_libs}:${host_conda_libs}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH:-}}"
  export PATH="${BUILD_PREFIX}/Library/bin:${PREFIX}/Library/bin${PATH:+:${PATH:-}}"

  configure_args+=(
    "--libexecdir=${PREFIX}/Library/bin"
    "--libdir=${host_conda_libs}"
    "--includedir=${PREFIX}/Library/include"
    "--enable-shared"
    "--disable-static"
    "--enable-explicit-deps=yes"
  )
  PYTHON="$(which python)"
  GLIB_COMPILE_RESOURCES="$PYTHON $(which glib-compile-resources)"
  GLIB_MKENUMS="$PYTHON $(which glib-mkenums)"
  GLIB_GENMARSHAL="$PYTHON $(which glib-genmarshal)"

  export GLIB_COMPILE_RESOURCES GLIB_GENMARSHAL GLIB_MKENUMS
fi

./configure --enable-debug=yes \
    --prefix="${PREFIX}" \
    "${configure_args[@]}"

if [[ "${target_platform}" = win-* ]]; then
  echo "Modifying Makefiles for -l<conda_lib>"
  # -Lppp -lxxx will apparently look for ppp/libxxx.lib (or dll.a), only ppp/xxx.lib exists
  makefiles=(
    "Makefile"
    "gdk/Makefile"
    "gdk/win32/Makefile"
  )
  while IFS= read -r file; do
    makefiles+=("$file")
  done < <(find modules gtk -name Makefile)
  replace_l_flag_in_files "${makefiles[@]}"

  # It appears that pkg-config is difficult to find within the mix of win/unix path separator (or at least that's how it appeared to me)
  perl -i -pe "s|(PKG_CONFIG)(\s*)=.*|\1\2=\2${PKG_CONFIG}|g"  "${makefiles[@]}"

  # Similarly for the .gir paths
  perl -i -pe "s|(--add-include-path=../gdk)|\1 --add-include-path=${BUILD_PREFIX}/Library/share/gir-1.0 --add-include-path=${PREFIX}/Library/share/gir-1.0|" "${makefiles[@]}"
  perl -i -pe 's|(--add-include-path=../gdk)|--verbose \1|' "${makefiles[@]}"
  perl -i -pe "s|(\s+--includedir=\.)|\1 --includedir=${BUILD_PREFIX}/Library/share/gir-1.0 --includedir=${PREFIX}/Library/share/gir-1.0|" gdk/Makefile
  perl -i -pe "s|(\s+--includedir=\.\./gdk)|\1 --includedir=${BUILD_PREFIX}/Library/share/gir-1.0 --includedir=${PREFIX}/Library/share/gir-1.0|" gtk/Makefile

  # It seems that libtool is missing some dynamic libraries to create the .dll
  perl -i -pe "s|(libgdk_win32_2_0_la_LIBADD = win32/libgdk-win32.la)|\1 -Wl,-L${build_conda_libs} -Wl,-L${host_conda_libs} -Wl,-lglib-2.0 -Wl,-lgobject-2.0 -Wl,-lgio-2.0 -Wl,-lcairo -Wl,-lgdk_pixbuf-2.0 -Wl,-lpango-1.0 -Wl,-lpangocairo-1.0 -Wl,-lintl|" gdk/Makefile
  perl -i -pe "s|(libgtk_win32_2_0_la_LIBADD.+?-lcomctl32)|\1 -Wl,-L${build_conda_libs} -Wl,-L${host_conda_libs} -Wl,-lglib-2.0 -Wl,-lgmodule-2.0 -Wl,-lgobject-2.0 -Wl,-latk-1.0 -Wl,-lgio-2.0 -Wl,-lcairo -Wl,-lgdk_pixbuf-2.0 -Wl,-lpango-1.0 -Wl,-lpangocairo-1.0 -Wl,-lintl|" gtk/Makefile

  # Specifying the compiler as GCC. Setting the system name to MINGW64 to avoid python lib defaulting to cl.exe on windows
  # The error is: Specified Compiler 'C:/.../x86_64-w64-mingw32-cc.exe' is unsupported.
  perl -i -pe 's|INTROSPECTION_TYPELIBDIR|INTROSPECTION_SCANNER_ENV = MSYSTEM=MINGW64\nINTROSPECTION_TYPELIBDIR|'  "${makefiles[@]}"
fi

make V=0 -j"$CPU_COUNT"
# make check -j$CPU_COUNT
make install -j$CPU_COUNT

# We use the GTK 3 version of gtk-update-icon-cache
# https://github.com/conda-forge/gtk2-feedstock/issues/24
rm -f ${PREFIX}/bin/gtk-update-icon-cache*
rm -f ${PREFIX}/share/man/man1/gtk-update-icon-cache.1
