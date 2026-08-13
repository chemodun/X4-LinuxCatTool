#!/usr/bin/env bash
# x4_cat_tool.sh — Create / extract / list files in X4 Foundations cat/dat archives
#
# Cat format per line:
#   <filepath> <size_bytes> <unix_timestamp> <md5_32hex>
# Entries are stored contiguously in the paired .dat file.
#
# Priority (folder mode):
#   Cat files are sorted by name ascending; higher-numbered cats override lower ones.
#   An entry with size == 0 in a higher-priority cat is a deletion marker → not extracted.
#
# Single-cat-file mode:
#   Only that .cat/.dat pair is processed.  Size-0 entries produce no output.
#
# Create mode — format rules verified against XRCatTool.exe 1.10:
#   * LF line endings, no header, no BOM; a trailing newline is present.
#   * Paths use forward slashes and keep their original case.
#   * Entries are sorted by the LOWERCASED path in C byte order.
#   * The timestamp is the source file's mtime, not the time of packing.
#   * A zero-byte file is stored with 32 zeros as its hash — the md5 of an empty
#     file is never written.
#   * The .dat is a plain concatenation in catalog order: no header, no padding.
#   * Include/exclude patterns are regexes matched as a SUBSTRING SEARCH against
#     the lowercased path.  Several -I are OR-ed; -E is applied after -I.

set -euo pipefail

VERSION="1.1.1"  # x-release-please-version

# ── usage ─────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
$(basename "$0") $VERSION

Usage: $(basename "$0") [OPTIONS] <source> <command> <path_or_mask> [<dest_dir>]
       $(basename "$0") [OPTIONS] <source_dir> c <out.cat>

  source        Folder containing cat/dat files  OR  a single .cat file
                For 'c': the folder to pack
  command       x   — extract matched files to dest_dir
                ls  — list matched files (no extraction; dest_dir not needed)
                c   — create a cat/dat pair from a folder
  path_or_mask  Path prefix ("assets/textures") or glob mask ("assets/*.xml")
                A plain prefix matches ALL files whose path starts with it,
                even without a trailing wildcard.
                "*" matches the whole catalog; an empty mask matches NOTHING.
                For 'c': the output catalog name, which must end in '.cat'
  dest_dir      Output directory (required for 'x', ignored for 'ls' and 'c')

Options (x / ls):
  -n   Skip MD5 hash verification          (x only)
  -s   Strip the filter path prefix from output paths  (x only)
       e.g. filter "assets/textures" → file stored as "ui/foo.gz" not "assets/textures/ui/foo.gz"

Options (c):
  -i <dir>  Additional input folder; repeatable.  Files from later folders
            override files of the same name from earlier ones.
  -I <re>   Include only paths matching this regex; repeatable (OR-ed).
  -E <re>   Exclude paths matching this regex; repeatable, applied after -I.
            Both are extended regexes matched as a substring search against the
            LOWERCASED path — "^assets/" anchors, "content.xml" matches anywhere.
  -a   Append to an existing catalog instead of replacing it.

Options (all):
  -f   Force overwrite of existing files / of an existing catalog
  -v   Verbose output
  -V   Show version and exit
  -h   Show this help

Examples:
  ./$(basename "$0") /game/x4        x   assets/textures   /tmp/out
  ./$(basename "$0") /game/x4/01.cat x   "libraries/*.xml" /tmp/out
  ./$(basename "$0") /game/x4/01.cat x   "*"               /tmp/out
  ./$(basename "$0") -fv /game/x4    x   maps              /tmp/out
  ./$(basename "$0") /game/x4        ls  assets/textures
  ./$(basename "$0") /game/x4        ls  "libraries/*.xml"
  ./$(basename "$0") ./my_mod        c   ext_01.cat
  ./$(basename "$0") -v -E "^assets/" ./my_mod c ext_01.cat
  ./$(basename "$0") -I "ui/addons/ego_debuglog/ui.xml" ./my_mod c subst_01.cat

Priority rules (folder mode):
  Cat files sorted by name; entry from the highest-numbered cat wins.
  Size 0 in a higher cat = file is deleted → skipped.

