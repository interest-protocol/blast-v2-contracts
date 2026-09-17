#[test_only]
/// External witness fixtures for adapter package-boundary tests.
module blast_boosts_core::test_risk_module;

public struct RiskModule() has drop;

public struct RiskModuleV2() has drop;

public fun new(): RiskModule {
    RiskModule()
}

public fun new_v2(): RiskModuleV2 {
    RiskModuleV2()
}
