load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":runtime_assets.bzl", "crate_runtime_assets", "runtime_asset_patterns")

def _protoc_helpers_impl(ctx):
    env = unittest.begin(ctx)
    for platform in [
        "linux-aarch_64",
        "linux-ppcle_64",
        "linux-s390_64",
        "linux-x86_32",
        "linux-x86_64",
        "macos-aarch_64",
        "macos-x86_64",
        "win32",
    ]:
        asserts.equals(env, ["bin/**", "include/**"], runtime_asset_patterns("protoc-bin-vendored-" + platform))
    return unittest.end(env)

def _unrelated_crates_impl(ctx):
    env = unittest.begin(ctx)
    for name in ["protoc-bin-vendored", "prost-build", "hiroz-codegen", "protoc-bin-vendored-unrecognized"]:
        asserts.equals(env, [], runtime_asset_patterns(name))
        data = [":existing_data"]
        rustc_env = {"CARGO_MANIFEST_DIR": "explicit", "OTHER": "value"}
        asserts.equals(env, (data, rustc_env), crate_runtime_assets(name, data, rustc_env))
    return unittest.end(env)

_protoc_helpers_test = unittest.make(_protoc_helpers_impl)
_unrelated_crates_test = unittest.make(_unrelated_crates_impl)

def runtime_assets_tests():
    unittest.suite(
        "runtime_assets_tests",
        _protoc_helpers_test,
        _unrelated_crates_test,
    )
