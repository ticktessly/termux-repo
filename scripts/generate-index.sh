#!/usr/bin/env bash
#
# Generates the GitHub Pages landing page (site/index.html) from the APT
# repository metadata that was just built into dists/.
#
# The page is derived from the real Packages files rather than hand-written,
# so it can never drift from what is actually published.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_DIR"

DIST="stable"
COMP="main"
OUT_DIR="site"
REPO_URL="https://ticktessly.github.io/termux-repo"

[ -d "dists/${DIST}/${COMP}" ] || {
    echo "generate-index: dists/${DIST}/${COMP} not found; skipping." >&2
    exit 0
}

mkdir -p "$OUT_DIR"

# ---------------------------------------------------------------------------
# Parse the Packages files into TSV records.
#
# One record per package/arch stanza:
#   name  version  arch  description  homepage  depends  filename  size
#
# The Description field is multi-line; only its first line is used (that is
# the short description), continuation lines are dropped.
# ---------------------------------------------------------------------------
parse_packages() {
    awk -v FS='' '
        function flush(   out) {
            if (name != "") {
                printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
                    name, version, arch, desc, homepage, depends, filename, size
            }
            name = version = arch = desc = homepage = depends = filename = size = ""
            cur = ""
        }
        /^\r$/ { flush(); next }
        /^$/ { flush(); cur = ""; next }
        /^[A-Za-z0-9][A-Za-z0-9-]*:/ {
            key = $0
            sub(/:.*$/, "", key)
            val = $0
            sub(/^[^:]*:[ \t]?/, "", val)
            cur = key
            if (key == "Package") name = val
            else if (key == "Version") version = val
            else if (key == "Architecture") arch = val
            else if (key == "Homepage") homepage = val
            else if (key == "Depends") depends = val
            else if (key == "Filename") filename = val
            else if (key == "Size") size = val
            else if (key == "Description" && desc == "") desc = val
            next
        }
        # Continuation line: only used to complete a short description.
        {
            if (cur == "Description" && desc == "") {
                line = $0
                sub(/^[ \t]+/, "", line)
                desc = line
            }
        }
        END { flush() }
    ' "$@"
}

TSV="$(mktemp)"
trap 'rm -f "$TSV"' EXIT

for pkg_file in dists/"${DIST}"/"${COMP}"/binary-*/Packages; do
    [ -f "$pkg_file" ] || continue
    parse_packages "$pkg_file" >> "$TSV"
done

if [ ! -s "$TSV" ]; then
    echo "generate-index: no package metadata found; skipping." >&2
    exit 0
fi

# ---------------------------------------------------------------------------
# Collapse the per-arch stanzas into one row per package name, preferring the
# most specific architecture available (aarch64 > x86_64 > all).
# ---------------------------------------------------------------------------
arch_rank() {
    case "$1" in
        aarch64) echo 0 ;;
        x86_64)  echo 1 ;;
        all)     echo 2 ;;
        *)       echo 3 ;;
    esac
}

ROWS="$(awk -F'\t' '
    function rank(a) {
        if (a == "aarch64") return 0
        if (a == "x86_64")  return 1
        if (a == "all")     return 2
        return 3
    }
    {
        name = $1
        if (!(name in best) || rank($3) < rank(best[name])) {
            best[name] = $3
            ver[name]  = $2
            desc[name] = $4
            home[name] = $5
            dep[name]  = $6
            file[name] = $7
            size[name] = $8
        }
    }
    END {
        for (n in best) printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
            n, ver[n], best[n], desc[n], home[n], dep[n], size[n]
    }
' "$TSV" | sort)"

# ---------------------------------------------------------------------------
# Render the table rows.
# ---------------------------------------------------------------------------
html_escape() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

fmt_size() {
    awk -v b="$1" 'BEGIN {
        if (b == "" || b + 0 <= 0) { print "-"; exit }
        if (b >= 1048576) printf "%.1f MB", b / 1048576
        else if (b >= 1024) printf "%.0f KB", b / 1024
        else print b " B"
    }'
}

