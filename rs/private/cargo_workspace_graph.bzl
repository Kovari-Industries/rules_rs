load("@bazel_skylib//lib:paths.bzl", "paths")
load("//rs/private:cargo_package_identity.bzl", "lock_source", "package_fq")
load("//rs/private:cfg_parser.bzl", "cfg_matches_expr_for_cfg_attrs", "triple_to_cfg_attrs")
load("//rs/private:resolver.bzl", "resolve")
load("//rs/private:select_utils.bzl", "compute_select")
load("//rs/private:semver.bzl", "select_matching_version")

def platform_label(triple, use_legacy_rules_rust_platforms):
    if use_legacy_rules_rust_platforms:
        return "@rules_rust//rust/platform:" + triple.replace("-musl", "-gnu").replace("-gnullvm", "-msvc")
    return "@rules_rs//rs/platforms/config:" + triple

def fq_crate(name, version):
    return name + "-" + version

def normalize_path(path):
    return str(path).replace("\\", "/")

def manifest_package_dir(manifest_path, repo_root):
    package_dir = normalize_path(manifest_path).removeprefix(repo_root + "/")
    if package_dir == "Cargo.toml":
        return ""

    return package_dir.removesuffix("/Cargo.toml")

def add_to_dict(d, k, v):
    existing = d.get(k, [])
    if not existing:
        d[k] = existing
    existing.append(v)

def exclude_deps_from_features(features):
    return [f for f in features if not f.startswith("dep:")]

def shared_and_per_platform(platform_items, use_legacy_rules_rust_platforms):
    if not platform_items:
        return [], {}

    by_platform = {}
    for triple, items in platform_items.items():
        platform = platform_label(triple, use_legacy_rules_rust_platforms)
        existing = by_platform.get(platform)
        if existing == None:
            by_platform[platform] = set(items)
        else:
            existing.update(items)

    items, per_platform = compute_select([], by_platform)
    return sorted(items), per_platform

def select_items(items):
    return {k: sorted(v) for k, v in items.items()}

def render_string_list(items):
    return ",\n            ".join(['"%s"' % item for item in sorted(items)])

def cfg_match_info_for_target(target, platform_cfg_attrs, cfg_match_cache):
    match_info = cfg_match_cache.get(target)
    if match_info:
        return match_info

    match_info = cfg_matches_expr_for_cfg_attrs(target, platform_cfg_attrs)
    cfg_match_cache[target] = match_info
    return match_info

def new_feature_resolutions(package_index, possible_deps, possible_features, platform_triples):
    return struct(
        features_enabled = {triple: set() for triple in platform_triples},
        build_deps = {triple: set() for triple in platform_triples},
        deps = {triple: set() for triple in platform_triples},
        aliases = {},
        package_index = package_index,
        possible_deps = possible_deps,
        possible_features = possible_features,
    )

_INTERNAL_RUSTC_PLACEHOLDER_CRATES = [
    "rustc-std-workspace-alloc",
    "rustc-std-workspace-core",
    "rustc-std-workspace-std",
]

def _is_internal_rustc_placeholder(crate_name):
    return crate_name in _INTERNAL_RUSTC_PLACEHOLDER_CRATES

def cargo_metadata_dep_to_dep_dict(dep):
    rename = dep.get("rename")
    converted = {
        "name": rename or dep["name"],
        "optional": dep.get("optional", False),
        "default_features": dep.get("uses_default_features", True),
        "features": list(dep.get("features", [])),
    }

    for field in ["source", "path"]:
        if field in dep:
            converted[field] = dep[field]

    req = dep.get("req")
    if req:
        converted["req"] = req

    kind = dep.get("kind")
    if kind and kind != "normal":
        converted["kind"] = kind

    target = dep.get("target")
    if target:
        converted["target"] = target

    if rename:
        converted["package"] = dep["name"]

    return converted

def _cargo_toml_dep_to_dep_dict_inner(dep, spec, is_build = False, target = None):
    if type(spec) == "string":
        converted = {
            "name": dep,
            "req": spec,
        }
    else:
        converted = {
            "name": dep,
            "optional": spec.get("optional", False),
            "default_features": spec.get("default_features", spec.get("default-features", True)),
            "features": spec.get("features", []),
        }
        for field in ["path", "git", "branch", "tag", "rev", "registry"]:
            if field in spec:
                converted[field] = spec[field]
        if "package" in spec:
            converted["package"] = spec["package"]
        if spec.get("version"):
            converted["req"] = spec["version"]

    if is_build:
        converted["kind"] = "build"

    if target:
        converted["target"] = target

    return converted

