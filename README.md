# X4 Cat Tool

A bash script for listing and extracting files from [X4 Foundations](https://www.egosoft.com/games/x4/info_en.php) `cat`/`dat` archive pairs using only standard Unix utilities (`awk`, `find`, `sort`, `tail`, `head`, `date`).

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
x4_cat_tool.sh [OPTIONS] <source> <command> <path_or_mask> [<dest_dir>]
```

| Argument | Description |
|---|---|
| `source` | Folder containing `cat`/`dat` files, **or** a single `.cat` file |
| `command` | `x` - extract &nbsp;&nbsp; `ls` - list |
| `path_or_mask` | Path prefix or glob mask (see [Filtering](#filtering)) |
| `dest_dir` | Output directory (required for `x`, not used for `ls`) |

### Options

| Flag | Description |
|---|---|
| `-f` | Force overwrite of already-existing output files |
| `-n` | Skip MD5 hash verification after extraction |
| `-s` | Strip the filter path prefix from output paths (see [Strip prefix](#strip-prefix)) |
| `-v` | Verbose output (shows offset, size, dat file, hash result) |
| `-h` | Show help |

## Commands

### `ls` - List matching files

Prints a table of matching catalog entries to stdout. No files are written.

```bash
x4_cat_tool.sh /game/x4  ls  assets/textures
x4_cat_tool.sh /game/x4  ls  "libraries/*.xml"
x4_cat_tool.sh /game/x4  ls  t/
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
x4_cat_tool.sh /game/x4        x  assets/textures          /tmp/out
x4_cat_tool.sh /game/x4/01.cat x  "libraries/*.xml"        /tmp/out
x4_cat_tool.sh -f /game/x4     x  maps                     /tmp/out
```

Each extracted file is logged:

```
  Extract: assets/textures/ui/foo.gz
```

Hash verification runs automatically after each extraction unless `-n` is given. A warning is printed on mismatch but extraction continues.

#### Strip prefix

With `-s`, the `path_or_mask` prefix is stripped from the output path so files land directly in `dest_dir` without the leading path hierarchy:

```bash
x4_cat_tool.sh -s /game/x4  x  assets/textures/ui/player_info  /tmp/out
# → /tmp/out/icon_logbook_alerts.gz   (not /tmp/out/assets/textures/ui/player_info/...)
```

The log shows both paths when stripping is active:

```
  Extract: assets/textures/ui/player_info/icon_logbook_alerts.gz -> icon_logbook_alerts.gz
```

## Filtering

| Pattern | Behaviour |
|---|---|
| `assets/textures` | Prefix match - all files whose path starts with `assets/textures` |
| `assets/textures/` | Same - trailing slash is stripped before matching |
| `libraries/*.xml` | Glob with `/` - matched against the full catalog path |
| `0001*.xml` | Glob without `/` - matched against the **filename only** (e.g. matches `t/0001-l044.xml`) |

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
x4_cat_tool.sh '/c/Program Files (x86)/X4 Foundations' ls t/

# List all XML files matching a name pattern across all catalogs
x4_cat_tool.sh '/c/Program Files (x86)/X4 Foundations' ls '0001*.xml'

# Extract all libraries
x4_cat_tool.sh '/c/Program Files (x86)/X4 Foundations' x libraries/ /tmp/x4out

# Extract a texture folder, stripping the leading path
x4_cat_tool.sh -s '/c/Program Files (x86)/X4 Foundations' x \
    assets/textures/ui/player_info /tmp/icons

# Extract from a specific catalog only (no priority merging)
x4_cat_tool.sh '/c/Program Files (x86)/X4 Foundations/01.cat' x maps/ /tmp/maps

# Force re-extract, skip hash check, verbose
x4_cat_tool.sh -fnv '/c/Program Files (x86)/X4 Foundations' x aiscripts/ /tmp/ai
```

## Requirements

- Bash 4.0+ (associative arrays, `${var,,}`)
- `awk`, `find`, `sort`, `tail`, `head`, `date`, `mkdir`, `dirname`
- `md5sum` (Linux) or `md5` (macOS)

Available out of the box on any Linux distribution and macOS.

## Performance

The entire catalog merge and filter step runs inside a single `awk` invocation. This makes parsing 450,000+ entries across 9 catalog files feasible in a few seconds.
