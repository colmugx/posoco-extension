# colmugx/posoco-devkit

Small helper layer for Posoco extension authors.

Core Posoco does not depend on this package. Extension authors can depend on it
when they want simple logger helpers and DI-style context for extension code.

```moonbit
let logger = MemoryLogger::new()
let ctx = ExtContext::new(logger)
ctx.warn(source="my-ext", code="my.warn", message="something happened")
```
