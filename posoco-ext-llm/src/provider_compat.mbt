///|
/// Compatibility exports for the provider contracts that now live canonically
/// in `colmugx/posoco-kit-provider`.
///
/// `pub using` re-exports the canonical types under their historical `@llm`
/// names. This is the same mechanism core uses to surface `@port`/`@error`
/// types as `@posoco.*`: `@llm.ModelSlot` and `@provider.ModelSlot` are the
/// *same* type, so constructors, struct literals, pattern matches, method
/// dot-calls, and `impl @llm.ProviderFactory` keep working for existing
/// consumers with no parallel representation and no duplicated trait
/// identity. New code should import the kit directly.

///|
pub using @provider {type ProviderConfigSource}

///|
pub using @provider {type ProviderBuildResult}

///|
pub using @provider {trait ProviderFactory}

///|
pub using @provider {trait RefreshableProviderFactory}

///|
pub using @provider {trait OAuthFactory}

///|
pub using @provider {trait ApiKeyFactory}

///|
pub using @provider {type AuthMethod}

///|
pub using @provider {type ModelSlot}

///|
pub using @provider {type ModelKind}

///|
pub using @provider {type ProviderModelCatalog}
