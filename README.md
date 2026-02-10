# Apache Spark Nix Flake

This repository provides a Nix flake for building Apache Spark from source, offering a reproducible and customizable build process.

## Motivation

The official Apache Spark package available in `nixpkgs` primarily downloads and wraps a pre-built binary distribution. This approach is convenient but offers limited flexibility. For instance, you are constrained to the specific versions of components like Scala, Hadoop, and others that the pre-built distribution was compiled with.

The primary goal of this project is to provide a fully reproducible, Nix-based build of Apache Spark directly from source. This allows for greater customization, such as:

*   Building Spark against a specific version of Scala.
*   Enabling or disabling various build profiles (e.g., for Kubernetes, Hive, etc.).
*   Having a transparent and auditable build process managed entirely by Nix.

## Build Process and Caveats

The Apache Spark build process is intricate, relying on a multitude of external tools and dependencies downloaded at build time by Maven and SBT. To make this process compatible with Nix's principles of reproducibility and sandboxing, this flake employs a two-stage approach.

### Stage 1: Dependency Fetching

First, we build a fixed-output derivation (`external-deps`) that captures all the dependencies required for the final build. This process involves:

1.  **Patching Build Scripts:** The original build scripts (`build/mvn`, `dev/change-scala-version.sh`, etc.) are patched to prevent them from downloading their own tools (like `mvn` or `sbt`) and instead use the versions provided by `nixpkgs`.
2.  **Fetching Dependencies:** We execute a full Maven build (`package`) within this derivation. This triggers Maven and SBT to download all necessary Java/Scala libraries and the SBT compiler bridge.
3.  **Hashing:** The entire output, including the populated Maven (`.m2`) and SBT (`sbt-cache`) caches, is hashed to create a fixed-output derivation.

This approach is conceptually similar to how other Nix tooling handles language-specific package management (e.g., `buildGoModule`, `buildRustCrate`, `buildMavenPackage`) by separating dependency fetching from the actual build.

### Stage 2: Final Offline Build

With all dependencies captured, the final `spark` derivation performs an offline build:

1.  The pre-populated `.m2` and `sbt-cache` directories from the `external-deps` derivation are made available.
2.  The build is invoked with flags that force Maven to run in offline mode (`-o`).
3.  This ensures that the final build is fast, reproducible, and does not require network access.

## Future Development

This flake is currently a proof of concept and has some limitations. The following are key areas for future improvement:

*   **Parameterization:** The versions for Spark, the JDK, protobuf, and the selected Maven profiles are currently hardcoded in `flake.nix`. The next logical step is to make these configurable via flake inputs or function arguments.
*   **Optimization:** There is a possibility of fetching all dependencies without a full compilation; using mvn package is overkill.
*   **Broader Testing:** The current configuration has been tested only as-is (`sparkVersion = "4.1.1"`, Scala 2.13, `-Pkubernetes`). Broader testing with different profiles is needed.
*   **Upstreaming:** The ultimate goal could be to refine this work and contribute it back to `nixpkgs` as a more flexible alternative to the existing Spark package.

## Usage

### Build Spark

To build the default Apache Spark package defined in the flake:

```sh
nix build
```

The resulting distribution will be available in the `result/` directory.

## Current Defaults

*   Spark: 4.1.1
*   Scala: 2.13 (only supported upstream for Spark 4.x)
*   JDK: 17
*   gRPC: 1.76.0 (matches upstream `pom.xml`)

Note: `flake.nix` uses fixed-output derivations, so updating Spark versions requires refreshing the source hash, the gRPC plugin hash, and the external-deps hash.
