# laffy

A Zig port of [taffy](https://github.com/DioxusLabs/taffy), the UI layout library implementing
flexbox, CSS grid, block and float layout.

Status: early scaffolding. See [PLAN.md](PLAN.md) for the roadmap and current milestone.

## Development

Requires Zig 0.17.1 (pinned in `mise.toml`).

```sh
zig build test                 # run unit tests
scripts/sync-fixtures.sh       # re-vendor fixtures at the pinned taffy commit
scripts/sync-fixtures.sh <ref> # move the pin to another taffy commit
```

Conformance is measured against taffy's Chrome-generated XML fixtures, vendored unmodified in
`tests/fixtures/xml`. The pinned upstream commit is recorded in `tests/fixtures/UPSTREAM`.

## License

MIT. laffy is derived from taffy; see [LICENSE](LICENSE).
