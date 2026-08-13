# X4 Cat Tool

A bash script for creating, listing and extracting [X4 Foundations](https://www.egosoft.com/games/x4/info_en.php) `cat`/`dat` archive pairs using only standard Unix utilities (`awk`, `find`, `sort`, `stat`, `md5sum`, `xargs`, `paste`).

Catalogs written by this script are **byte-for-byte identical** to those produced by Egosoft's `XRCatTool.exe` 1.10, so it can replace the Windows-only packing step of a mod build on Linux and macOS.

## Installation

Clone the repository and make the script executable:

```bash
git clone https://github.com/chemodun/X4-LinuxCatTool.git
cd X4-LinuxCatTool
chmod +x x4_cat_tool.sh
```

Or download just the script directly:

```bash
curl -O https://raw.githubusercontent.com/chemodun/X4-LinuxCatTool/main/x4_cat_tool.sh
chmod +x x4_cat_tool.sh
```

Optionally, copy it somewhere on your `PATH` (e.g. `~/.local/bin/`) so you can run it from anywhere:

```bash
cp x4_cat_tool.sh ~/.local/bin/x4_cat_tool.sh
```

## Overview

X4 Foundations stores its game assets in paired catalog/data files:

- **`.cat`** - plain-text catalog; each line describes one file:
  ```
  <filepath> <size_bytes> <unix_timestamp> <md5_32hex>
  ```
- **`.dat`** - binary blob containing all files concatenated in the order listed in the `.cat`.

Files are split across multiple numbered catalog pairs (`01.cat`/`01.dat`, `02.cat`/`02.dat`, …). Higher-numbered catalogs have higher priority: the same path in `07.cat` overrides `01.cat`. A size-0 entry in a higher catalog is a **deletion marker** - the file is treated as absent.

`_sig.cat` signature catalogs are automatically skipped.

## Usage

```
./x4_cat_tool.sh [OPTIONS] <source> <command> <path_or_mask> [<dest_dir>]
./x4_cat_tool.sh [OPTIONS] <source_dir> c <out.cat>
```

| Argument | Description |
|---|---|
| `source` | Folder containing `cat`/`dat` files, **or** a single `.cat` file. For `c`: the folder to pack |
| `command` | `x` - extract &nbsp;&nbsp; `ls` - list &nbsp;&nbsp; `c` - create |
| `path_or_mask` | Path prefix or glob mask (see [Filtering](#filtering)). For `c`: the output catalog name, which must end in `.cat` |
| `dest_dir` | Output directory (required for `x`, not used for `ls` and `c`) |

### Options

| Flag | Applies to | Description |
|---|---|---|
| `-f` | `x` `c` | Force overwrite of already-existing output files or of an existing catalog |
| `-n` | `x` | Skip MD5 hash verification after extraction |
| `-s` | `x` | Strip the filter path prefix from output paths (see [Strip prefix](#strip-prefix)) |
| `-i <dir>` | `c` | Additional input folder; repeatable. Files from later folders override same-named files from earlier ones |
| `-I <re>` | `c` | Include only paths matching this regex; repeatable, OR-ed together |
| `-E <re>` | `c` | Exclude paths matching this regex; repeatable, applied after `-I` |
| `-a` | `c` | Append to an existing catalog instead of replacing it |
| `-v` | all | Verbose output (shows offset, size, dat file, hash result; for `c` lists every packed entry) |
| `-h` | all | Show help |

## Commands

### `ls` - List matching files

Prints a table of matching catalog entries to stdout. No files are written.

```bash
./x4_cat_tool.sh /game/x4  ls  assets/textures
./x4_cat_tool.sh /game/x4  ls  "libraries/*.xml"
./x4_cat_tool.sh /game/x4  ls  t/
```

**Output (folder/multi-cat mode)** includes a `CAT` column showing which catalog last defined each file:

```
SIZE          DATE                 CAT           PATH
------------  -------------------  ------------  ----
      123456  2025-08-19 17:21:23  03.cat        assets/textures/foo.dds
   [deleted]  2025-09-01 10:00:00  07.cat        assets/textures/old.dds
```

In single-cat mode the `CAT` column is omitted.

### `x` - Extract matching files

Extracts matching files into `dest_dir`, preserving the catalog path structure by default.

```bash
./x4_cat_tool.sh /game/x4        x  assets/textures          /tmp/out
./x4_cat_tool.sh /game/x4/01.cat x  "libraries/*.xml"        /tmp/out
./x4_cat_tool.sh -f /game/x4     x  maps                     /tmp/out
```

Each extracted file is logged:

```
  Extract: assets/textures/ui/foo.gz
```

Hash verification runs automatically after each extraction unless `-n` is given. A warning is printed on mismatch but extraction continues.

#### Strip prefix

With `-s`, the `path_or_mask` prefix is stripped from the output path so files land directly in `dest_dir` without the leading path hierarchy:

```bash
./x4_cat_tool.sh -s /game/x4  x  assets/textures/ui/player_info  /tmp/out
# → /tmp/out/icon_logbook_alerts.gz   (not /tmp/out/assets/textures/ui/player_info/...)
```

The log shows both paths when stripping is active:

```
  Extract: assets/textures/ui/player_info/icon_logbook_alerts.gz -> icon_logbook_alerts.gz
```

### `c` - Create a catalog

Packs a folder into a `cat`/`dat` pair. The `.dat` name is derived from the `.cat` name, so `ext_01.cat` writes `ext_01.dat` beside it.

```bash
./x4_cat_tool.sh ./my_mod c ext_01.cat
./x4_cat_tool.sh -v ./my_mod c /tmp/build/ext_01.cat
```

An existing catalog is never replaced silently - pass `-f` to overwrite it or `-a` to append to it. This is deliberately stricter than `XRCatTool.exe`, which overwrites without asking.

Multiple input folders are merged with `-i`, and later folders win. This is how you overlay a patch tree on top of a base tree:

```bash
./x4_cat_tool.sh ./base -i ./overrides c ext_01.cat
```

#### Filtering what gets packed

`-I` includes and `-E` excludes take **regular expressions**, not globs, matched exactly the way `XRCatTool.exe` matches its `-include` / `-exclude`: as a **substring search against the lowercased path**. So `-E "content.xml"` drops that file wherever it sits, while `-E "^assets/"` only anchors at the start. Repeating `-I` ORs the patterns; `-E` is applied afterwards to whatever survived.

This mirrors a typical two-catalog mod build, where the substitution catalog and the extension catalog are cut from one source tree:

```bash
./x4_cat_tool.sh -I "ego_debuglog/ui.xml" ./my_mod c subst_01.cat
./x4_cat_tool.sh -E "ego_debuglog/ui.xml" -E "content.xml" ./my_mod c ext_01.cat
```

Nothing is excluded by default, so packing a working copy directly will pull in `.git` and other development files. Filter them out explicitly:

```bash
./x4_cat_tool.sh -E "^\.git" -E "^docs/" -E "\.bat$" ./my_mod c ext_01.cat
```

#### Appending

`-a` appends the new entries to an existing pair instead of rewriting it:

```bash
./x4_cat_tool.sh -a ./more_files c ext_01.cat
```

The appended block is sorted within itself and added at the end, exactly as `XRCatTool.exe -append` does. The catalog as a whole is therefore no longer globally sorted, and duplicate paths are not merged away - the later entry simply wins at load time. If `-a` is given but the catalog does not exist yet, it is created.

## Filtering

Applies to `x` and `ls`. The `c` command filters with regexes instead, via `-I` / `-E` - see [Filtering what gets packed](#filtering-what-gets-packed).

| Pattern | Behaviour |
|---|---|
| `*` | **Everything** - the whole catalog. Use this to list or extract a complete archive |
| `assets/textures` | Prefix match - all files whose path starts with `assets/textures` |
| `assets/textures/` | Same - trailing slash is stripped before matching |
| `libraries/*.xml` | Glob with `/` - matched against the full catalog path |
| `0001*.xml` | Glob without `/` - matched against the **filename only** (e.g. matches `t/0001-l044.xml`) |

An **empty** mask (`""`) matches nothing rather than everything, so pass `*` when you want the whole catalog:

```bash
./x4_cat_tool.sh /game/x4/01.cat x '*' /tmp/out
```

## Priority rules

### Folder mode (multiple catalogs)

Cat files are sorted by name ascending. Each subsequent file overrides earlier entries for the same path:

```
01.cat  assets/foo.bin  500000 ...   ← earlier version
07.cat  assets/foo.bin       0 ...   ← deletion marker → file is NOT extracted
```

### Single-cat mode

Only the specified `.cat`/`.dat` pair is used. Size-0 entries produce no output.

## Examples

```bash
# List all files under the 't' directory
./x4_cat_tool.sh '/c/Program Files (x86)/X4 Foundations' ls t/

# List all XML files matching a name pattern across all catalogs
./x4_cat_tool.sh '/c/Program Files (x86)/X4 Foundations' ls '0001*.xml'

# Extract all libraries
./x4_cat_tool.sh '/c/Program Files (x86)/X4 Foundations' x libraries/ /tmp/x4out

# Extract a texture folder, stripping the leading path
./x4_cat_tool.sh -s '/c/Program Files (x86)/X4 Foundations' x \
    assets/textures/ui/player_info /tmp/icons

# Extract from a specific catalog only (no priority merging)
./x4_cat_tool.sh '/c/Program Files (x86)/X4 Foundations/01.cat' x maps/ /tmp/maps

# Force re-extract, skip hash check, verbose
./x4_cat_tool.sh -fnv '/c/Program Files (x86)/X4 Foundations' x aiscripts/ /tmp/ai

# Extract an entire catalog
./x4_cat_tool.sh '/c/Program Files (x86)/X4 Foundations/01.cat' x '*' /tmp/all

# Pack a mod folder into a catalog pair
./x4_cat_tool.sh ./my_mod c ext_01.cat

# Pack everything except the assets tree, listing each entry
./x4_cat_tool.sh -v -E '^assets/' ./my_mod c ext_01.cat
```

## Catalog format written by `c`

These rules were confirmed by packing test trees with `XRCatTool.exe` 1.10 and comparing the bytes. They matter if you ever hand-write or post-process a catalog:

- The `.cat` uses **LF** line endings with no header and no BOM, and ends with a trailing newline.
- Paths keep their **original case** and always use forward slashes.
- Entries are sorted by the **lowercased** path in C byte order. So `UPPER.TXT` sorts after `stray.dat`, not before it, and a plain `sort` on the raw paths gives the wrong order.
- The timestamp is the source file's **mtime**, not the time of packing.
- A **zero-byte file** is written with 32 zeros as its hash. The md5 of an empty file (`d41d8cd9…`) never appears.
- The `.dat` is a plain concatenation of the file contents in catalog order - no header, no padding, no alignment. Offsets are implied by the running sum of the sizes.

A deletion marker, which the game reads as "this file is absent", is an entry with size 0 **and** timestamp 0. `c` does not generate those; it is what `XRCatTool.exe -diff` emits.

## Requirements

- Bash 4.0+ (associative arrays, `${var,,}`)
- `awk`, `find`, `sort`, `tail`, `head`, `date`, `mkdir`, `dirname`
- `md5sum` (Linux) or `md5` (macOS)
- For `c` additionally: `stat`, `paste`, `tr`, `xargs`, `mktemp`, `sed`, `cat`, `wc`

Available out of the box on any Linux distribution and macOS. Both GNU (`stat -c`) and BSD/macOS (`stat -f`) syntax are detected automatically.

Source paths containing tab or newline characters are not supported, as the pipelines are tab- and line-delimited. Neither is representable in an X4 mod.

## Performance

The entire catalog merge and filter step runs inside a single `awk` invocation. This makes parsing 450,000+ entries across 9 catalog files feasible in a few seconds.

`c` works the same way. The file scan, filtering, sorting and metadata collection are pipelines rather than per-file shell loops, and hashing runs as one `md5sum` process per `xargs` batch instead of one per file. Packing a 1000-file, 20 MB mod takes a few seconds.

`x` is process-bound rather than I/O-bound, since `tail -c +N` and `dd` both seek straight to the offset - a file at the end of a 20 GB archive costs no more to extract than one at the start. Extraction therefore runs one process per file rather than the six or seven a naive loop needs: output paths are resolved with shell builtins instead of `dirname`, every output directory is created in one batched `mkdir`, the byte range is copied by a single `dd` where GNU `dd` is available (falling back to `tail | head` on macOS and BSD), and hashes are verified in `xargs` batches after the fact instead of one `md5sum` per file.

## Changelog

### [1.1.1] - 2026-08-13

- Changed:
  - Extraction is substantially faster. A file now costs one process instead of six or seven - output paths are resolved with shell builtins, every output directory is created in a single batched `mkdir`, the byte range is copied by one `dd` where GNU `dd` is available, and hashes are verified in batches afterwards rather than one `md5sum` per file. Measured 3.4x faster with verification and 2.6x with `-n`; a full 1000-file catalog that previously ran past a two-minute timeout now completes in about a minute. Gains are largest where process creation is expensive.
- Fixed:
  - With `-s`, the check that skips already-extracted files tested the unstripped path, so it never matched and every file was re-extracted on each run. It now checks the real output path.

### [1.1.0] - 2026-08-13

- Added:
  - `c` command - create a `cat`/`dat` pair from a folder. Output is byte-for-byte identical to `XRCatTool.exe` 1.10, verified across nine cases including a 1000-file mod.
  - `-i <dir>` - additional input folders, repeatable, with files from later folders overriding earlier ones.
  - `-I <re>` and `-E <re>` - include and exclude filters for `c`, using the same regex substring-search semantics as `XRCatTool.exe`'s `-include` / `-exclude`. Both are repeatable; `-I` patterns are OR-ed and `-E` is applied afterwards.
  - `-a` - append to an existing catalog rather than replacing it.
  - `-V` - print the tool version and exit.
- Changed:
  - `-f` now also guards `c`: an existing catalog is never overwritten without it. This is deliberately stricter than `XRCatTool.exe`, which overwrites silently.
- Documentation:
  - The `*` mask is now documented, including that an empty mask matches nothing rather than everything.
  - New section describing the catalog format written by `c` - the case-folded sort order, the zero hash used for empty files, and the size-0 / timestamp-0 shape of a deletion marker.

### [1.0.0]

- Added:
  - `ls` command - list catalog entries with size, date and originating catalog.
  - `x` command - extract entries, with MD5 verification (`-n` to skip) and `-s` to strip the filter prefix from output paths.
  - Folder mode with catalog priority merging and deletion markers, and single-catalog mode.
  - Prefix, full-path glob and filename-only glob filtering.