def cargo_toml_dep_to_dep_dict(dep, spec, package_name, workspace_cargo_toml_json = None, is_build = False, target = None):
    if type(spec) == "dict" and spec.get("workspace") == True:
        workspace = (workspace_cargo_toml_json or {}).get("workspace")
        if not workspace:
            fail("Package %s depends on %s with workspace inheritance, but no workspace section was found" % (package_name, dep))
        if dep not in workspace.get("dependencies", {}):
            fail("Package %s depends on %s with workspace inheritance, but it was not found in workspace.dependencies" % (package_name, dep))

        inherited = _cargo_toml_dep_to_dep_dict_inner(dep, workspace["dependencies"][dep], is_build = is_build, target = target)

        extra_features = spec.get("features")
        if extra_features:
            inherited["features"] = sorted(set(extra_features + inherited.get("features", [])))

        if spec.get("optional"):
            inherited["optional"] = True

        if spec.get("package"):
            inherited["package"] = spec["package"]

        return inherited

    return _cargo_toml_dep_to_dep_dict_inner(dep, spec, is_build = is_build, target = target)

def cargo_toml_dependencies(cargo_toml_json, workspace_cargo_toml_json = None):
    package_name = cargo_toml_json["package"]["name"]
    dependencies = [
        cargo_toml_dep_to_dep_dict(dep, spec, package_name, workspace_cargo_toml_json)
        for dep, spec in cargo_toml_json.get("dependencies", {}).items()
    ] + [
        cargo_toml_dep_to_dep_dict(dep, spec, package_name, workspace_cargo_toml_json, is_build = True)
        for dep, spec in cargo_toml_json.get("build-dependencies", {}).items()
    ]

    for target, value in cargo_toml_json.get("target", {}).items():
        for dep, spec in value.get("dependencies", {}).items():
            dependencies.append(cargo_toml_dep_to_dep_dict(
                dep,
                spec,
                package_name,
                workspace_cargo_toml_json,
                target = target,
            ))

    return dependencies

def cargo_toml_fact(cargo_toml_json, workspace_cargo_toml_json = None, strip_prefix = ""):
    return dict(
        features = cargo_toml_json.get("features", {}),
        dependencies = cargo_toml_dependencies(cargo_toml_json, workspace_cargo_toml_json),
        strip_prefix = strip_prefix,
    )

def prepare_possible_deps(dependencies, converter = None, skip_internal_rustc_placeholder_crates = True):
    possible_deps = []

    for dep in dependencies:
        if converter:
            dep = converter(dep)
        else:
            dep = dict(dep)

        if dep.get("kind") == "dev":
            continue

        dep_package = dep.get("package") or dep["name"]
        if skip_internal_rustc_placeholder_crates and _is_internal_rustc_placeholder(dep_package):
            continue

        if dep.get("default_features", True):
            add_to_dict(dep, "features", "default")

        possible_deps.append(dep)

    return possible_deps

def _dep_package_name(dep):
    return dep.get("package") or dep["name"]

def _packages_by_name(packages):
    result = {}
    for package in packages:
        add_to_dict(result, package["name"], package)
    return result

