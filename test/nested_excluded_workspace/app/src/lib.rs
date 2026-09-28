#[test]
fn local_and_registry_packages_remain_distinct() {
    assert_eq!(bridge::origin(), "local-1.0.15");
    assert_eq!(registry_itoa::Buffer::new().format(42), "42");
}
