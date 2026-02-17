# Releasing Geminy Cricket

This document covers how to package and publish `geminy-cricket` to RubyGems.

## What Gets Packaged

The gem package includes only runtime files from:
- `bin/`
- `lib/`
- `dashboard/`
- `README.md`
- `LICENSE`

Planning docs and internal notes (for example `planning/`) are intentionally not packaged.

## Prerequisites

1. Ruby 3.3+
2. RubyGems account with push access
3. RubyGems API key configured locally (`~/.gem/credentials`) for manual releases
4. For runtime use on macOS: `brew install duckdb`

## Manual Release Checklist

1. Ensure branch is clean and checks pass.

```bash
make check
make release-check
make release-check-install
```
2. Update version in `lib/geminy_cricket/version.rb`.
3. Commit version bump.
4. Build gem:

```bash
gem build geminy-cricket.gemspec
```

5. Inspect package contents:

```bash
tar -tf geminy-cricket-<VERSION>.gem
```

6. Optional local install smoke test:

```bash
gem install ./geminy-cricket-<VERSION>.gem
geminy-cricket --help
ruby -e 'puts Gem::Specification.find_by_name("geminy-cricket").executables.sort.join(",")'
```

7. Push to RubyGems:

```bash
gem push geminy-cricket-<VERSION>.gem
```

8. Tag and push tag:

```bash
git tag v<VERSION>
git push origin v<VERSION>
```

## Automated Release (GitHub Actions)

This repo includes a tag-triggered workflow at `.github/workflows/release.yml`.

When you push a tag matching `v*.*.*`, the workflow will:
1. Build the gem.
2. Publish it to RubyGems using `RUBYGEMS_API_KEY` secret.

Required repository secret:
- `RUBYGEMS_API_KEY`

## Recommended Tag Flow

1. Bump version in code.
2. Merge to main.
3. Create and push tag `vX.Y.Z`.
4. Verify GitHub Actions release job succeeds.
5. Confirm version is available on RubyGems.