def compute_package_fq_deps(package, versions_by_name, strict = True, packages_by_fq = None, packages_by_name = None):
    """Resolve Cargo's name [version [(source)]] lockfile references exactly."""
    possible_dep_fq_crates_by_name = {}
    for reference in package.get("dependencies", []):
        parts = reference.split(" ", 2)
        name = parts[0]
        version = parts[1] if len(parts) > 1 else None
        source = parts[2][1:-1] if len(parts) > 2 else None
        if packages_by_fq != None:
            candidates = [
                p
                for p in (packages_by_name.get(name, []) if packages_by_name != None else packages_by_fq.values())
                if p["name"] == name and (version == None or p["version"] == version)
            ]
            if source != None:
                candidates = [p for p in candidates if lock_source(p) == source]
            elif version != None:
                # Cargo omits the source for a local package even when another
                # package has the same name/version and an explicit source.
                local = [p for p in candidates if not lock_source(p)]
                if local:
                    candidates = local
            if len(candidates) != 1:
                if not candidates and not strict:
                    continue
                fail("Cargo.lock dependency %r is %s" % (reference, "ambiguous" if candidates else "missing"))
            fq = package_fq(candidates[0])
        else:
            versions = [version] if version else versions_by_name.get(name, [])
            if len(versions) != 1:
                if not versions and not strict:
                    continue
                fail("Cargo.lock dependency %r is ambiguous or missing" % reference)
            if source != None:
                fail("Source-qualified Cargo.lock dependency requires a package identity index: %s" % reference)
            fq = fq_crate(name, versions[0])
        add_to_dict(possible_dep_fq_crates_by_name, name, fq)
    return possible_dep_fq_crates_by_name

def select_package_fq_dep(dep, fq_deps, packages_by_fq = None, owner = None):
    dep_package = _dep_package_name(dep)
    candidates = fq_deps.get(dep_package, [])
    if not candidates:
        return None
    if len(candidates) == 1:
        return candidates[0]

    if packages_by_fq != None:
        source = dep.get("source")
        if dep.get("path"):
            source = lock_source(owner) if owner and lock_source(owner).startswith("git+") else ""
        elif dep.get("git"):
            source = "git+" + dep["git"]
            for selector in ["branch", "tag", "rev"]:
                if dep.get(selector):
                    source += "?" + selector + "=" + dep[selector]
        elif source == None:
            registry = dep.get("registry")
            if not registry:
                source = "registry+https://github.com/rust-lang/crates.io-index"
            elif "://" in registry:
                source = "registry+" + registry
            elif len({lock_source(packages_by_fq[candidate]): True for candidate in candidates}) > 1:
                fail("Cannot resolve named registry %r for dependency %s with multiple Cargo sources" % (registry, dep_package))
        if source != None:
            matching = [
                candidate
                for candidate in candidates
                if lock_source(packages_by_fq[candidate]) == source or
                   (source.startswith("git+") and lock_source(packages_by_fq[candidate]).split("#")[0] == source)
            ]

            # Cargo patches may replace a registry/git dependency with another
            # source. Prefer an exact source when available; otherwise let the
            # lockfile's version constraints resolve patches, never first-match.
            if matching or dep.get("path"):
                candidates = matching

    req = dep.get("req")
    if req and len(candidates) > 1:
        versions = {
            candidate: packages_by_fq[candidate]["version"] if packages_by_fq != None else candidate[len(dep_package) + 1:]
            for candidate in candidates
        }
        version = select_matching_version(req, versions.values())
        candidates = [candidate for candidate in candidates if versions[candidate] == version]
    if len(candidates) > 1:
        fail("Ambiguous Cargo dependency %s: %s" % (dep_package, candidates))
    return candidates[0] if candidates else None

def compute_workspace_fq_deps(workspace_members, versions_by_name, packages_by_fq = None):
    packages_by_name = _packages_by_name(packages_by_fq.values()) if packages_by_fq != None else None
    return {
        package["name"]: compute_package_fq_deps(package, versions_by_name, strict = False, packages_by_fq = packages_by_fq, packages_by_name = packages_by_name)
        for package in workspace_members
    }

def _relative_to_workspace(path, workspace_root):
    normalized_root = normalize_path(workspace_root)
    normalized_path = normalize_path(path)

    if not paths.is_absolute(normalized_path):
        normalized_path = normalize_path(paths.normalize(paths.join(normalized_root, normalized_path)))

    root_parts = [p for p in normalized_root.split("/") if p]
    path_parts = [p for p in normalized_path.split("/") if p]

    common = 0
    max_common = min(len(root_parts), len(path_parts))
    for idx in range(max_common):
        if root_parts[idx] != path_parts[idx]:
            break
        common = idx + 1

    rel_parts = [".."] * (len(root_parts) - common) + path_parts[common:]
    return "/".join(rel_parts) if rel_parts else "."

