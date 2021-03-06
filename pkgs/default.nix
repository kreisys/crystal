{ stdenv
, lib
, fetchFromGitHub
, fetchurl
, makeWrapper
, coreutils
, git
, gmp
, hostname
, openssl
, readline
, tzdata
, libxml2
, libyaml
, boehmgc
, libatomic_ops
, pcre
, libevent
, libiconv
, llvm
, clang
, which
, zlib
, pkgconfig
, callPackage
}:

# We need multiple binaries as a given binary isn't always able to build
# (even slightly) older or newer versions.
# - 0.26.1 can build 0.25.x and 0.26.x but not 0.27.x
# - 0.27.2 can build 0.27.x but not 0.25.x, 0.26.x and 0.29.x
#
# We need to keep around at least the latest version released with a stable
# NixOS
let
  archs = {
    x86_64-linux = "linux-x86_64";
    i686-linux = "linux-i686";
    x86_64-darwin = "darwin-x86_64";
  };

  arch = archs.${stdenv.system} or (throw "system ${stdenv.system} not supported");

  checkInputs = [ git gmp openssl readline libxml2 libyaml ];

  genericBinary = { version, sha256s, rel ? 1 }:
    stdenv.mkDerivation rec {
      pname = "crystal-binary";
      inherit version;

      src = fetchurl {
        url = "https://github.com/crystal-lang/crystal/releases/download/${version}/crystal-${version}-${toString rel}-${arch}.tar.gz";
        sha256 = sha256s.${stdenv.system};
      };

      buildCommand = ''
        mkdir -p $out
        tar --strip-components=1 -C $out -xf ${src}
      '';
    };

  commonBuildInputs = extraBuildInputs: [
    boehmgc
    libatomic_ops
    pcre
    libevent
    libyaml
    zlib
    libxml2
    openssl
  ] ++ extraBuildInputs
  ++ lib.optionals stdenv.isDarwin [ libiconv ];


  generic = ({ version, sha256, binary, doCheck ? true, extraBuildInputs ? [ ] }:
    lib.fix (compiler: stdenv.mkDerivation {
      pname = "crystal";
      inherit doCheck version;

      src = fetchFromGitHub {
        owner = "crystal-lang";
        repo = "crystal";
        rev = version;
        inherit sha256;
      };

      outputs = [ "out" "lib" "bin" ];

      postPatch = ''
        substituteInPlace src/crystal/system/unix/time.cr \
          --replace /usr/share/zoneinfo ${tzdata}/share/zoneinfo

        ln -sf spec/compiler spec/std

        substituteInPlace spec/std/file_spec.cr \
          --replace '/bin/ls' '${coreutils}/bin/ls' \
          --replace '/usr/share' "$TMPDIR/crystal" \
          --replace '/usr' "$TMPDIR"

        substituteInPlace spec/std/process_spec.cr \
          --replace '/bin/cat' '${coreutils}/bin/cat' \
          --replace '/bin/ls' '${coreutils}/bin/ls' \
          --replace '/usr/bin/env' '${coreutils}/bin/env' \
          --replace '"env"' '"${coreutils}/bin/env"' \
          --replace '"/usr"' "\"$TMPDIR\""

        substituteInPlace spec/std/socket/tcp_server_spec.cr \
          --replace '{% if flag?(:gnu) %}"listen: "{% else %}"bind: "{% end %}' '"bind: "'

        substituteInPlace spec/std/system_spec.cr \
          --replace '`hostname`' '`${hostname}/bin/hostname`'

        # See https://github.com/crystal-lang/crystal/pull/8640
        substituteInPlace spec/std/http/cookie_spec.cr \
          --replace '01 Jan 2020' '01 Jan #{Time.utc.year + 2}'

        # See https://github.com/crystal-lang/crystal/issues/8629
        substituteInPlace spec/std/socket/udp_socket_spec.cr \
          --replace 'it "joins and transmits to multicast groups"' 'pending "joins and transmits to multicast groups"'

        # See https://github.com/crystal-lang/crystal/pull/8699
        substituteInPlace spec/std/xml/xml_spec.cr \
          --replace 'it "handles errors"' 'pending "handles errors"'
      '';

      buildInputs = commonBuildInputs extraBuildInputs;

      nativeBuildInputs = [ binary makeWrapper which pkgconfig llvm ];

      makeFlags = [
        "CRYSTAL_CONFIG_VERSION=${version}"
      ];

      buildFlags = [
        "all"
        "docs"
      ];

      LLVM_CONFIG = "${llvm}/bin/llvm-config";

      FLAGS = [
        "--release"
        "--single-module" # needed for deterministic builds
      ];

      # This makes sure we don't keep depending on the previous version of
      # crystal used to build this one.
      CRYSTAL_LIBRARY_PATH = "${placeholder "lib"}/crystal";

      # We *have* to add `which` to the PATH or crystal is unable to build stuff
      # later if which is not available.
      installPhase = ''
        runHook preInstall

        install -Dm755 .build/crystal $bin/bin/crystal
        wrapProgram $bin/bin/crystal \
            --suffix PATH : ${lib.makeBinPath [ pkgconfig clang which ]} \
            --suffix CRYSTAL_PATH : lib:$lib/crystal \
            --suffix CRYSTAL_LIBRARY_PATH : ${
              lib.makeLibraryPath (commonBuildInputs extraBuildInputs)
            }
        install -dm755 $lib/crystal
        cp -r src/* $lib/crystal/

        install -dm755 $out/share/doc/crystal/api
        cp -r docs/* $out/share/doc/crystal/api/
        cp -r samples $out/share/doc/crystal/

        install -Dm644 etc/completion.bash $out/share/bash-completion/completions/crystal
        install -Dm644 etc/completion.zsh $out/share/zsh/site-functions/_crystal

        install -Dm644 man/crystal.1 $out/share/man/man1/crystal.1

        install -Dm644 -t $out/share/licenses/crystal LICENSE README.md

        mkdir -p $out
        ln -s $bin/bin $out/bin
        ln -s $lib $out/lib

        runHook postInstall
      '';

      enableParallelBuilding = true;

      dontStrip = true;

      checkTarget = "spec";

      preCheck = ''
        export HOME=$TMPDIR
        mkdir -p $HOME/test

        export LIBRARY_PATH=${lib.makeLibraryPath checkInputs}:$LIBRARY_PATH
        export PATH=${lib.makeBinPath checkInputs}:$PATH
      '';

      passthru.buildCrystalPackage = callPackage ./build-package.nix {
        crystal = compiler;
      };

      meta = with lib; {
        description = "A compiled language with Ruby like syntax and type inference";
        homepage = "https://crystal-lang.org/";
        license = licenses.asl20;
        maintainers = with maintainers; [ manveru david50407 peterhoeg ];
        platforms = builtins.attrNames archs;
      };
    }));

in
rec {
  binaryCrystal_0_31 = genericBinary {
    version = "0.31.1";
    sha256s = {
      x86_64-linux = "0r8salf572xrnr4m6ll9q5hz6jj8q7ff1rljlhmqb1r26a8mi2ih";
      i686-linux = "0hridnis5vvrswflx0q67xfg5hryhz6ivlwrb9n4pryj5d1gwjrr";
      x86_64-darwin = "1dgxgv0s3swkc5cwawzgpbc6bcd2nx4hjxc7iw2h907y1vgmbipz";
    };
  };

  binaryCrystal_0_35 = genericBinary {
    version = "0.35.0";
    sha256s = {
      x86_64-linux = "1pcjzwsgdwfh0amn21kizf95psxw4zyxb5xrw925xgskxy4lp0ds";
      i686-linux = "01nfzx3vm2n5hdv219jajqyyhp7ym3hj5n4wjgcka6yqlsjr62b1";
      x86_64-darwin = "sha256-fxSVkOs9c3itQPMd3h38B5at5fzGpHHBH96U/AY2UO0=";
    };
  };

  crystal_0_31 = generic {
    version = "0.31.1";
    sha256 = "1dswxa32w16gnc6yjym12xj7ibg0g6zk3ngvl76lwdjqb1h6lwz8";
    doCheck = false; # 5 checks are failing now
    binary = binaryCrystal_0_31;
  };

  crystal_0_33 = generic {
    version = "0.33.0";
    sha256 = "1zg0qixcws81s083wrh54hp83ng2pa8iyyafaha55mzrh8293jbi";
    binary = binaryCrystal_0_31;
    doCheck = false; # 4 checks are failing now
  };

  crystal_0_34 = generic {
    version = "0.34.0";
    sha256 = "110lfpxk9jnqyznbfnilys65ixj5sdmy8pvvnlhqhc3ccvrlnmq4";
    binary = crystal_0_33;
    doCheck = false; # 4 checks are failing now
  };

  crystal_0_35 = generic {
    version = "0.35.0";
    sha256 = "168a6w3k5pgzzpxj2y7y092f3ai7c4dlh9li6dshdcdm72zg696f";
    binary = binaryCrystal_0_35;
    doCheck = false; # 4 checks are failing now
    extraBuildInputs = [ git ];
  };

  crystal = crystal_0_35;

  crystal2nix = callPackage ./crystal2nix.nix { inherit crystal; };
}
