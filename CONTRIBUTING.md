# Contributing

Thank you for considering a contribution to this module. This document describes the expected workflow.

## Workflow

1. Fork the repository and create a feature branch from `main`.
2. Make your changes with tests.
3. Run the checks locally before pushing:
   ```bash
   pdk validate
   pdk test unit
   ```
4. Regenerate documentation if you changed any manifest, type or provider:
   ```bash
   pdk bundle exec puppet strings generate --format markdown
   ```
5. Update `CHANGELOG.md` under the `Unreleased` section (Keep a Changelog format).
6. Submit a pull request using the provided template.

## Rules

- All code, comments, documentation, commit messages and error messages must be in English.
- Puppet code must pass `puppet-lint` with no warnings.
- All class and defined type parameters must use strict Puppet data types.
- All public classes, defined types, facts and providers must carry puppet-strings documentation.
- No secrets in plain text, no unnecessary dependencies.

## Releases

Releases are cut by pushing a semver tag (`vX.Y.Z`) that matches `metadata.json`:

```bash
# metadata.json version is 1.0.0, so:
git tag v1.0.0
git push origin v1.0.0
```

The release workflow re-runs lint and unit tests, builds the package with `pdk build`,
publishes it to the Puppet Forge and creates a GitHub Release with the notes
extracted from `CHANGELOG.md`.