def _cargo_metadata_dep_paths_by_name(packages, workspace_root):
    package_dirs = {}

    for package in packages:
        for dep in package.get("dependencies", []):
            dep_path = dep.get("path")
            if not dep_path:
                continue

            package_dirs[dep["name"]] = _relative_to_workspace(dep_path, workspace_root)

    return package_dirs

def _cargo_toml_patch_paths_by_name(workspace_cargo_toml, workspace_root, workspace_package_dir = ""):
    workspace_root = normalize_path(workspace_root)
    workspace_root_prefix = workspace_root + "/"
    package_dirs = {}

    for patches in workspace_cargo_toml.get("patch", {}).values():
        for name, spec in patches.items():
            if type(spec) != "dict":
                continue

            patch_path = spec.get("path")
            if not patch_path:
                continue

            package = spec.get("package") or name
            if paths.is_absolute(patch_path):
                normalized = normalize_path(patch_path)
                if not normalized.startswith(workspace_root_prefix):
                    fail("Patch path for %s points outside the workspace: %s" % (name, patch_path))
                package_dirs[package] = normalized.removeprefix(workspace_root_prefix)
            else:
                package_dirs[package] = normalize_path(paths.normalize(paths.join(workspace_package_dir, patch_path)))

    return package_dirs

def workspace_metadata_packages(cargo_metadata):
    members = cargo_metadata.get("workspace_members")
    if members == None:
        return cargo_metadata["packages"]
    return [p for p in cargo_metadata["packages"] if p["id"] in members]

def discover_local_packages(cargo_metadata, workspace_cargo_toml, all_packages, read_metadata):
    """Follow locked local dependencies, including separate nested workspaces.

    Cargo supplies membership and expands workspace inheritance. Do not infer
    either from whether a manifest is below the root workspace directory.
    """
    required = {(p["name"], p["version"]): True for p in all_packages if not lock_source(p)}
    required_names = {name: True for name, _ in required}
    available = {}
    discovered = {}
    pending = []
    visited = {}
    root = normalize_path(cargo_metadata["workspace_root"])
    for package in workspace_metadata_packages(cargo_metadata):
        manifest = normalize_path(package["manifest_path"])
        available[manifest] = (package, paths.join(root, "Cargo.toml"))
        pending.append(manifest)
    for path in _cargo_toml_patch_paths_by_name(workspace_cargo_toml, root).values():
        pending.append(paths.join(root, path, "Cargo.toml"))

    # Each iteration discovers at least one locked local package. The bound
    # also permits a final empty iteration without unbounded Starlark loops.
    for _ in range(len(required) + 1):
        if not pending:
            return discovered
        current = pending
        pending = []
        for manifest in current:
            manifest = normalize_path(paths.normalize(manifest))
            if manifest in visited:
                continue
            visited[manifest] = True
            if manifest not in available:
                metadata = read_metadata(manifest)
                workspace_manifest = paths.join(normalize_path(metadata["workspace_root"]), "Cargo.toml")
                for package in metadata["packages"]:
                    available[normalize_path(package["manifest_path"])] = (package, workspace_manifest)
            if manifest not in available:
                fail("Cargo metadata did not include local manifest %s" % manifest)
            package, workspace_manifest = available[manifest]
            key = (package["name"], package["version"])
            if key not in required:
                continue
            if key in discovered and discovered[key]["manifest_path"] != manifest:
                fail("Ambiguous local Cargo package %s: %s and %s" % (key, discovered[key]["manifest_path"], manifest))
            package = dict(package)
            package["workspace_manifest"] = workspace_manifest
            discovered[key] = package
            for dep in package.get("dependencies", []):
                if dep.get("path") and dep["name"] in required_names:
                    pending.append(paths.join(dep["path"], "Cargo.toml"))
    fail("Local Cargo dependency discovery did not converge")

