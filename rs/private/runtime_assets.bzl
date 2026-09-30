"""Runtime files for Cargo helpers whose Rust APIs return vendored asset paths."""

load("@bazel_lib//lib:copy_to_directory.bzl", "copy_to_directory")

_PROTOC_PLATFORMS = [
    "linux-aarch_64",
    "linux-ppcle_64",
    "linux-s390_64",
    "linux-x86_32",
    "linux-x86_64",
    "macos-aarch_64",
    "macos-x86_64",
    "win32",
]

def runtime_asset_patterns(package_name):
    """Return the supported package's asset inventory, not its Rust sources."""
    if package_name in ["protoc-bin-vendored-" + platform for platform in _PROTOC_PLATFORMS]:
        return ["bin/**", "include/**"]
    return []

def crate_runtime_assets(name, data, rustc_env):
    """Stage supported assets and return augmented library attributes.

    Cargo still selects the crate version and execution-host protoc. The
    helpers embed their manifest directory in Rust code, so compiler sandbox
    paths are not valid. Build scripts execute in <runfiles>/m, alongside
    external repositories. rlocationpath supplies the actual repository name.
    Explicit annotation environment settings take precedence over defaults.
    """
    patterns = runtime_asset_patterns(name)
    if not patterns:
        return data, rustc_env

    target = name + "__runtime_assets"
    copy_to_directory(
        name = target,
        srcs = native.glob(patterns, allow_empty = False),
        root_paths = ["."],
    )
    return data + [":" + target], {
        "CARGO_MANIFEST_DIR": "../$(rlocationpath :%s)" % target,
    } | rustc_env
