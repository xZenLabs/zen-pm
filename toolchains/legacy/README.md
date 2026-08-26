# Patched current Go toolchain for legacy e-readers

ZenPM's 32-bit ARM packages are built with the supported Go 1.26.6 source
release, not an unsupported Go 1.19/1.20 runtime. The source archive and SHA-256
are pinned in this directory. A narrowly scoped patch routes the Linux/ARM
runtime poller through `epoll_wait` and falls back to `accept` when `accept4`
is unavailable. Supported early Kindle kernels can return `ENOSYS` for either
newer syscall, preventing startup or the first incoming connection.

Build the compiler with:

```sh
toolchains/legacy/bootstrap.sh
```

The script verifies the official source archive before applying the checked-in
patch. Set `ZENPM_GO_SOURCE_ARCHIVE` to use an already downloaded archive and
pass an output directory as the first argument when CI needs a different cache
location. Release builds use this compiler only for the ARM soft-float and
hard-float backends.

The patch is intentionally not claimed as an upstream Go configuration. Test
release candidates on the oldest supported Kindle and Kobo kernels before
publishing them.