def split_lockfile_packages(hub_name, cargo_metadata, workspace_cargo_toml, all_packages, repo_root = None, workspace_package_dir = "", local_packages = None):
    if repo_root == None:
        repo_root = cargo_metadata["workspace_root"]
    repo_root = normalize_path(repo_root)

    workspace_member_keys = {}
    for package in workspace_metadata_packages(cargo_metadata):
        workspace_member_keys[(package["name"], package["version"])] = True

    dep_paths_by_name = _cargo_metadata_dep_paths_by_name(cargo_metadata["packages"], repo_root)
    patch_paths_by_name = _cargo_toml_patch_paths_by_name(workspace_cargo_toml, repo_root, workspace_package_dir)
    workspace_members = []
    packages = []

    for package in all_packages:
        pkg = dict(package)

        if lock_source(pkg):
            packages.append(pkg)
            continue

        key = (pkg["name"], pkg["version"])
        if key in workspace_member_keys:
            workspace_members.append(pkg)
            continue

        metadata = (local_packages or {}).get(key)
        if metadata:
            rel_path = _relative_to_workspace(paths.dirname(metadata["manifest_path"]), repo_root)
            pkg["local_metadata"] = metadata
            pkg["workspace_manifest"] = metadata["workspace_manifest"]
        else:
            rel_path = patch_paths_by_name.get(pkg["name"]) or dep_paths_by_name.get(pkg["name"])
        local_path = rel_path
        if rel_path and not rel_path.startswith("/"):
            local_path = paths.join(repo_root, rel_path)

        if not local_path:
            fail("Found a path dependency on %s %s but could not determine its path from Cargo.toml. Please declare it in [patch] or as a path dependency." % (pkg["name"], pkg["version"]))

        pkg["lock_source"] = ""
        pkg["source"] = "path+" + hub_name + "/" + rel_path
        pkg["local_path"] = local_path
        packages.append(pkg)

    return struct(
        packages = packages,
        workspace_members = workspace_members,
    )

def _resolve_packages(packages, package_info_by_fq_crate, platform_triples, dep_converter = None, skip_internal_rustc_placeholder_crates = True):
    feature_resolutions_by_fq_crate = {}
    versions_by_name = {}

    for package_index in range(len(packages)):
        package = packages[package_index]
        name = package["name"]
        version = package["version"]
        fq = package_fq(package)

        if version not in versions_by_name.get(name, []):
            add_to_dict(versions_by_name, name, version)

        package_info = package_info_by_fq_crate[fq]
        possible_deps = prepare_possible_deps(
            package_info.get("dependencies", []),
            converter = dep_converter,
            skip_internal_rustc_placeholder_crates = skip_internal_rustc_placeholder_crates,
        )
        feature_resolutions = new_feature_resolutions(package_index, possible_deps, package_info.get("features", {}), platform_triples)
        package["feature_resolutions"] = feature_resolutions
        feature_resolutions_by_fq_crate[fq] = feature_resolutions

    return struct(
        feature_resolutions_by_fq_crate = feature_resolutions_by_fq_crate,
        versions_by_name = versions_by_name,
    )

def resolve_package_facts(packages, facts_by_fq_crate, platform_triples, skip_internal_rustc_placeholder_crates = True):
    return _resolve_packages(
        packages,
        facts_by_fq_crate,
        platform_triples,
        skip_internal_rustc_placeholder_crates = skip_internal_rustc_placeholder_crates,
    )

def resolve_cargo_metadata_packages(packages, cargo_metadata, platform_triples, skip_internal_rustc_placeholder_crates = True):
    metadata_by_fq_crate = {
        package_fq(package): package
        for package in cargo_metadata["packages"]
    }

    return _resolve_packages(
        packages,
        metadata_by_fq_crate,
        platform_triples,
        dep_converter = cargo_metadata_dep_to_dep_dict,
        skip_internal_rustc_placeholder_crates = skip_internal_rustc_placeholder_crates,
    )

def _resolve_possible_deps(
        packages,
        resolver_versions_by_name,
        feature_resolutions_by_fq_crate,
        platform_triples,
        platform_cfg_attrs,
        cfg_match_cache,
        dep_label_prefix):
    packages_by_fq = {package_fq(p): p for p in packages}
    packages_by_name = _packages_by_name(packages)
    for package in packages:
        name = package["name"]
        fq_deps = compute_package_fq_deps(package, resolver_versions_by_name, packages_by_fq = packages_by_fq, packages_by_name = packages_by_name)
        for dep in package["feature_resolutions"].possible_deps:
            dep_fq = select_package_fq_dep(dep, fq_deps, packages_by_fq, owner = package)
            if not dep_fq:
                continue

            if dep_fq not in feature_resolutions_by_fq_crate:
                fail("Resolved %s dependency %s but no crate metadata was available" % (name, dep_fq))
            dep["bazel_target"] = "%s%s" % (dep_label_prefix, dep_fq)
            dep["feature_resolutions"] = feature_resolutions_by_fq_crate[dep_fq]

            target = dep.get("target")
            match_info = cfg_match_info_for_target(target, platform_cfg_attrs, cfg_match_cache)
            if match_info.uses_feature_cfg:
                dep["target_expr"] = target
                dep["feature_sensitive"] = True
                dep["target"] = set(platform_triples)
            else:
                dep["target"] = set(match_info.matches)