Priority rules (single-cat mode):
  Only the specified cat/dat pair is used.  Size-0 entries are skipped.
EOF
    exit 1
}

# ── option parsing ─────────────────────────────────────────────────────────────
FORCE=0
SKIP_HASH=0
STRIP_PREFIX=0
VERBOSE=0
APPEND=0
EXTRA_INPUTS=()
INCLUDES=()
EXCLUDES=()

while getopts "afnsvVhi:I:E:" opt; do
    case $opt in
        a) APPEND=1 ;;
        f) FORCE=1 ;;
        n) SKIP_HASH=1 ;;
        s) STRIP_PREFIX=1 ;;
        v) VERBOSE=1 ;;
        V) printf '%s %s\n' "$(basename "$0")" "$VERSION"; exit 0 ;;
        i) EXTRA_INPUTS+=("$OPTARG") ;;
        I) INCLUDES+=("$OPTARG") ;;
        E) EXCLUDES+=("$OPTARG") ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

[[ $# -lt 3 ]] && usage

SOURCE="$1"
COMMAND="$2"
FILTER="$3"
DEST_DIR="${4:-}"

# Combine repeated -I/-E into one alternation each; empty means "no filter".
build_alt_re() {
    local out="" p
    for p in "$@"; do out="${out:+$out|}($p)"; done
    printf '%s' "$out"
}
INC_RE=""; [[ ${#INCLUDES[@]} -gt 0 ]] && INC_RE="$(build_alt_re "${INCLUDES[@]}")"
EXC_RE=""; [[ ${#EXCLUDES[@]} -gt 0 ]] && EXC_RE="$(build_alt_re "${EXCLUDES[@]}")"

# ── helpers ────────────────────────────────────────────────────────────────────
log()     { printf '%s\n' "$*" >&2; }
verbose() { [[ $VERBOSE -eq 1 ]] && printf '%s\n' "$*" >&2 || true; }
die()     { log "Error: $*"; exit 1; }

case "$COMMAND" in
    x)
        [[ -z "$DEST_DIR" ]] && { log "Error: dest_dir is required for the 'x' command."; usage; }
        ;;
    ls) ;;
    c)  ;;
    *)
        die "Unknown command '$COMMAND'. Use 'x', 'ls' or 'c'."
        ;;
esac

# ── dependency check ───────────────────────────────────────────────────────────
_needed=(awk find sort tail head date mkdir dirname)
[[ "$COMMAND" == "c" ]] && _needed+=(stat paste tr xargs mktemp sed cat wc)
[[ "$COMMAND" == "x" ]] && _needed+=(xargs mktemp wc)

_missing=()
for _cmd in "${_needed[@]}"; do
    command -v "$_cmd" &>/dev/null || _missing+=("$_cmd")
done

_md5_tool=""
if   command -v md5sum &>/dev/null; then _md5_tool="md5sum"
elif command -v md5    &>/dev/null; then _md5_tool="md5"
else _missing+=("md5sum or md5")
fi

if [[ ${#_missing[@]} -gt 0 ]]; then
    log "Error: the following required tools are missing:"
    for _t in "${_missing[@]}"; do log "  - $_t"; done
    exit 1
fi
verbose "Tools OK: ${_needed[*]} $_md5_tool"

# GNU and BSD stat disagree on how to ask for "size and mtime".
_stat_cmd=()
if [[ "$COMMAND" == "c" ]]; then
    if   stat -c '%s %Y' . &>/dev/null; then _stat_cmd=(stat -c '%s %Y')
    elif stat -f '%z %m' . &>/dev/null; then _stat_cmd=(stat -f '%z %m')
    else die "Neither GNU (stat -c) nor BSD (stat -f) stat syntax works here."
    fi
fi

# GNU dd extracts a byte range in one process; without it we fall back to
# tail|head, which costs two.
_DD_BYTES=0
if [[ "$COMMAND" == "x" ]]; then
    if command -v dd &>/dev/null &&
       dd if=/dev/null of=/dev/null bs=1 count=0 skip=0 \
          iflag=skip_bytes,count_bytes status=none 2>/dev/null; then
        _DD_BYTES=1
    fi
    verbose "Byte-range extraction: $([[ $_DD_BYTES -eq 1 ]] && echo 'dd' || echo 'tail|head')"
fi

# ── MD5 helper ─────────────────────────────────────────────────────────────────
_md5() {
    case "$_md5_tool" in
        md5sum) md5sum "$1" | awk '{print $1}' ;;
        md5)    md5 -q "$1" ;;
        *)      die "No MD5 tool available." ;;
    esac
}

# ── extraction helper ──────────────────────────────────────────────────────────
# Costs one process per file.  Directory creation and hash verification are
# batched by the caller, and the output path is precomputed, so nothing else
# here forks.  GNU dd seeks straight to the offset; the tail|head fallback is
# for systems whose dd lacks skip_bytes/count_bytes (macOS, BSD).
write_entry() {
    local dat_file="$1" out_path="$2" offset="$3" size="$4"

    if [[ $_DD_BYTES -eq 1 ]]; then
        dd if="$dat_file" of="$out_path" bs=1M status=none \
           iflag=skip_bytes,count_bytes skip="$offset" count="$size"
    else
        # tail -c +N is 1-based: byte at offset O is at position O+1.
        # Disable pipefail for this pipeline: when head exits after reading $size
        # bytes, tail gets SIGPIPE (exit 141) which would abort under pipefail.
        ( set +o pipefail; tail -c "+$(( offset + 1 ))" "$dat_file" | head -c "$size" ) > "$out_path"
    fi
}

# Verify every extracted file in one md5 process per xargs batch rather than
# one (plus an awk) per file.  Order is preserved, so results pair positionally
# with the expected hashes.
verify_batch() {
    local n=${#vf_paths[@]}
    [[ $n -eq 0 ]] && return 0

    local actual_file="$_TMP_DIR/actual_hashes"
    case "$_md5_tool" in
        md5sum) printf '%s\0' "${vf_paths[@]}" | xargs -0 md5sum \
                    | awk '{ h = $1; sub(/^\\/, "", h); print h }' > "$actual_file" ;;
        md5)    printf '%s\0' "${vf_paths[@]}" | xargs -0 md5 -q > "$actual_file" ;;
    esac

    local produced
    produced=$(( $(wc -l < "$actual_file") + 0 ))
    if [[ $produced -ne $n ]]; then
        log "  WARNING hash verification incomplete: expected $n hashes, got $produced"
        return 0
    fi

    local i=0 actual expected mismatches=0
    while IFS= read -r actual; do
        expected="${vf_hashes[$i]}"
        if [[ "${actual,,}" != "${expected,,}" ]]; then
            log "  WARNING hash mismatch for ${vf_names[$i]}"
            log "    expected : $expected"
            log "    actual   : $actual"
            (( mismatches++ )) || true
        fi
        # "|| true": (( i++ )) returns 1 when i is 0, which set -e would treat as failure.
        (( i++ )) || true
    done < "$actual_file"

    verbose "  Hashes verified: $n  mismatches: $mismatches"
    return 0
}

# ── create (pack) ──────────────────────────────────────────────────────────────
# Builds <out>.cat / <out>.dat from one or more input folders.  Everything runs
# through find/awk/sort/xargs pipelines rather than a per-file bash loop, since
# a full game folder is 450 000+ entries.
create_catalog() {
    local out_cat="$1"

    if [[ "$out_cat" != *.cat ]]; then
        die "Output '$out_cat' must end with '.cat'."
    fi
    if [[ "$out_cat" == *_sig.cat ]]; then
        die "Refusing to write a signature catalog (*_sig.cat)."
    fi
    local out_dat="${out_cat%.cat}.dat"

    local appending=0
    if [[ $APPEND -eq 1 && -f "$out_cat" && -f "$out_dat" ]]; then
        appending=1
    elif [[ $FORCE -eq 0 ]] && [[ -e "$out_cat" || -e "$out_dat" ]]; then
        die "'$out_cat' or its .dat already exists. Use -f to overwrite, or -a to append."
    fi

    mkdir -p "$(dirname "$out_cat")"

    # Global, not local: the EXIT trap fires after this function has returned.
    _TMP_DIR="$(mktemp -d)"
    trap '[[ -n "${_TMP_DIR:-}" ]] && rm -rf "$_TMP_DIR"' EXIT
    local tmp="$_TMP_DIR"

    # Input roots, one per line: line N holds root index N-1.
    local root
    : > "$tmp/roots"
    for root in "${INPUTS[@]}"; do
        root="${root%/}"
        [[ -d "$root" ]] || die "Input '$root' is not a folder."
        printf '%s\n' "$root" >> "$tmp/roots"
    done

    # Raw list "relpath <TAB> root_index", in input order so later roots win.
    # -L follows symlinks/junctions, which dev mod trees rely on.
    : > "$tmp/raw"
    local idx=0
    while IFS= read -r root; do
        verbose "Reading from folder $root"
        ( cd "$root" && find -L . -type f -print ) \
            | sed 's|^\./||' \
            | awk -v i="$idx" '{ print $0 "\t" i }' >> "$tmp/raw"
        idx=$(( idx + 1 ))
    done < "$tmp/roots"

    # Filter, fold case for the sort key, and let a later root override an
    # earlier one.  The regexes travel via the environment: passing them with
    # -v would make awk eat the backslash in "\." before it ever becomes a regex.
    INC_RE="$INC_RE" EXC_RE="$EXC_RE" awk -F'\t' '
        BEGIN { inc = ENVIRON["INC_RE"]; exc = ENVIRON["EXC_RE"] }
        {
            rel = $1
            lc  = tolower(rel)
            if (inc != "" && lc !~ inc) next
            if (exc != "" && lc ~  exc) next
            keep[lc] = rel "\t" $2
        }
        END { for (k in keep) print k "\t" keep[k] }
    ' "$tmp/raw" | LC_ALL=C sort -t$'\t' -k1,1 > "$tmp/sorted"

    local n
    n=$(wc -l < "$tmp/sorted")
    n=$(( n + 0 ))

    if [[ $n -eq 0 ]]; then
        log "Warning: no files matched — writing an empty catalog."
        if [[ $appending -eq 0 ]]; then
            : > "$out_cat"
            : > "$out_dat"
        fi
        log "────────────────────────────────────────"
        log "Catalog              : $out_cat"
        log "Entries written      : 0"
        return 0
    fi

    # Absolute source path per entry, in catalog order.
    awk -F'\t' 'NR == FNR { roots[FNR-1] = $0; next } { print roots[$3] "/" $2 }' \
        "$tmp/roots" "$tmp/sorted" > "$tmp/abs"

    # One stat/md5 process per xargs batch instead of per file.  Both preserve
    # argument order, so results are pasted back positionally — md5sum's own
    # path output is unusable, it escapes backslashes in names.
    tr '\n' '\0' < "$tmp/abs" | xargs -0 "${_stat_cmd[@]}" > "$tmp/meta"
    case "$_md5_tool" in
        md5sum) tr '\n' '\0' < "$tmp/abs" | xargs -0 md5sum \
                    | awk '{ h = $1; sub(/^\\/, "", h); print h }' > "$tmp/hash" ;;
        md5)    tr '\n' '\0' < "$tmp/abs" | xargs -0 md5 -q      > "$tmp/hash" ;;
    esac

    # A short read here would silently pair hashes with the wrong files.
    local n_meta n_hash
    n_meta=$(( $(wc -l < "$tmp/meta") + 0 ))
    n_hash=$(( $(wc -l < "$tmp/hash") + 0 ))
    if [[ $n_meta -ne $n || $n_hash -ne $n ]]; then
        die "Metadata desync: $n entries, $n_meta stat lines, $n_hash hashes."
    fi

    paste "$tmp/sorted" "$tmp/abs" "$tmp/meta" "$tmp/hash" \
      | awk -F'\t' \
            -v verbose_mode="$VERBOSE" \
            -v blockfile="$tmp/catblock" \
            -v listfile="$tmp/datlist" '
        BEGIN { zero = "00000000000000000000000000000000" }
        {
            rel = $2; abs = $4; hash = $6
            split($5, m, " ")
            size = m[1]; mtime = m[2]

            # A zero-byte file is stored with a zero hash, never md5("").
            if (size + 0 == 0) hash = zero

            print rel " " size " " mtime " " hash > blockfile
            if (size + 0 > 0) print abs > listfile
            if (verbose_mode) printf "%12s %s %s\n", size, mtime, rel > "/dev/stderr"
        }
    '

    if [[ $appending -eq 1 ]]; then
        log "Appending to catalog $out_cat"
        cat "$tmp/catblock" >> "$out_cat"
    else
        log "Writing catalog $out_cat"
        cat "$tmp/catblock" > "$out_cat"
        : > "$out_dat"
    fi

    # Guarded: "xargs cat" with no input would read stdin and hang.
    if [[ -s "$tmp/datlist" ]]; then
        tr '\n' '\0' < "$tmp/datlist" | xargs -0 cat >> "$out_dat"
    fi

    log "────────────────────────────────────────"
    log "Catalog              : $out_cat"
    log "Entries written      : $n"
    log "Data size            : $(wc -c < "$out_dat" | tr -d ' ') bytes"
    return 0
}

if [[ "$COMMAND" == "c" ]]; then
    INPUTS=("$SOURCE")
    [[ ${#EXTRA_INPUTS[@]} -gt 0 ]] && INPUTS+=("${EXTRA_INPUTS[@]}")
    [[ -n "$INC_RE" ]] && log "Include : $INC_RE"
    [[ -n "$EXC_RE" ]] && log "Exclude : $EXC_RE"
    create_catalog "$FILTER"
    exit 0
fi

# ── collect cat files ──────────────────────────────────────────────────────────
cat_files=()

if [[ -f "$SOURCE" && "$SOURCE" == *.cat ]]; then
    [[ "$SOURCE" == *_sig.cat ]] && die "Signature catalog files (*_sig.cat) are not supported as input."
    cat_files=("$SOURCE")
    log "Mode: single catalog file"
elif [[ -d "$SOURCE" ]]; then
    while IFS= read -r f; do
        cat_files+=("$f")
    done < <(find "$SOURCE" -maxdepth 1 -name "*.cat" ! -name "*_sig.cat" -print | sort)
    log "Mode: folder  (${#cat_files[@]} catalog file(s) found)"
else
    die "Source '$SOURCE' is neither a folder nor a .cat file."
fi

[[ ${#cat_files[@]} -eq 0 ]] && die "No .cat files found at '$SOURCE'."

# ── normalise filter ───────────────────────────────────────────────────────────
FILTER="${FILTER//\\//}"   # backslashes → forward slashes
FILTER="${FILTER#./}"
FILTER="${FILTER#/}"
FILTER="${FILTER%/}"       # strip trailing slash — "assets/" == "assets" (prefix match)

log "Filter  : $FILTER"
[[ "$COMMAND" == "x" ]] && log "Dest    : $DEST_DIR"

# Build awk-compatible filter expression.
# Glob-to-ERE conversion done in awk itself to avoid sed escape issues.
# If the glob contains no '/', it is treated as a filename-only pattern and
# matched against the basename of each catalog entry (e.g. "0001*.xml" matches
# "t/0001-L044.xml").  A glob with '/' is matched against the full path.
if [[ "$FILTER" == *'*'* || "$FILTER" == *'?'* ]]; then
    AWK_FILTER_TYPE="glob"
    # Pass the raw glob to awk; awk will convert it to ERE internally.
    AWK_FILTER_GLOB="$FILTER"
    # Filename-only glob when no directory separator present
    [[ "$FILTER" == *'/'* ]] && AWK_GLOB_SCOPE="path" || AWK_GLOB_SCOPE="name"
else
    AWK_FILTER_TYPE="prefix"
    AWK_FILTER_GLOB=""
    AWK_GLOB_SCOPE="path"
fi

[[ "$COMMAND" == "x" ]] && mkdir -p "$DEST_DIR"

# ── catalog merge + filter (entirely in awk) ───────────────────────────────────
#
# All cat files are passed to a single awk invocation in sorted order.
# awk builds a merged catalog dict (later files override earlier ones),
# then outputs only the entries matching the filter.
#
# Output format (TSV): filepath <TAB> dat_file <TAB> offset <TAB> size <TAB> hash <TAB> ts
# Sorted by filepath via the shell pipeline.
#
# This processes 400 000+ entries in awk native speed without any bash loop overhead.

matched_entries=$(awk \
    -v filter_type="$AWK_FILTER_TYPE" \
    -v filter_val="$FILTER" \
    -v filter_glob="$AWK_FILTER_GLOB" \
    -v glob_scope="$AWK_GLOB_SCOPE" \
    -v verbose_mode="$VERBOSE" \
    '
    # Convert a shell glob pattern to an awk ERE string
    function glob_to_ere(g,    ere, i, c) {
        ere = ""
        for (i = 1; i <= length(g); i++) {
            c = substr(g, i, 1)
            if      (c == "*") ere = ere ".*"
            else if (c == "?") ere = ere "."
            else if (c ~ /[.^$\[\]()+{}|\\]/) ere = ere "\\" c
            else               ere = ere c
        }
        return "^" ere "$"
    }

    BEGIN {
        if (filter_type == "glob")
            glob_ere = glob_to_ere(filter_glob)
    }

    FNR == 1 {
        dat = FILENAME
        sub(/\.cat$/, ".dat", dat)
        cum_offset = 0
        if (verbose_mode) print "Parsing: " FILENAME > "/dev/stderr"
    }

    /^[[:space:]]*$/ { next }

    {
        hash = $NF; ts = $(NF-1); size_str = $(NF-2)

        if (size_str !~ /^[0-9]+$/ || ts !~ /^[0-9]+$/ || hash !~ /^[0-9a-fA-F]{32}$/) {
            print "Warning: malformed line in " FILENAME ": " $0 > "/dev/stderr"
            next
        }

        size = size_str + 0

        fp = ""
        for (i = 1; i <= NF-3; i++) fp = (i == 1) ? $i : fp " " $i

        gsub(/\\/, "/", fp)
        sub(/^\.\//, "", fp)
        sub(/^\//, "", fp)

        catalog[fp] = dat "\t" cum_offset "\t" size "\t" hash "\t" ts
        cum_offset += size
    }

    END {
        total = length(catalog)
        matched = 0

        for (fp in catalog) {
            split(catalog[fp], a, "\t")
            dat = a[1]; off = a[2]; sz = a[3] + 0; hash = a[4]; ts = a[5]

            if (filter_type == "glob") {
                # Match against full path or basename depending on glob_scope
                target = (glob_scope == "name") ? substr(fp, index(fp, "/") ? length(fp) - length(fp) + 1 : 1) : fp
                # Extract basename: everything after the last /
                if (glob_scope == "name") {
                    n = split(fp, parts, "/")
                    target = parts[n]
                }
                if (target !~ glob_ere) continue
            } else {
                if (fp != filter_val && index(fp, filter_val "/") != 1) continue
            }

            matched++
            print fp "\t" dat "\t" off "\t" sz "\t" hash "\t" ts
        }

        print "Catalog entries: " total "  matched: " matched > "/dev/stderr"
    }
    ' "${cat_files[@]}" | sort
)

# ── ls ─────────────────────────────────────────────────────────────────────────
if [[ "$COMMAND" == "ls" ]]; then
    if [[ ${#cat_files[@]} -gt 1 ]]; then
        printf "%-12s  %-19s  %-12s  %s\n" "SIZE" "DATE" "CAT" "PATH"
        printf "%-12s  %-19s  %-12s  %s\n" "------------" "-------------------" "------------" "----"
    else
        printf "%-12s  %-19s  %s\n" "SIZE" "DATE" "PATH"
        printf "%-12s  %-19s  %s\n" "------------" "-------------------" "----"
    fi

    listed=0
    while IFS=$'\t' read -r filepath dat_file offset size hash ts; do
        [[ -z "$filepath" ]] && continue

        date_str=""
        if [[ -n "$ts" && "$ts" != "0" ]]; then
            date_str=$(date -d "@${ts}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
                     || date -r "${ts}"  '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
                     || printf '%s' "$ts")
        fi
        if [[ ${#cat_files[@]} -gt 1 ]]; then
            # Derive cat filename: replace .dat extension with .cat, take basename
            cat_name="${dat_file##*/}"
            cat_name="${cat_name%.dat}.cat"
            if [[ "$size" -eq 0 ]]; then
                printf "%-12s  %-19s  %-12s  %s\n" "[deleted]" "$date_str" "$cat_name" "$filepath"
            else
                printf "%12d  %-19s  %-12s  %s\n" "$size" "$date_str" "$cat_name" "$filepath"
            fi
        else
            if [[ "$size" -eq 0 ]]; then
                printf "%-12s  %-19s  %s\n" "[deleted]" "$date_str" "$filepath"
            else
                printf "%12d  %-19s  %s\n" "$size" "$date_str" "$filepath"
            fi
        fi
        (( listed++ )) || true
    done <<< "$matched_entries"

    log "────────────────────────────────────────"
    log "Listed               : $listed"
    exit 0
fi

# ── extract ────────────────────────────────────────────────────────────────────
# Three phases, so a file costs one process instead of roughly seven:
#   1. plan   — a fork-free scan that resolves output paths and collects the
#               directory set (path handling is bash builtins, not dirname)
#   2. mkdir  — every directory created in one batched call
#   3. write  — one dd per file, then hashes verified in batches
extracted=0
deleted=0
skipped=0

ex_names=(); ex_dats=(); ex_paths=(); ex_offsets=(); ex_sizes=()
vf_names=(); vf_paths=(); vf_hashes=()
declare -A ex_dirs=()

while IFS=$'\t' read -r filepath dat_file offset size hash ts; do
    [[ -z "$filepath" ]] && continue

    if [[ "$size" -eq 0 ]]; then
        verbose "  Deleted/empty (size=0): $filepath"
        (( deleted++ )) || true
        continue
    fi

    # Optionally strip the filter prefix from the output path
    out_rel="$filepath"
    if [[ $STRIP_PREFIX -eq 1 && -n "$FILTER" && "$out_rel" == "$FILTER"* ]]; then
        out_rel="${out_rel#$FILTER}"
        out_rel="${out_rel#/}"
    fi
    out_path="$DEST_DIR/$out_rel"

    if [[ -f "$out_path" && $FORCE -eq 0 ]]; then
        verbose "  Skip (exists): $filepath"
        (( skipped++ )) || true
        continue
    fi

    ex_names+=("$filepath")
    ex_dats+=("$dat_file")
    ex_paths+=("$out_path")
    ex_offsets+=("$offset")
    ex_sizes+=("$size")
    ex_dirs["${out_path%/*}"]=1

    if [[ $SKIP_HASH -eq 0 && -n "$hash" ]]; then
        vf_names+=("$filepath")
        vf_paths+=("$out_path")
        vf_hashes+=("$hash")
    fi
done <<< "$matched_entries"

extracted=${#ex_paths[@]}

if [[ $extracted -gt 0 ]]; then
    _TMP_DIR="$(mktemp -d)"
    trap '[[ -n "${_TMP_DIR:-}" ]] && rm -rf "$_TMP_DIR"' EXIT

    printf '%s\0' "${!ex_dirs[@]}" | xargs -0 mkdir -p

    for (( i = 0; i < extracted; i++ )); do
        if [[ $VERBOSE -eq 1 ]]; then
            log "  Extract: ${ex_names[i]} -> ${ex_paths[i]#$DEST_DIR/}  (dat=${ex_dats[i]##*/}  off=${ex_offsets[i]}  sz=${ex_sizes[i]})"
        elif [[ "${ex_paths[i]}" != "$DEST_DIR/${ex_names[i]}" ]]; then
            log "  Extract: ${ex_names[i]} -> ${ex_paths[i]#$DEST_DIR/}"
        else
            log "  Extract: ${ex_names[i]}"
        fi

        write_entry "${ex_dats[i]}" "${ex_paths[i]}" "${ex_offsets[i]}" "${ex_sizes[i]}"
    done

    verify_batch
fi

log "────────────────────────────────────────"
log "Extracted            : $extracted"
log "Deleted/empty (sz=0) : $deleted"
log "Skipped (exists)     : $skipped"