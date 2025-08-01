{
  cudaMajorMinorVersion,
  runPatches ? [ ],
  autoPatchelfHook,
  autoAddDriverRunpath,
  addDriverRunpath,
  alsa-lib,
  curlMinimal,
  expat,
  fetchurl,
  fontconfig,
  freetype,
  gdk-pixbuf,
  glib,
  glibc,
  gst_all_1,
  gtk2,
  lib,
  libxcrypt-legacy,
  libxkbcommon,
  libkrb5,
  libxml2,
  krb5,
  makeWrapper,
  markForCudatoolkitRootHook,
  ncurses5,
  ncurses6,
  numactl,
  nss,
  patchelf,
  perl,
  python3, # FIXME: CUDAToolkit 10 may still need python27
  python310,
  python311,
  python312,
  pulseaudio,
  setupCudaHook,
  stdenv,
  backendStdenv, # E.g. gcc11Stdenv, set in extension.nix
  unixODBC,
  wayland,
  xorg,
  zlib,
  libglut,
  libGLU,
  libsForQt5,
  libtiff,
  qt6Packages,
  qt6,
  rdma-core,
  ucx,
  rsync,
  libglvnd,
}:

let
  # Version info for the classic cudatoolkit packages that contain everything that is in redist.
  releases = builtins.import ./releases.nix;
  release = releases.${cudaMajorMinorVersion};
in

