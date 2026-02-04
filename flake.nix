{
  description = "Apache Spark nix build";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachSystem [ "x86_64-linux" ] (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
        };

        sparkVersion = "3.5.8";
        mvnExtraArgs = "-Pkubernetes";
        scala-pkg = pkgs.scala_2_13;

        jdk-pkg = pkgs.temurin-bin-17;

        maven-pkg = pkgs.maven.override {
          jdk_headless = jdk-pkg;
        };

        protobuf-pkg = pkgs.protobuf_25;

        grpc-java-suffix = {
          "x86_64-linux" = "linux-x86_64.exe";
        };

        grpc-java-version = "1.56.0";
        grpc-java-hash = {
          "x86_64-linux" = "sha256-oRSCvwLTowg5XoGhDMMzWqdXPBheLtl4DVUiiVbW4yc=";
        };
        grpc-java-pkg = pkgs.stdenv.mkDerivation {
          name = "protoc-gen-grpc-java";
          version = grpc-java-version;
          src = pkgs.fetchurl {
            url = "https://repo1.maven.org/maven2/io/grpc/protoc-gen-grpc-java/${grpc-java-version}/protoc-gen-grpc-java-${grpc-java-version}-${grpc-java-suffix.${system}}";
            sha256 = grpc-java-hash.${system};
          };
          dontUnpack = true;
          meta.mainProgram = "protoc-gen-grpc-java";

          nativeBuildInputs = [
            pkgs.autoPatchelfHook
            pkgs.stdenv.cc.cc.lib
          ];

          installPhase = ''
            mkdir -p $out/bin
            cp $src $out/bin/protoc-gen-grpc-java
            chmod +x $out/bin/protoc-gen-grpc-java
          '';
        };

        spark-src = pkgs.stdenv.mkDerivation {
          name = "spark-${sparkVersion}-patched-src";
          src = pkgs.fetchFromGitHub {
            owner = "apache";
            repo = "spark";
            tag = "v${sparkVersion}";
            hash = "sha256-M91McGXYTawtRnUSPOmU7cyfzOik9SqlRPvPp4naqGg=";
          };

          JAVA_HOME = jdk-pkg.home;
          MVN_BIN = pkgs.lib.getExe maven-pkg;

          buildPhase = ''
            echo "Pathing mvn and sbt wrappers..."
            patchShebangs .
            substituteInPlace ./build/mvn \
              --replace-fail 'install_mvn()' 'never_install_mvn()' \
              --replace-fail 'install_scala()' 'never_install_scala()'

            substituteInPlace ./build/mvn \
              --replace-fail 'install_mvn' "" \
              --replace-fail 'install_scala' ""

            substituteInPlace ./project/SparkBuild.scala \
              --replace-fail 'val protoVersion = "3.23.4"' 'val protoVersion = "$PROTO_VERSION"'

            substituteInPlace ./build/sbt-launch-lib.bash \
              --replace-fail '[[ -f "$sbt_jar" ]] || acquire_sbt_jar "$sbt_version" || {' "true || {" \
              --replace-fail '-jar "$sbt_jar"' "-jar $SBT_JAR"

            substituteInPlace ./dev/change-scala-version.sh \
              --replace-fail 'build/mvn dependency:get -Dartifact=commons-cli:commons-cli:''${COMMONS_CLI_VERSION} -q' "" \
              --replace-fail 'COMMONS_CLI_VERSION=`build/mvn help:evaluate -Dexpression=commons-cli.version -q -DforceStdout`' "" \
              --replace-fail '`build/mvn help:evaluate -Pscala-''${TO_VERSION} -Dexpression=scala.version -q -DforceStdout`' "${scala-pkg.version}"

            scala_version=$(echo ${scala-pkg.version} | awk -F. '{print $1"."$2}')
            echo "Swithcih Scala version to $scala_version..."
            ./dev/change-scala-version.sh $scala_version
          '';

          dontFixup = true;

          installPhase = ''
            cp -R ./ $out/
          '';
        };

        externalDepsHash = {
          "x86_64-linux" = "sha256-HWx6ANvn5+TSpMUqWqv1FjN9cFUMRe37l5n4bTQHK/M=";
        };
        external-deps = pkgs.stdenv.mkDerivation {
          name = "spark-${sparkVersion}-external-deps";
          src = spark-src;

          nativeBuildInputs = [
            maven-pkg
            pkgs.patchelf
            pkgs.autoPatchelfHook
            grpc-java-pkg
            protobuf-pkg
            pkgs.strip-nondeterminism
          ];

          JAVA_HOME = jdk-pkg.home;
          MVN_BIN = pkgs.lib.getExe maven-pkg;
          SCALA_COMPILER = "${scala-pkg}/lib/scala-compiler.jar";
          SCALA_LIBRARY = "${scala-pkg}/lib/scala-library.jar";
          SPARK_PROTOC_EXEC_PATH = pkgs.lib.getExe protobuf-pkg;
          CONNECT_PLUGIN_EXEC_PATH = pkgs.lib.getExe grpc-java-pkg;
          PROTO_VERSION = "3.${protobuf-pkg.version}";

          buildPhase = ''
            echo "Getting maven help plugin"
            mvn dependency:get -Dartifact=org.apache.maven.plugins:maven-help-plugin:3.5.1 -Dmaven.repo.local=$out/.m2
            mvn help:help -Dmaven.repo.local=$out/.m2 # Triggers metadata creation
            scala_version=$(echo ${scala-pkg.version} | awk -F. '{print $1"."$2}')
            echo "Buiding whole project to fetch all deps..."
            ./build/mvn \
                -DskipTests \
                -Dmaven.javadoc.skip=true \
                -Dmaven.scaladoc.skip=true \
                -Dmaven.source.skip \
                -Dcyclonedx.skip=true \
                -DskipDefaultProtoc \
                -Dprotobuf.version=3.${protobuf-pkg.version} \
                -Pscala-$scala_version \
                -Puser-defined-protoc \
                ${mvnExtraArgs} \
                package -DsecondaryCacheDir=$out/sbt-cache -Dmaven.repo.local=$out/.m2

            find $out -name 'org.scala-sbt-compiler-bridge_*' -type f -print0 | xargs -r0 strip-nondeterminism
            find $out -type f \( \
            -name \*.lastUpdated \
            -o -name resolver-status.properties \
            -o -name _remote.repositories \) \
            -delete
          '';

          outputHashAlgo = if externalDepsHash.${system} != "" then null else "sha256";
          outputHashMode = "recursive";
          outputHash = externalDepsHash.${system};
        };

        spark = pkgs.stdenv.mkDerivation {
          name = "spark-${sparkVersion}";
          src = spark-src;

          nativeBuildInputs = [
            maven-pkg
            pkgs.patchelf
            pkgs.autoPatchelfHook
            grpc-java-pkg
            protobuf-pkg
          ];

          buildInputs = [ jdk-pkg ];

          JAVA_HOME = jdk-pkg.home;
          MVN_BIN = pkgs.lib.getExe maven-pkg;
          SCALA_COMPILER = "${scala-pkg}/lib/scala-compiler.jar";
          SCALA_LIBRARY = "${scala-pkg}/lib/scala-library.jar";
          SPARK_PROTOC_EXEC_PATH = pkgs.lib.getExe protobuf-pkg;
          CONNECT_PLUGIN_EXEC_PATH = pkgs.lib.getExe grpc-java-pkg;
          PROTO_VERSION = "3.${protobuf-pkg.version}";

          buildPhase = ''
            echo "Installing maven dependancies"
            mvnDeps=$(cp -dpR ${external-deps}/.m2 ./ && chmod +w -R .m2 && pwd)

            echo "Installing scala compiler bridge jars"
            sbtDeps=$(cp -dpR ${external-deps}/sbt-cache ./ && chmod +w -R sbt-cache && pwd)

            echo "local maven repo = ${external-deps}/.m2"
            substituteInPlace ./dev/make-distribution.sh \
              --replace-fail 'DISTDIR="$SPARK_HOME/dist"' 'DISTDIR="$out"' \
              --replace-fail 'help:evaluate' 'help:evaluate -o -nsu' \
              --replace-fail 'BUILD_COMMAND=("$MVN" clean package' 'BUILD_COMMAND=("$MVN" package -o -nsu'

            scala_version=$(echo ${scala-pkg.version} | awk -F. '{print $1"."$2}')
            echo "Buiding project..."
            ./dev/make-distribution.sh \
                -Puser-defined-protoc \
                -DskipDefaultProtoc \
                -Dprotobuf.version=3.${protobuf-pkg.version} \
                -DsecondaryCacheDir=$sbtDeps/sbt-cache \
                -Dmaven.repo.local=$mvnDeps/.m2 \
                -Pscala-$scala_version \
                ${mvnExtraArgs}
          '';
        };
      in
      {
        packages = {
          inherit spark;
          default = spark;
        };
      }
    );
}
