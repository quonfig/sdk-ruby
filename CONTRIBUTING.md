# Contributing to `quonfig` (Ruby SDK)

Thanks for your interest in contributing! This guide covers the basics of getting set up,
running tests, and sending pull requests.

## Reporting Issues

Before opening a new issue, please check the
[issue list](https://github.com/quonfig/sdk-ruby/issues) to see if it has already been
reported or fixed.

When filing a bug, include:

- The version of `quonfig` you're running (`gem list quonfig`)
- Ruby version (`ruby --version`) — we test against Ruby 3.1, 3.2, and 3.3
- A minimal reproduction (a snippet, or ideally a failing test) and the actual vs. expected
  behavior

For security issues, please follow [SECURITY.md](./SECURITY.md) instead of filing a public
issue.

## Local Development

Clone, install dependencies with bundler, and you're ready:

```sh
git clone https://github.com/quonfig/sdk-ruby.git
cd sdk-ruby
bundle install
```

### Test

```sh
bundle exec rake test
```

Some tests exercise the integration suite that lives in the sibling
[`integration-test-data`](https://github.com/quonfig/integration-test-data) repo. The CI
workflow checks out both repos side-by-side; for local runs, only the unit-level tests are
required.

## Sending Pull Requests

- Open a draft PR early if you'd like feedback before finishing the implementation.
- Add a test for any behavior change. Bug fixes should include a regression test that fails
  without the fix.
- Update `CHANGELOG.md` in the same commit as the public-API change. We follow semver — any
  breaking change must be called out in the migration notes.
- Keep commits focused. If a PR touches both a feature and an unrelated cleanup, split them.
- If you change `quonfig.gemspec` or `Gemfile`, regenerate `Gemfile.lock` (`bundle install`)
  and stage it in the same commit so CI's frozen install does not fail.

The CI pipeline (`.github/workflows/test.yaml`) runs `bundle exec rake test` on Ruby 3.1,
3.2, and 3.3 on every push and pull request — please make sure tests pass locally before
requesting review.

## Releases

Releases are automated by `.github/workflows/release.yml` and fire on `v*` tag pushes via
rubygems.org Trusted Publishing. The publish step refuses to push unless the tag matches
`Quonfig::VERSION` in `lib/quonfig/version.rb`. Releasing is currently maintainer-only; if
your change is ready to ship, leave a note on the PR and a maintainer will cut the release.

Thanks again for contributing!
