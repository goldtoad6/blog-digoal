# PG Build Options for Bug Hunting

Configure flags used by `build_and_start_pg.sh` (override via
`PG_CONFIGURE_OPTS` env var). Defaults are tuned for finding bugs
fast, not for production.

## Recommended defaults

```
--enable-debug
--enable-cassert
--enable-debug-symbols
--prefix=$PG_SRC_DIR/install
```

- **`--enable-debug`** — turns on `elog(ERROR, ...)` debug aids
  (`assertions`, `pgstat_report_wait_start`, more aggressive `ereport`
  in places) and adds debug symbols to binaries.
- **`--enable-cassert`** — enables `Assert()` in the backend. Many
  latent bugs trip an `Assert` long before they produce a user-visible
  crash. **This is the single most useful flag for bug hunting.**
- **`--enable-debug-symbols`** — emits `-g` so a crash produces a usable
  core / backtrace. Stripping is disabled.
- **`--prefix=$PG_SRC_DIR/install`** — keeps the build isolated from
  the system PG. You can blow it away without affecting anything else.

## Optional flags worth knowing

- `--with-openssl` — required if you want to test SSL / GSS / SCRAM
  auth paths.
- `--with-icu` — required to exercise ICU-backed collations
  (often a source of bugs around locale-aware comparisons).
- `--with-llvm` — enables JIT. JIT has its own long tail of bugs; turn
  on if you want to chase them.
- `--enable-tap-tests` — installs Perl TAP runner, needed for the
  regression suite (`make check`).
- `--enable-nls` — multi-language message paths; useful for finding
  encoding / translation issues.

## Build & install lifecycle

```bash
cd $PG_SRC_DIR
./configure $PG_CONFIGURE_OPTS     # one-time
make -j$(nproc)                     # incremental rebuilds
make install                        # install into $PG_PREFIX
initdb -D $PGDATA                   # one-time per data dir
pg_ctl -D $PGDATA -l $PG_LOG start  # idempotent start
```

`build_and_start_pg.sh` runs all of the above and skips steps that
are already done, so it is safe to re-run after editing C code.

## Common pitfalls

- **`make` after editing headers** — run `make clean` only if you
  changed `src/include/`. The build is otherwise incremental.
- **Stale `config.status`** — if you change `./configure` flags,
  delete `src/Makefile.global` and re-run `./configure`.
- **OpenSSL headers missing** — on macOS: `brew install openssl`,
  then `--with-openssl` will pick it up.
- **`/usr/bin/psql` shadowing** — the script prepends `$PGBIN` to
  `PATH`, but if you `source pg_env.sh` in your shell the order is
  preserved. If you don't source it, `psql` will hit the system one.