backendStdenv.mkDerivation rec {
  pname = "cudatoolkit";
  inherit (release) version;
  inherit runPatches;

  dontPatchELF = true;
  dontStrip = true;

  src = fetchurl { inherit (release) url sha256; };

  outputs = [
    "out"
    "lib"
    "doc"
  ];

  nativeBuildInputs = [
    perl
    makeWrapper
    rsync
    addDriverRunpath
    autoPatchelfHook
    autoAddDriverRunpath
    markForCudatoolkitRootHook
  ] ++ lib.optionals (lib.versionAtLeast version "11.8") [ qt6Packages.wrapQtAppsHook ];
  propagatedBuildInputs = [ setupCudaHook ];
  buildInputs =
    [
      # To get $GDK_PIXBUF_MODULE_FILE via setup-hook
      gdk-pixbuf

      # For autoPatchelf
      ncurses5
      expat
      python3
      zlib
      glibc
      xorg.libX11
      xorg.libXext
      xorg.libXrender
      xorg.libXt
      xorg.libXtst
      xorg.libXi
      xorg.libXext
      xorg.libXdamage
      xorg.libxcb
      xorg.xcbutilimage
      xorg.xcbutilrenderutil
      xorg.xcbutilwm
      xorg.xcbutilkeysyms
      pulseaudio
      libxkbcommon
      libkrb5
      krb5
      gtk2
      glib
      fontconfig
      freetype
      numactl
      nss
      unixODBC
      alsa-lib
      wayland
      libglvnd
    ]
    ++ lib.optionals (lib.versionAtLeast version "11.8") [
      (lib.getLib libtiff)
      qt6Packages.qtwayland
      rdma-core
      (ucx.override { enableCuda = false; }) # Avoid infinite recursion
      xorg.libxshmfence
      xorg.libxkbfile
    ]
    ++ (lib.optionals (lib.versionAtLeast version "12") (
      map lib.getLib ([
        # Used by `/target-linux-x64/CollectX/clx` and `/target-linux-x64/CollectX/libclx_api.so` for:
        # - `libcurl.so.4`
        curlMinimal

        # Used by `/host-linux-x64/Scripts/WebRTCContainer/setup/neko/server/bin/neko`
        gst_all_1.gstreamer
        gst_all_1.gst-plugins-base
      ])
      ++ (with qt6; [
        qtmultimedia
        qttools
        qtpositioning
        qtscxml
        qtsvg
        qtwebchannel
        qtwebengine
      ])
    ))
    ++ lib.optionals (lib.versionAtLeast version "12.6") [
      # libcrypt.so.1
      libxcrypt-legacy
      ncurses6
      python310
      python311
    ]
    ++ lib.optionals (lib.versionAtLeast version "12.9") [
      # Replace once https://github.com/NixOS/nixpkgs/pull/421740 is merged.
      (libxml2.overrideAttrs rec {
        version = "2.13.8";
        src = fetchurl {
          url = "mirror://gnome/sources/libxml2/${lib.versions.majorMinor version}/libxml2-${version}.tar.xz";
          hash = "sha256-J3KUyzMRmrcbK8gfL0Rem8lDW4k60VuyzSsOhZoO6Eo=";
        };
      })
      python312
    ];

  # Prepended to runpaths by autoPatchelf.
  # The order inherited from older rpath preFixup code
  runtimeDependencies = [
    (placeholder "lib")
    (placeholder "out")
    "${placeholder "out"}/nvvm"
    # NOTE: use the same libstdc++ as the rest of nixpkgs, not from backendStdenv
    "${lib.getLib stdenv.cc.cc}/lib64"
    "${placeholder "out"}/jre/lib/amd64/jli"
    "${placeholder "out"}/lib64"
    "${placeholder "out"}/nvvm/lib64"
  ];

  autoPatchelfIgnoreMissingDeps = [
    # This is the hardware-dependent userspace driver that comes from
    # nvidia_x11 package. It must be deployed at runtime in
    # /run/opengl-driver/lib or pointed at by LD_LIBRARY_PATH variable, rather
    # than pinned in runpath
    "libcuda.so.1"

    # Similar to libcuda.so.1, this is part of the driver package.
    "libnvidia-ml.so.1"

    # The krb5 expression ships libcom_err.so.3 but cudatoolkit asks for the
    # older
    # This dependency is asked for by target-linux-x64/CollectX/RedHat/x86_64/libssl.so.10
    # - do we even want to use nvidia-shipped libssl?
    "libcom_err.so.2"
  ];

  preFixup = ''
    ${lib.getExe' patchelf "patchelf"} $out/lib64/libnvrtc.so --add-needed libnvrtc-builtins.so
  '';

  unpackPhase = ''
    sh $src --keep --noexec
  '';

  installPhase =
    ''
      runHook preInstall
      mkdir $out
      mkdir -p $out/bin $out/lib64 $out/include $doc
      for dir in pkg/builds/* pkg/builds/cuda_nvcc/nvvm pkg/builds/cuda_cupti/extras/CUPTI; do
        if [ -d $dir/bin ]; then
          mv $dir/bin/* $out/bin
        fi
        if [ -d $dir/doc ]; then
          (cd $dir/doc && find . -type d -exec mkdir -p $doc/\{} \;)
          (cd $dir/doc && find . \( -type f -o -type l \) -exec mv \{} $doc/\{} \;)
        fi
        if [ -L $dir/include ] || [ -d $dir/include ]; then
          (cd $dir/include && find . -type d -exec mkdir -p $out/include/\{} \;)
          (cd $dir/include && find . \( -type f -o -type l \) -exec mv \{} $out/include/\{} \;)
        fi
        if [ -L $dir/lib64 ] || [ -d $dir/lib64 ]; then
          (cd $dir/lib64 && find . -type d -exec mkdir -p $out/lib64/\{} \;)
          (cd $dir/lib64 && find . \( -type f -o -type l \) -exec mv \{} $out/lib64/\{} \;)
        fi
      done
      mv pkg/builds/cuda_nvcc/nvvm $out/nvvm

      mv pkg/builds/cuda_sanitizer_api $out/cuda_sanitizer_api
      ln -s $out/cuda_sanitizer_api/compute-sanitizer/compute-sanitizer $out/bin/compute-sanitizer

      mv pkg/builds/nsight_systems/target-linux-x64 $out/target-linux-x64
      mv pkg/builds/nsight_systems/host-linux-x64 $out/host-linux-x64
      rm $out/host-linux-x64/libstdc++.so*
        ${lib.optionalString (lib.versionAtLeast version "11.8" && lib.versionOlder version "12")
          # error: auto-patchelf could not satisfy dependency libtiff.so.5 wanted by /nix/store/.......-cudatoolkit-12.0.1/host-linux-x64/Plugins/imageformats/libqtiff.so
          # we only ship libtiff.so.6, so let's use qt plugins built by Nix.
          # TODO: don't copy, come up with a symlink-based "merge"
          ''
            rsync ${lib.getLib qt6Packages.qtimageformats}/lib/qt-6/plugins/ $out/host-linux-x64/Plugins/ -aP
          ''
        }
        ${lib.optionalString (lib.versionAtLeast version "12")
          # Use Qt plugins built by Nix.
          ''
            for qtlib in $out/host-linux-x64/Plugins/*/libq*.so; do
              qtdir=$(basename $(dirname $qtlib))
              filename=$(basename $qtlib)
              for qtpkgdir in ${
                lib.concatMapStringsSep " " (x: qt6Packages.${x}) [
                  "qtbase"
                  "qtimageformats"
                  "qtsvg"
                  "qtwayland"
                ]
              }; do
                if [ -e $qtpkgdir/lib/qt-6/plugins/$qtdir/$filename ]; then
                  ln -snf $qtpkgdir/lib/qt-6/plugins/$qtdir/$filename $qtlib
                fi
              done
            done
          ''
        }

      rm -f $out/tools/CUDA_Occupancy_Calculator.xls # FIXME: why?

      ${lib.optionalString (lib.versionAtLeast version "12.0") ''
        rm $out/host-linux-x64/libQt6*
      ''}

      # Fixup path to samples (needed for cuda 6.5 or else nsight will not find them)
      if [ -d "$out"/cuda-samples ]; then
          mv "$out"/cuda-samples "$out"/samples
      fi

      # Change the #error on GCC > 4.9 to a #warning.
      sed -i $out/include/host_config.h -e 's/#error\(.*unsupported GNU version\)/#warning\1/'

      # Fix builds with newer glibc version
      sed -i "1 i#define _BITS_FLOATN_H" "$out/include/host_defines.h"
    ''
    +
      # Point NVCC at a compatible compiler
      # CUDA_TOOLKIT_ROOT_DIR is legacy,
      # Cf. https://cmake.org/cmake/help/latest/module/FindCUDA.html#input-variables
      ''
        mkdir -p $out/nix-support
        cat <<EOF >> $out/nix-support/setup-hook
        cmakeFlags+=' -DCUDA_TOOLKIT_ROOT_DIR=$out'
        EOF

        # Move some libraries to the lib output so that programs that
        # depend on them don't pull in this entire monstrosity.
        mkdir -p $lib/lib
        mv -v $out/lib64/libcudart* $lib/lib/

        # Remove OpenCL libraries as they are provided by ocl-icd and driver.
        rm -f $out/lib64/libOpenCL*

        # nvprof do not find any program to profile if LD_LIBRARY_PATH is not set
        wrapProgram $out/bin/nvprof \
          --prefix LD_LIBRARY_PATH : $out/lib
      ''
    # 11.8 and 12.9 include a broken symlink, include/include, pointing to targets/x86_64-linux/include
    +
      lib.optionalString
        (lib.versions.majorMinor version == "11.8" || lib.versions.majorMinor version == "12.9")
        ''
          rm $out/include/include
        ''
    # 12.9 has another broken symlink, lib64/lib64, pointing to lib/targets/x86_64-linux/lib
    + lib.optionalString (lib.versions.majorMinor version == "12.9") ''
      rm $out/lib64/lib64
    ''
    # Python 3.8 and 3.9 are not in nixpkgs anymore, delete Python 3.{8,9} cuda-gdb support
    # to avoid autopatchelf failing to find libpython3.{8,9}.so.
    + lib.optionalString (lib.versionAtLeast version "12.6") ''
      find $out -name '*python3.8*' -delete
      find $out -name '*python3.9*' -delete
    ''
    + ''
      runHook postInstall
    '';

  postInstall = ''
    for b in nvvp; do
      wrapProgram "$out/bin/$b" \
        --set GDK_PIXBUF_MODULE_FILE "$GDK_PIXBUF_MODULE_FILE"
    done
    ${lib.optionalString (lib.versionAtLeast version "12")
      # Check we don't have any lurking vendored qt libraries that weren't
      # replaced during installPhase
      ''
        qtlibfiles=$(find $out -name "libq*.so" -type f)
        if [ ! -z "$qtlibfiles" ]; then
          echo "Found unexpected vendored Qt library files in $out" >&2
          echo $qtlibfiles >&2
          echo "These should be replaced with symlinks in installPhase" >&2
          exit 1
        fi
      ''
    }
  '';

  # cuda-gdb doesn't run correctly when not using sandboxing, so
  # temporarily disabling the install check.  This should be set to true
  # when we figure out how to get `cuda-gdb --version` to run correctly
  # when not using sandboxing.
  doInstallCheck = false;
  postInstallCheck = ''
    # Smoke test binaries
    pushd $out/bin
    for f in *; do
      case $f in
        crt)                           continue;;
        nvcc.profile)                  continue;;
        nsight_ee_plugins_manage.sh)   continue;;
        uninstall_cuda_toolkit_6.5.pl) continue;;
        computeprof|nvvp|nsight)       continue;; # GUIs don't feature "--version"
        *)                             echo "Executing '$f --version':"; ./$f --version;;
      esac
    done
    popd
  '';
  passthru = {
    inherit (backendStdenv) cc;
    majorMinorVersion = lib.versions.majorMinor version;
    majorVersion = lib.versions.majorMinor version;
  };

  meta = with lib; {
    description = "Deprecated runfile-based CUDAToolkit installation (a compiler for NVIDIA GPUs, math libraries, and tools)";
    homepage = "https://developer.nvidia.com/cuda-toolkit";
    platforms = [ "x86_64-linux" ];
    license = licenses.nvidiaCuda;
    teams = [ teams.cuda ];
  };
}