TABLE_ROWS=""
while IFS=$'\t' read -r name ver arch desc home dep size; do
    [ -n "$name" ] || continue
    name_h=$(printf '%s' "$name" | html_escape)
    ver_h=$(printf '%s' "$ver" | html_escape)
    arch_h=$(printf '%s' "$arch" | html_escape)
    desc_h=$(printf '%s' "$desc" | html_escape)
    dep_h=$(printf '%s' "$dep" | html_escape)
    size_h=$(fmt_size "$size")

    if [ -n "$home" ]; then
        home_h=$(printf '%s' "$home" | html_escape)
        home_cell="<a href=\"${home_h}\" rel=\"noopener\" target=\"_blank\">${home_h}</a>"
    else
        home_cell="<span class=\"muted\">—</span>"
    fi

    if [ -n "$dep" ]; then
        dep_cell="<code>${dep_h}</code>"
    else
        dep_cell="<span class=\"muted\">—</span>"
    fi

    TABLE_ROWS+="      <tr>
        <td class=\"name\"><code>${name_h}</code></td>
        <td>${ver_h}</td>
        <td><span class=\"arch\">${arch_h}</span></td>
        <td class=\"desc\">${desc_h}</td>
        <td class=\"deps\">${dep_cell}</td>
        <td>${home_cell}</td>
        <td class=\"size\">${size_h}</td>
      </tr>
"
done <<< "$ROWS"

PKG_COUNT=$(printf '%s\n' "$ROWS" | grep -c . || true)
ARCH_LIST=$(ls -d dists/"${DIST}"/"${COMP}"/binary-* 2>/dev/null \
    | xargs -I{} basename {} | sed 's/binary-//' | sort | tr '\n' ' ')
UPDATED="$(date -u '+%Y-%m-%d %H:%M UTC')"

# Documentation pages are published alongside the landing page.
DOC_LINKS=""
for doc in README.md DNS_FORWARDING.md PACKAGE_RESEARCH.md; do
    [ -f "$doc" ] || continue
    case "$doc" in
        README.md)          title="README" ;;
        DNS_FORWARDING.md)  title="DNS Forwarding & Caching Guide" ;;
        PACKAGE_RESEARCH.md) title="Package Research & Architecture" ;;
    esac
    DOC_LINKS+="      <li><a href=\"${doc}\">${title}</a> <span class=\"muted\">.md</span></li>
"
done

cat > "$OUT_DIR/index.html" <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>ticktessly's Termux Repository</title>
<meta name="description" content="Custom APT repository for Termux with packages not available in the official repos.">
<style>
  :root {
    --bg: #0d1117;
    --panel: #161b22;
    --border: #30363d;
    --text: #e6edf3;
    --muted: #8b949e;
    --accent: #58a6ff;
    --green: #3fb950;
    --code-bg: #010409;
  }
  @media (prefers-color-scheme: light) {
    :root {
      --bg: #ffffff; --panel: #f6f8fa; --border: #d0d7de;
      --text: #1f2328; --muted: #59636e; --accent: #0969da;
      --green: #1a7f37; --code-bg: #f6f8fa;
    }
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; padding: 0 1rem 4rem;
    background: var(--bg); color: var(--text);
    font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
  }
  .wrap { max-width: 1080px; margin: 0 auto; }
  header { padding: 3rem 0 1.5rem; border-bottom: 1px solid var(--border); }
  h1 { margin: 0 0 .5rem; font-size: 2.1rem; letter-spacing: -.02em; }
  h2 { margin: 2.5rem 0 1rem; font-size: 1.3rem; letter-spacing: -.01em; }
  p.lead { margin: 0; color: var(--muted); font-size: 1.05rem; }
  a { color: var(--accent); text-decoration: none; }
  a:hover { text-decoration: underline; }
  code {
    font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
    font-size: .875em;
  }
  p code, li code, td code {
    background: var(--code-bg); border: 1px solid var(--border);
    border-radius: 5px; padding: .15em .4em;
  }
  pre {
    background: var(--code-bg); border: 1px solid var(--border);
    border-radius: 8px; padding: 1rem 1.15rem; overflow-x: auto;
  }
  pre code { background: none; border: 0; padding: 0; font-size: .875rem; }
  .panel {
    background: var(--panel); border: 1px solid var(--border);
    border-radius: 10px; padding: 1.25rem 1.5rem;
  }
  .install { margin-top: 1.5rem; }
  .steps { counter-reset: step; list-style: none; padding-left: 0; }
  .steps li { position: relative; padding-left: 2.25rem; margin-bottom: 1.25rem; }
  .steps li::before {
    counter-increment: step; content: counter(step);
    position: absolute; left: 0; top: .1rem;
    width: 1.5rem; height: 1.5rem; border-radius: 50%;
    background: var(--green); color: #fff;
    font-size: .8rem; font-weight: 700; line-height: 1.5rem; text-align: center;
  }
  .steps h3 { margin: 0 0 .35rem; font-size: 1rem; }
  .steps p { margin: 0; color: var(--muted); font-size: .95rem; }
  table { width: 100%; border-collapse: collapse; margin-top: .5rem; font-size: .9rem; }
  th, td { text-align: left; padding: .7rem .75rem; border-bottom: 1px solid var(--border); vertical-align: top; }
  th { color: var(--muted); font-weight: 600; font-size: .8rem; text-transform: uppercase; letter-spacing: .04em; }
  tbody tr:hover { background: var(--panel); }
  td.name { white-space: nowrap; }
  td.desc { color: var(--text); }
  td.deps { color: var(--muted); max-width: 22rem; }
  td.deps code { white-space: normal; }
  td.size { white-space: nowrap; text-align: right; color: var(--muted); }
  .arch {
    display: inline-block; padding: .1rem .45rem; border-radius: 999px;
    border: 1px solid var(--border); color: var(--muted); font-size: .75rem;
  }
  .muted { color: var(--muted); }
  ul.docs { list-style: none; padding-left: 0; }
  ul.docs li { padding: .35rem 0; }
  .meta { margin-top: 3rem; padding-top: 1.25rem; border-top: 1px solid var(--border); color: var(--muted); font-size: .85rem; }
  .meta a { color: var(--muted); text-decoration: underline; }
  @media (max-width: 720px) {
    h1 { font-size: 1.6rem; }
    .table-scroll { overflow-x: auto; }
  }