def resolve_cargo_workspace_members(
        ctx,
        *,
        cargo_metadata,
        packages,
        workspace_members,
        versions_by_name,
        feature_resolutions_by_fq_crate,
        annotations,
        platform_triples,
        materialize_workspace_members,
        validate_lockfile = True,
        debug = False,
        dep_label_prefix = "//:",
        skip_internal_rustc_placeholder_crates = True,
        watch_manifests = False,
        use_legacy_rules_rust_platforms = False):
    platform_cfg_attrs = [triple_to_cfg_attrs(triple) for triple in platform_triples]
    platform_cfg_attrs_by_triple = {}
    for cfg_attr in platform_cfg_attrs:
        platform_cfg_attrs_by_triple[cfg_attr["_triple"]] = cfg_attr

    cfg_match_cache = {None: struct(matches = platform_triples, uses_feature_cfg = False)}

    workspace_member_keys = {}
    for package in workspace_metadata_packages(cargo_metadata):
        workspace_member_keys[(package["name"], package["version"])] = True

    resolver_versions_by_name = {name: versions[:] for name, versions in versions_by_name.items()}
    workspace_members_by_key = {(package["name"], package["version"]): package for package in workspace_members}
    resolver_packages = packages[:]
    for package in workspace_metadata_packages(cargo_metadata):
        name = package["name"]
        version = package["version"]

        versions = resolver_versions_by_name.get(name, [])
        if version not in versions:
            if versions:
                versions.append(version)
            else:
                resolver_versions_by_name[name] = [version]

        possible_features = package.get("features", {})
        possible_deps = prepare_possible_deps(
            package.get("dependencies", []),
            converter = cargo_metadata_dep_to_dep_dict,
            skip_internal_rustc_placeholder_crates = skip_internal_rustc_placeholder_crates,
        )

        package_index = len(resolver_packages)
        lockfile_pkg = workspace_members_by_key.get((name, version), {})
        resolver_package = dict(lockfile_pkg)
        resolver_package.update(name = name, version = version)
        package["fq"] = package_fq(resolver_package)

        feature_resolutions = new_feature_resolutions(package_index, possible_deps, possible_features, platform_triples)
        resolver_package["feature_resolutions"] = feature_resolutions
        feature_resolutions_by_fq_crate[package_fq(package)] = feature_resolutions

        resolver_packages.append(resolver_package)

    _resolve_possible_deps(
        resolver_packages,
        resolver_versions_by_name,
        feature_resolutions_by_fq_crate,
        platform_triples,
        platform_cfg_attrs,
        cfg_match_cache,
        dep_label_prefix,
    )

    packages_by_fq = {package_fq(p): p for p in resolver_packages}
    workspace_fq_deps = compute_workspace_fq_deps(workspace_members, resolver_versions_by_name, packages_by_fq)
    workspace_dep_versions_by_name = {}
    workspace_dep_labels_by_triple = {triple: set() for triple in platform_triples}

    for package in workspace_metadata_packages(cargo_metadata):
        if watch_manifests:
            ctx.watch(package["manifest_path"])

        package_feature_resolutions = feature_resolutions_by_fq_crate[package_fq(package)]
        if "default" in package.get("features", {}):
            for triple in platform_triples:
                package_feature_resolutions.features_enabled[triple].add("default")

        fq_deps = workspace_fq_deps.get(package["name"], {})

        for dep in package["dependencies"]:
            source = dep.get("source")
            dep_name = dep["name"]
            dep_package = _dep_package_name(dep)
            dep_fq = select_package_fq_dep(dep, fq_deps, packages_by_fq)
            dep_version = None
            if dep_fq:
                dep_version = packages_by_fq[dep_fq]["version"]
            is_first_party_dep = not source and dep_version and (dep_package, dep_version) in workspace_member_keys

            if validate_lockfile and source and source.startswith("registry+"):
                req = dep["req"]
                fq = dep_fq
                if req and fq:
                    locked_version = packages_by_fq[fq]["version"]
                    if not select_matching_version(req, [locked_version]):
                        fail(("ERROR: Cargo.lock out of sync: %s requires %s %s but Cargo.lock has %s.\n\n" +
                              "If this is incorrect, please set `validate_lockfile = False` in `crate.from_cargo`\n" +
                              "and file a bug at https://github.com/hermeticbuild/rules_rs/issues/new") % (
                            package["name"],
                            dep_package,
                            req,
                            locked_version,
                        ))

            features = list(dep.get("features", []))
            if dep.get("uses_default_features"):
                features.append("default")

            if not dep_fq:
                continue

            if dep_fq not in feature_resolutions_by_fq_crate:
                fail("Resolved %s dependency %s but no crate metadata was available" % (package["name"], dep_fq))

            if not is_first_party_dep or materialize_workspace_members:
                dep["bazel_target"] = "%s%s" % (dep_label_prefix, dep_fq)

            feature_resolutions = feature_resolutions_by_fq_crate[dep_fq]

            if not is_first_party_dep or materialize_workspace_members:
                versions = workspace_dep_versions_by_name.get(dep_name)
                if not versions:
                    versions = set()
                    workspace_dep_versions_by_name[dep_name] = versions
                versions.add(dep_fq)

            target = dep.get("target")
            match_info = cfg_match_info_for_target(target, platform_cfg_attrs, cfg_match_cache)

            for triple in match_info.matches:
                if not is_first_party_dep or materialize_workspace_members:
                    workspace_dep_labels_by_triple[triple].add(":" + dep_fq)
                feature_resolutions.features_enabled[triple].update(features)

    for crate, annotation_versions in annotations.items():
        for version_key, annotation in annotation_versions.items():
            target_versions = resolver_versions_by_name.get(crate, [])
            if version_key != "*":
                if version_key not in target_versions:
                    continue
                target_versions = [version_key]
            if not annotation.crate_features and not annotation.crate_features_select:
                continue
            for package in resolver_packages:
                if package["name"] != crate or package["version"] not in target_versions:
                    continue
                features_enabled = feature_resolutions_by_fq_crate[package_fq(package)].features_enabled
                if annotation.crate_features:
                    for triple in platform_triples:
                        features_enabled[triple].update(annotation.crate_features)
                for triple, features in annotation.crate_features_select.items():
                    if triple in features_enabled:
                        features_enabled[triple].update(features)

    resolve(ctx, resolver_packages, feature_resolutions_by_fq_crate, platform_cfg_attrs_by_triple, debug)

    for package in packages:
        feature_resolutions = package["feature_resolutions"]
        features_enabled = feature_resolutions.features_enabled

        for dep in feature_resolutions.possible_deps:
            if "bazel_target" in dep:
                continue

            prefixed_dep_alias = "dep:" + dep["name"]

            for triple in platform_triples:
                if prefixed_dep_alias in features_enabled[triple]:
                    fail("Crate %s has enabled %s but it was not in the lockfile..." % (package["name"], prefixed_dep_alias))

    return struct(
        cfg_match_cache = cfg_match_cache,
        feature_resolutions_by_fq_crate = feature_resolutions_by_fq_crate,
        platform_cfg_attrs = platform_cfg_attrs,
        platform_cfg_attrs_by_triple = platform_cfg_attrs_by_triple,
        resolver_versions_by_name = resolver_versions_by_name,
        workspace_dep_labels_by_triple = workspace_dep_labels_by_triple,
        workspace_dep_versions_by_name = workspace_dep_versions_by_name,
        workspace_fq_deps = workspace_fq_deps,
        workspace_member_keys = workspace_member_keys,
    )

