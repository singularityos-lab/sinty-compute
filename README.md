# Sinty Compute

Kernel-assisted reuse of computation results on Sinty OS. A program marks the
memory a computation reads, the kernel tells it when that memory may have changed,
and the runtime decides whether a stored result is still valid.

The feature is off by default. It is turned on from Developer Options in Settings,
which only shows it when the kernel module is installed.

## Components

- `kmod/`: the `sinty_compute` kernel module. It exposes `/dev/sinty-compute`,
  tracks memory ranges per process and bumps a range's generation when the kernel
  discards or replaces its pages. Counters and the global switch live in
  `/sys/kernel/sinty_compute`.
- `libsintycompute/`: the C ABI used by runtimes and applications.
- `cmd/sinty-compute`: `status` prints the module state, `probe` checks the
  invalidation rules against the running kernel.
- `cmd/sinty-computed`: the system service behind the Settings switch. It loads
  and unloads the module, sets the mode and keeps the choice across reboots.
  Changes require the `dev.sinty.compute.manage` polkit action.

## Modes

- `measure`: lookups are counted, results are never reused.
- `active`: valid results are reused.
- `verify`: results are recomputed and compared with the stored ones.

## Build

Requires Zig 0.16 and GLib. The module builds against the kernel tree of the target.

```sh
zig build
zig build test
make -C kmod KDIR=/path/to/linux
```

## License

GPL-3.0-only, see [LICENSE](LICENSE). The kernel module is GPL-2.0-only, see
[kmod/LICENSE](kmod/LICENSE). Contributions under the [CLA](CLA.md).

## Use of Generative AI

Maintainers may use generative AI tools as assistants while working on sinty-compute. Non-trivial assisted commits disclose the tool, model, and scope of the work.

AI tools may assist with code comments, documentation, repetitive code, and issue triage. Maintainers make project decisions and review every assisted change before it is merged.

Use these trailers for non-trivial assisted commits:

```plain
Assisted-by: <tool>:<model-version>
AI-Scope: <what the tool generated and the prompt or a short prompt summary>
```

Single-line completions, renames, and formatting changes do not need trailers.

Coding agents must also follow [AGENTS.md](AGENTS.md) before changing files,
creating commits, or opening pull requests.