</style>
</head>
<body>
<div class="wrap">
  <header>
    <h1>ticktessly's Termux Repository</h1>
    <p class="lead">Custom APT repository for Termux with packages not available in the official repos.</p>
  </header>

  <h2>Quick install</h2>
  <div class="panel install">
    <pre><code>curl -sL ${REPO_URL}/install.sh | bash</code></pre>
    <p class="muted">This adds the repository to <code>\$PREFIX/etc/apt/sources.list.d/</code> and runs <code>pkg update</code>.</p>
  </div>

  <h2>Manual install</h2>
  <ol class="steps">
    <li>
      <h3>Add the repository source</h3>
      <p>Create <code>\$PREFIX/etc/apt/sources.list.d/ticktessly-repo.list</code> containing:</p>
      <pre><code>deb [trusted=yes] ${REPO_URL} stable main</code></pre>
    </li>
    <li>
      <h3>Refresh the package lists</h3>
      <pre><code>pkg update -y</code></pre>
    </li>
    <li>
      <h3>Install a package</h3>
      <pre><code>pkg install opencode</code></pre>
    </li>
  </ol>

  <h2>Available packages <span class="muted">(${PKG_COUNT})</span></h2>
  <div class="table-scroll">
  <table>
    <thead>
      <tr><th>Package</th><th>Version</th><th>Arch</th><th>Description</th><th>Depends</th><th>Homepage</th><th>Size</th></tr>
    </thead>
    <tbody>
${TABLE_ROWS}    </tbody>
  </table>
  </div>

  <h2>Notes</h2>
  <div class="panel">
    <ul>
      <li><code>opencode</code>, <code>antigravity-cli</code>, <code>oh-my-pi</code> and <code>copilot-cli</code> require <code>glibc-repo</code> and <code>glibc</code> &mdash; install with <code>pkg install glibc-repo</code>.</li>
      <li><code>copilot-cli</code> downloads the official glibc binary from GitHub releases at install time and verifies its checksum; it is not redistributed here.</li>
      <li><code>muse-code</code> requires <code>proot</code> for syscall emulation.</li>
      <li>Architectures published: ${ARCH_LIST}</li>
    </ul>
  </div>

  <h2>Documentation</h2>
  <ul class="docs">
${DOC_LINKS}  </ul>

  <div class="meta">
    Last updated ${UPDATED} &middot;
    <a href="https://github.com/ticktessly/termux-repo">Source on GitHub</a> &middot;
    <a href="${REPO_URL}/dists/stable/Release">Release file</a>
  </div>
</div>
</body>
</html>
HTML

echo "Generated ${OUT_DIR}/index.html (${PKG_COUNT} packages)"