def workspace_dep_data(
        *,
        cargo_metadata,
        feature_resolutions_by_fq_crate,
        platform_triples,
        platform_cfg_attrs,
        cfg_match_cache,
        repo_root,
        workspace_package,
        use_legacy_rules_rust_platforms,
        lint_configs = {}):
    dep_data = {}
    for package in workspace_metadata_packages(cargo_metadata):
        aliases = {}
        crate_features = {triple: set() for triple in platform_triples}
        deps = {triple: set() for triple in platform_triples}
        build_deps = {triple: set() for triple in platform_triples}
        dev_deps = {triple: set() for triple in platform_triples}
        package_dir = manifest_package_dir(package["manifest_path"], repo_root)
        package_manifest_dir = normalize_path(package["manifest_path"]).removesuffix("/Cargo.toml")
        binaries = {}
        shared_libraries = {}
        feature_resolutions = feature_resolutions_by_fq_crate.get(package_fq(package))

        for target in package.get("targets", []):
            kinds = target.get("kind", [])
            if "cdylib" not in kinds and "bin" not in kinds:
                continue

            src_path = target.get("src_path")
            if not src_path:
                continue

            entrypoint = normalize_path(src_path).removeprefix(repo_root + "/")
            if package_dir and entrypoint.startswith(package_dir + "/"):
                entrypoint = entrypoint.removeprefix(package_dir + "/")

            if "cdylib" in kinds:
                shared_libraries[target["name"]] = entrypoint
            elif "bin" in kinds:
                binaries[target["name"]] = entrypoint

        for dep in package["dependencies"]:
            bazel_target = dep.get("bazel_target")
            dep_path = dep.get("path")
            if not bazel_target:
                if not dep_path:
                    continue
                bazel_target = "//" + paths.join(workspace_package, normalize_path(dep_path).removeprefix(repo_root + "/"))

            is_self_dep = dep_path and normalize_path(dep_path) == package_manifest_dir

            if not is_self_dep:
                if dep.get("rename"):
                    aliases[bazel_target] = dep["rename"].replace("-", "_")
                elif dep_path:
                    aliases[bazel_target] = dep["name"].replace("-", "_")

            target = dep.get("target")
            match_info = cfg_match_info_for_target(target, platform_cfg_attrs, cfg_match_cache)
            match = match_info.matches

            kind = dep["kind"]
            if kind == "dev":
                target_deps = dev_deps
            elif kind == "build":
                target_deps = build_deps
            else:
                target_deps = deps

            for triple in match:
                if dep.get("optional") and feature_resolutions:
                    dep_name = dep.get("rename") or dep["name"]
                    triple_features = feature_resolutions.features_enabled[triple]
                    if dep_name not in triple_features and ("dep:" + dep_name) not in triple_features:
                        continue

                if is_self_dep:
                    continue

                target_deps[triple].add(bazel_target)

        if feature_resolutions:
            for triple in platform_triples:
                crate_features[triple].update(exclude_deps_from_features(feature_resolutions.features_enabled[triple]))

        bazel_package = paths.join(workspace_package, package_dir) if package_dir else workspace_package

        crate_features, crate_features_by_platform = shared_and_per_platform(crate_features, use_legacy_rules_rust_platforms)
        deps, deps_by_platform = shared_and_per_platform(deps, use_legacy_rules_rust_platforms)
        build_deps, build_deps_by_platform = shared_and_per_platform(build_deps, use_legacy_rules_rust_platforms)
        dev_deps, dev_deps_by_platform = shared_and_per_platform(dev_deps, use_legacy_rules_rust_platforms)

        package_dep_data = {
            "aliases": aliases,
            "binaries": binaries,
            "build_deps": build_deps,
            "build_deps_by_platform": build_deps_by_platform,
            "crate_features": crate_features,
            "crate_features_by_platform": crate_features_by_platform,
            "crate_name": package["name"].replace("-", "_"),
            "deps": deps,
            "deps_by_platform": deps_by_platform,
            "dev_deps": dev_deps,
            "dev_deps_by_platform": dev_deps_by_platform,
            "edition": package.get("edition", "2015"),
            "shared_libraries": shared_libraries,
        }
        lint_config = lint_configs.get(bazel_package)
        if lint_config:
            package_dep_data["lint_config"] = lint_config
        dep_data[bazel_package] = package_dep_data

    return dep_data

def render_dep_data(dep_data):
    return "DEP_DATA = {\n%s\n}\n\n" % "\n".join([
        "    %s: %s," % (repr(package), repr(dep_data[package]))
        for package in sorted(dep_data.keys())
    ])
