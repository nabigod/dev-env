# Portable Development Environment

`setup_devenv.sh` applies tool modules selected by an INI configuration file. The
script resolves the repository from its own path, so it can be invoked from any
working directory.

## Usage

```bash
./setup_devenv.sh -c configs/online.conf
./setup_devenv.sh -c configs/offline-lite.conf --dry-run
./setup_devenv.sh --list-backups
./setup_devenv.sh --restore 20261031-120000-1234
```

Options are `--dry-run`, `-v`/`--verbose`, `--restore ID`,
`--list-backups`, and `-h`/`--help`. Omitting `-c` prints the available
repository configs and exits. The current skeleton configs contain only the
`[general]` section; tool sections are added by the corresponding module
work.

## Config format

```ini
[general]
backup_dir = ~/.dev-env-backup

[vim]
enable = true
install = false
```

Sections use the module directory name. Keys are `key = value`; blank lines and
full-line `#` or `;` comments are ignored. Boolean values are
`true`/`false`, `yes`/`no`, `on`/`off`, and `1`/`0`. Unknown sections are
errors. Unknown keys are warnings, allowing a module to evolve without making
older shared parsing code reject its configuration.

## Adding a tool module

Create `tools/<category>/<tool>/module.sh` and add a `[tool]` section to a
config. The top script discovers modules by section name; it does not need to
be edited.

A module is sourced in an isolated subshell with these exported variables:

- `DEVENV_REPO_DIR`: absolute repository path.
- `DEVENV_TOOL_NAME`: config section/module name.
- `DEVENV_CONFIG_FILE`: selected config path.
- `HOME`, `DEVENV_DRY_RUN`, and `DEVENV_VERBOSE`.

Each module must define:

- `module_detect`: no arguments; return `0` when the tool is available, `1`
  when it is absent, and another nonzero status for a detection error.
- `module_apply`: no arguments; return `0` when applied, `3` for an intentional
  skip, and another nonzero status on failure. Use `module_skip "reason"` to
  report a one-line human-readable skip reason. A bare return code `3` is a
  failure, not a skip; this prevents detection or application errors from
  being hidden.

A module may define `module_install` (no arguments) when it supports
`install = true`, and `module_known_keys` to print a space-separated list of
accepted keys. `module_install` may return `3` when installation is
intentionally skipped; `pkg_install` uses this convention and provides the
reason through the framework. The code `3` is treated as an installation skip
only when `pkg_install` supplied a non-empty skip reason. During `--dry-run`,
installation is reported as planned and `module_install` is not called. A missing tool with
`install = false` is reported as `skipped (not installed)`. Module failures
are isolated, summarized as `applied`, `skipped`, or `failed` with a reason,
and make the top script exit nonzero without preventing other modules from
running.

Module stdout and stderr are streamed directly in execution order, and a
module keeps the script's own stdin. The runner uses a transient result file
under `${TMPDIR:-/tmp}` only for the final state and reason. It is removed after
each module and on every exit path, including termination signals; it is not a
configuration or backup file.

On `SIGINT`, `SIGTERM` or `SIGHUP` the script stops the running module and every
process it started (`SIGTERM`, then `SIGKILL` after about five seconds), does
not run the remaining modules, prints an `Interrupted by SIG...` message and
exits with `128` plus the signal number (`130`, `143`, `129`). No tool summary
is printed for an interrupted run, and the interrupted module is not reported
as failed. Finding the module's child processes reads `/proc`, so this part
requires Linux.

Modules should use these shared library functions rather than modifying HOME
by other means:

- `log_info`, `log_verbose`, `log_warn`, `log_error`.
- `config_get`, `config_has`, `config_bool`, `config_sections`.
- `version_normalize`, `version_compare`, `version_at_least`.
- `deploy_link source target` for idempotent symlink deployment.
- `deploy_displace target` to back up and remove an existing HOME target
  before another deployment. It accepts regular files, directories, and
  symlinks; special files and removal failures are errors without a successful
  displacement record.
- `rc_block_apply rc_file block_file` and `rc_block_remove rc_file` for the
  fixed portable-devenv rc block.
- `pkg_manager_detect`, `pkg_install package...` for apt-get, dnf, or yum.
- `download_file url destination [sha256]` for curl/wget downloads.

`deploy_link`, `deploy_displace`, and `rc_block_apply` record their changes in
a timestamped backup manifest. `deploy_displace` writes a `BEFORE` record and
an `AFTER_ABSENT` record before removing the target. Restore only replaces a
target when its current state still matches the state produced by that setup
run; changed targets are warned about and left untouched. `--restore ID
--dry-run` only reports the restore and does not modify HOME. Before anything
is restored, the whole manifest is validated by the same code for
`--restore` and `--restore --dry-run`: every target must be a safe path, every
saved copy must be exactly `<backup directory>/item-<number>` and exist, saved
paths must be unique across BEFORE records, every target has at most one AFTER
record, unknown record types are rejected, and every record must be well
formed. Blank lines and comment lines beginning with `#` are ignored. Each
new saved copy scans the backup directory for the next unused `item-<number>`,
so isolated modules cannot overwrite one another's backup item. An invalid
manifest is rejected with an error and a nonzero exit status, and nothing is
restored.

Within one setup run, a target that was actually changed by
`deploy_displace` cannot be handled again: `deploy_displace` followed by
`deploy_link`, `rc_block_apply`, or another `deploy_displace` is rejected, as
are the reverse orders. Repeating an already-correct `deploy_link` or
`rc_block_apply` is idempotent and allowed. These guards use manifest records,
so they do not fire during `--dry-run`; the real run reports the conflict.

If removal fails after an `AFTER_ABSENT` record was written, restore warns that
the target still exists and returns nonzero while preserving the target.
If directory removal stops after removing only part of a directory, restore
refuses to overwrite the remaining target; use the saved `item-<number>` copy
for manual recovery. An interrupted removal has the same partial-state risk.
As with `deploy_link`, a parent symlink that points outside HOME can cause a
lexically safe target path to affect a file outside HOME.

Backup and deployment paths must be absolute paths strictly inside a non-root,
non-empty `HOME`. They must be canonical: HOME itself, `.` or `..` components,
empty components (`a//b`, a trailing slash), tabs, and newlines are rejected.
The one exception is `backup_dir` in `[general]`: a trailing slash is removed
(`~/bk/` means `~/bk`) because it never changes which directory is meant.
Every other non-canonical spelling is rejected with a message that names the
actual reason. Moving the repository requires running setup again
because links and rc blocks contain absolute repository paths. An rc file that
is itself a symlink is replaced by a regular file during rc block updates;
the original symlink remains restorable from its manifest.

Downloads use a temporary file and atomically replace the destination only
after an optional SHA-256 check. A failed download or checksum check preserves
the existing destination. The implementation uses coreutils for comparison
and hashing and does not require `cmp`.

## Supported scope and limitations

The framework targets bash 4.2-compatible syntax and Linux systems. Package
installation uses only apt-get, dnf, or yum and is skipped with a manual
command when the manager or sudo is unavailable. The supplied smoke test uses
a temporary HOME; it does not modify the real HOME.
