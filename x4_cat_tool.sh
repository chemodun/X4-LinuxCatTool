#!/usr/bin/env bash
# x4_cat_tool.sh — Extract / list files from X4 Foundations cat/dat archives
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

set -euo pipefail

# ── usage ─────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] <source> <command> <path_or_mask> [<dest_dir>]

  source        Folder containing cat/dat files  OR  a single .cat file
  command       x   — extract matched files to dest_dir
                ls  — list matched files (no extraction; dest_dir not needed)
  path_or_mask  Path prefix ("assets/textures") or glob mask ("assets/*.xml")
                A plain prefix matches ALL files whose path starts with it,
                even without a trailing wildcard.
  dest_dir      Output directory (required for 'x', ignored for 'ls')

Options:
  -f   Force overwrite of existing files  (x only)
  -n   Skip MD5 hash verification          (x only)
  -s   Strip the filter path prefix from output paths  (x only)
       e.g. filter "assets/textures" → file stored as "ui/foo.gz" not "assets/textures/ui/foo.gz"
  -v   Verbose output
  -h   Show this help

Examples:
  $(basename "$0") /game/x4        x   assets/textures   /tmp/out
  $(basename "$0") /game/x4/01.cat x   "libraries/*.xml" /tmp/out
  $(basename "$0") -fv /game/x4    x   maps              /tmp/out
  $(basename "$0") /game/x4        ls  assets/textures
  $(basename "$0") /game/x4        ls  "libraries/*.xml"

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

while getopts "fnsvh" opt; do
    case $opt in
        f) FORCE=1 ;;
        n) SKIP_HASH=1 ;;
        s) STRIP_PREFIX=1 ;;
        v) VERBOSE=1 ;;
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

# ── helpers ────────────────────────────────────────────────────────────────────
log()     { printf '%s\n' "$*" >&2; }
verbose() { [[ $VERBOSE -eq 1 ]] && printf '%s\n' "$*" >&2 || true; }
die()     { log "Error: $*"; exit 1; }

case "$COMMAND" in
    x)
        [[ -z "$DEST_DIR" ]] && { log "Error: dest_dir is required for the 'x' command."; usage; }
        ;;
    ls) ;;
    *)
        die "Unknown command '$COMMAND'. Use 'x' or 'ls'."
        ;;
esac

# ── dependency check ───────────────────────────────────────────────────────────
_missing=()
for _cmd in awk find sort tail head date mkdir dirname; do
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
verbose "Tools OK: awk find sort tail head date mkdir dirname $_md5_tool"

# ── MD5 helper ─────────────────────────────────────────────────────────────────
_md5() {
    case "$_md5_tool" in
        md5sum) md5sum "$1" | awk '{print $1}' ;;
        md5)    md5 -q "$1" ;;
        *)      die "No MD5 tool available." ;;
    esac
}

# ── extraction helper ──────────────────────────────────────────────────────────
extract_entry() {
    local filepath="$1"
    local dat_file="$2"
    local offset="$3"
    local size="$4"
    local hash="$5"

    # Optionally strip the filter prefix from the output path
    local out_rel="$filepath"
    if [[ $STRIP_PREFIX -eq 1 && -n "$FILTER" && "$out_rel" == "$FILTER"* ]]; then
        out_rel="${out_rel#$FILTER}"
        out_rel="${out_rel#/}"
    fi

    local out_path="$DEST_DIR/$out_rel"

    mkdir -p "$(dirname "$out_path")"

    if [[ $VERBOSE -eq 1 ]]; then
        log "  Extract: $filepath -> $out_rel  (dat=$(basename "$dat_file")  off=$offset  sz=$size)"
    elif [[ "$out_rel" != "$filepath" ]]; then
        log "  Extract: $filepath -> $out_rel"
    else
        log "  Extract: $filepath"
    fi

    # tail -c +N is 1-based: byte at offset O is at position O+1.
    # Disable pipefail for this pipeline: when head exits after reading $size bytes,
    # tail gets SIGPIPE (exit 141) which would abort the script under set -o pipefail.
    ( set +o pipefail; tail -c "+$(( offset + 1 ))" "$dat_file" | head -c "$size" ) > "$out_path"

    if [[ $SKIP_HASH -eq 0 && -n "$hash" ]]; then
        local actual
        actual="$(_md5 "$out_path")"
        if [[ "${actual,,}" != "${hash,,}" ]]; then
            log "  WARNING hash mismatch for $filepath"
            log "    expected : $hash"
            log "    actual   : $actual"
        else
            verbose "  Hash OK: $filepath"
        fi
    fi
}

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

# ── ls / extract loop ──────────────────────────────────────────────────────────
if [[ "$COMMAND" == "ls" ]]; then
    if [[ ${#cat_files[@]} -gt 1 ]]; then
        printf "%-12s  %-19s  %-12s  %s\n" "SIZE" "DATE" "CAT" "PATH"
        printf "%-12s  %-19s  %-12s  %s\n" "------------" "-------------------" "------------" "----"
    else
        printf "%-12s  %-19s  %s\n" "SIZE" "DATE" "PATH"
        printf "%-12s  %-19s  %s\n" "------------" "-------------------" "----"
    fi
fi

extracted=0
deleted=0
skipped=0
listed=0

while IFS=$'\t' read -r filepath dat_file offset size hash ts; do
    [[ -z "$filepath" ]] && continue

    if [[ "$COMMAND" == "ls" ]]; then
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
        continue
    fi

    if [[ "$size" -eq 0 ]]; then
        verbose "  Deleted/empty (size=0): $filepath"
        (( deleted++ )) || true
        continue
    fi

    if [[ -f "$DEST_DIR/$filepath" && $FORCE -eq 0 ]]; then
        verbose "  Skip (exists): $filepath"
        (( skipped++ )) || true
        continue
    fi

    extract_entry "$filepath" "$dat_file" "$offset" "$size" "$hash"
    (( extracted++ )) || true
done <<< "$matched_entries"

log "────────────────────────────────────────"
if [[ "$COMMAND" == "ls" ]]; then
    log "Listed               : $listed"
else
    log "Extracted            : $extracted"
    log "Deleted/empty (sz=0) : $deleted"
    log "Skipped (exists)     : $skipped"
fi