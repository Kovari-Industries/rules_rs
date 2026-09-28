#[cfg(not(feature = "inherited-feature"))]
compile_error!("nested workspace dependency features were not inherited");

pub fn origin() -> &'static str {
    concat!("local-", env!("CARGO_PKG_VERSION"))
}

// Parsing this requires the nested workspace edition, not the root edition.
pub async fn edition_check() {}
