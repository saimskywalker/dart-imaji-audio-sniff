# Go-public checklist

Everything above the line is automated or already done; everything below it
needs the owner. Tick items in the pull request that makes the repository
public.

## Automated on every push (CI)

- [x] `dart format --set-exit-if-changed .`
- [x] `dart analyze --fatal-infos` (strict casts, inference and raw types;
      `public_member_api_docs`)
- [x] `dart test` on the oldest supported SDK and on stable, including a
      bounded fuzz run (4,000 mutated inputs: no throws, bounded reads, and
      the sync, random-access and async APIs agree)
- [x] `dart test --platform chrome` (web-safe arithmetic)
- [x] `dart pub publish --dry-run` with no warnings
- [x] `dart run example/main.dart`
- [x] Leak scan, once the `LEAK_PATTERNS` secret exists (see below)

## Done in the repository

- [x] MIT licence, README (symptom, quick start, API, formats table, FAQ,
      comparison), CHANGELOG 0.1.0, CONTRIBUTING
- [x] pubspec `description`, `topics`, `repository`, `issue_tracker`
- [x] All fixtures are synthetic, generated in `test/support/`
- [x] Actions pinned to commit SHAs

## Owner actions

- [ ] Run a long fuzz campaign once: `dart run tool/fuzz.dart --iterations 1000000`
- [ ] Add the private leak patterns as the repository secret `LEAK_PATTERNS`
      (one extended regex, e.g. `word1|word2|host.example`), or locally in an
      untracked `.leakscan` file, and run `tool/leak_scan.sh`
- [ ] Read the README once more as a stranger would
- [ ] Settings → General: make the repository public
- [ ] Settings → Branches: protect `main` (require the CI checks)
- [ ] `dart pub publish` (optionally under a verified publisher), then add
      the pub.dev version badge to the README
- [ ] Tag `v0.1.0` and create a GitHub release from the CHANGELOG entry
- [ ] Optional: automated publishing from GitHub Actions on tags
      (pub.dev → package admin → Automated publishing)
- [ ] Optional: a social preview image (Settings → General)
