# Domain Docs

Before exploring, read `CONTEXT.md` for product language and `docs/architecture/current-system.md` for the inherited runtime boundaries and preservation rules. Also read `CONTEXT-MAP.md` and relevant ADRs under `docs/adr/` when they exist. Missing files require no warning.

This repository currently uses the single-context structure:

```
/
├── CONTEXT.md
├── docs/adr/
└── source directories
```

Use vocabulary defined in `CONTEXT.md`. Treat code and tests as authoritative when older prose conflicts with current behavior. Flag proposals that conflict with an existing ADR instead of silently overriding it. Domain-modeling creates these documents lazily as terminology and decisions are resolved.
