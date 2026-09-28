"""Cargo lock identities and their source-safe Bazel names."""

def lock_source(package):
    # Download mirrors are not Cargo package identities.
    return package.get("lock_source", package.get("source")) or ""

def package_fq(package):
    return package.get("fq", package["name"] + "-" + package["version"])

def source_suffix(source):
    # Starlark's string hash is deterministic. Reject collisions when assigning
    # names, rather than silently merging unrelated packages.
    return "__source" + str(hash(source)).replace("-", "n") if source else "__path"

def assign_package_ids(packages):
    """Keep ordinary labels; disambiguate only repeated name/version pairs."""
    sources_by_nv = {}
    for package in packages:
        nv = (package["name"], package["version"])
        sources_by_nv.setdefault(nv, []).append(lock_source(package))

    used = {}
    for package in packages:
        source = lock_source(package)
        package["lock_source"] = source
        nv = (package["name"], package["version"])
        fq = package["name"] + "-" + package["version"]
        if len(sources_by_nv[nv]) > 1:
            fq += source_suffix(source)
        repo_name = fq.replace("+", "-")
        if repo_name in used:
            fail("Cargo packages %s and %s produce the same Bazel name %s" % (used[repo_name], (nv, source), repo_name))
        used[repo_name] = (nv, source)
        package["fq"] = fq

def package_spoke(hub_name, package):
    return (hub_name + "__" + package_fq(package)).replace("+", "-")

def registry_fact_key(package):
    return package["source"] + "_" + package["name"] + "_" + package["version"]
