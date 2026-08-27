import Testing

/// Parent suite for every test that mutates a process-wide AI environment
/// variable.
///
/// `setenv`/`unsetenv` are process-global, and `.serialized` on a suite only
/// orders tests *within* that suite — Swift Testing still runs separate suites
/// concurrently. Three AI suites write `OPENROUTER_API_KEY`: the model router,
/// plan routing, and the fallback chain. Nesting them under one `.serialized`
/// parent is the supported way to exclude them from each other.
///
/// Not hypothetical: CI runs 33113209052 and 33114551229 both failed
/// `routerWithoutAnyKey` ("With no key at all no router is built") on `main`
/// while that test passed in isolation, because plan routing had set
/// `OPENROUTER_API_KEY` concurrently.
///
/// A global actor would be the tidier mechanism, but Vapor's
/// `app.testing().test(...)` closures are not `Sendable`, so isolating the
/// suite bodies to one fails to compile.
@Suite(.serialized)
struct AIEnvironmentSuites {}
