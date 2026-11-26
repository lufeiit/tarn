use flutter_rust_bridge::frb;

/// Runs `main(config)` from a profile override script and returns the JSON the
/// script produced. `config` is the profile as JSON; the result replaces it.
#[frb]
pub fn evaluate_script(script: String, config: String) -> Result<String, String> {
    #[cfg(target_os = "ios")]
    {
        let _ = (script, config);
        return Err("script engine is unavailable in this iOS build".to_string());
    }
    #[cfg(not(target_os = "ios"))]
    {
        crate::script::evaluate(&script, &config)
    }
}
