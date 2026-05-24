"""tests/test_sanitize_svg.py — Tests for the _sanitize_svg function in puppet-trace.

Extracts _sanitize_svg from the puppet-trace script using regex and exec()s it
in the test context, then validates each security property.

Run: pytest tests/test_sanitize_svg.py -v
"""
import re
import sys
from pathlib import Path

# ── Extract _sanitize_svg from the script ─────────────────────────────────────

SCRIPT_PATH = Path(__file__).parent.parent / "scripts" / "puppet-trace"


def _extract_sanitize_svg(script_path: Path) -> str:
    """Extract the _sanitize_svg function body from the puppet-trace script.

    The script contains two copies (one in _generate_collect_report, one in
    generate_report).  Both should be identical after the H2 fix. We take the
    first match.
    """
    text = script_path.read_text()
    # Match: optional 'import re as _re' line, then def _sanitize_svg...return s
    # We need the full function including the import alias.
    pattern = re.compile(
        r'(import re as _re\s+)?'
        r'(def _sanitize_svg\(s\):.*?return s)',
        re.DOTALL,
    )
    m = pattern.search(text)
    if not m:
        raise RuntimeError(f"Could not find _sanitize_svg in {script_path}")
    return m.group(0)


# Build a module namespace containing _sanitize_svg
_NS: dict = {}
_func_src = _extract_sanitize_svg(SCRIPT_PATH)
# Ensure 're' alias is available in the namespace
exec("import re as _re\n" + _func_src, _NS)  # noqa: S102
_sanitize_svg = _NS["_sanitize_svg"]


# ── Tests ──────────────────────────────────────────────────────────────────────


def test_script_found():
    """Sanity check that the script file exists."""
    assert SCRIPT_PATH.exists(), f"puppet-trace script not found at {SCRIPT_PATH}"


def test_function_extracted():
    """Ensure the function was extracted successfully."""
    assert callable(_sanitize_svg), "_sanitize_svg was not extracted as a callable"


def test_script_block_stripped():
    """<script>alert(1)</script> is removed entirely."""
    dirty = '<svg><script>alert(1)</script><text>ok</text></svg>'
    result = _sanitize_svg(dirty)
    assert '<script>' not in result.lower()
    assert 'alert(1)' not in result
    assert '<text>ok</text>' in result  # safe content preserved


def test_unclosed_script_tag_stripped():
    """<script src="http://evil.com/x.js"> with no closing tag is stripped."""
    dirty = '<svg><script src="http://evil.com/x.js"><text>safe</text></svg>'
    result = _sanitize_svg(dirty)
    assert 'evil.com' not in result
    assert '<script' not in result.lower()


def test_self_closing_script_stripped():
    """<script/> self-closing variant is stripped."""
    dirty = '<svg><script src="evil.js"/><text>safe</text></svg>'
    result = _sanitize_svg(dirty)
    assert '<script' not in result.lower()
    assert '<text>safe</text>' in result


def test_javascript_href_neutralized():
    """xlink:href="javascript:alert(1)" has the javascript: scheme neutralized."""
    dirty = '<svg><a xlink:href="javascript:alert(1)">click</a></svg>'
    result = _sanitize_svg(dirty)
    assert 'javascript:' not in result.lower()
    # href should start with '#' (scheme replaced; rest of value may remain)
    assert 'href="#' in result or "href='#" in result


def test_plain_href_javascript_neutralized():
    """href="javascript:void(0)" (without xlink:) is replaced with '#'."""
    dirty = '<svg><a href="javascript:void(0)">click</a></svg>'
    result = _sanitize_svg(dirty)
    assert 'javascript:' not in result.lower()


def test_onclick_event_handler_stripped():
    """onclick="alert(1)" event handler is removed."""
    dirty = '<svg><rect onclick="alert(1)" width="100" height="100"/></svg>'
    result = _sanitize_svg(dirty)
    assert 'onclick' not in result.lower()
    assert 'alert(1)' not in result
    # The rect element structure should still be present
    assert '<rect' in result


def test_onmouseover_event_handler_stripped():
    """onmouseover event handler is removed."""
    dirty = '<svg><rect onmouseover="evil()" width="50"/></svg>'
    result = _sanitize_svg(dirty)
    assert 'onmouseover' not in result.lower()
    assert 'evil()' not in result


def test_data_uri_in_href_neutralized():
    """<image href="data:text/html,<script>alert(1)</script>"> is neutralized."""
    dirty = '<svg><image href="data:text/html,&lt;script&gt;alert(1)&lt;/script&gt;" width="100"/></svg>'
    result = _sanitize_svg(dirty)
    assert 'data:' not in result.lower() or 'href="#"' in result or "href='#'" in result


def test_data_uri_in_src_neutralized():
    """src="data:..." URI is replaced with '#'."""
    dirty = '<svg><image src="data:image/svg+xml,<svg><script>evil()</script></svg>"/></svg>'
    result = _sanitize_svg(dirty)
    # data: URI in src should be removed
    assert 'data:' not in result.lower() or 'src="#"' in result or "src='#'" in result


def test_clean_flamegraph_svg_passthrough():
    """A normal flamegraph SVG is not corrupted by the sanitizer."""
    clean_svg = '''<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"
     width="900" height="400" viewBox="0 0 900 400">
  <defs>
    <linearGradient id="bg" y1="0" y2="1" x1="0" x2="0">
      <stop stop-color="#eeeeee" offset="5%"/>
      <stop stop-color="#eeeeb0" offset="95%"/>
    </linearGradient>
  </defs>
  <rect width="900" height="400" fill="url(#bg)"/>
  <text x="450" y="20" text-anchor="middle" font-family="Verdana" font-size="17">
    Puppet Catalog Compilation
  </text>
  <g id="frames">
    <rect x="10" y="100" width="200" height="20" fill="#e8603c">
      <title>Puppet::Resource::Catalog#compile (200ms)</title>
    </rect>
    <text x="15" y="115" font-family="Verdana" font-size="12" fill="rgb(0,0,0)">
      Puppet::Resource::Catalog#compile
    </text>
  </g>
</svg>'''
    result = _sanitize_svg(clean_svg)
    # Core SVG structure must be preserved
    assert '<svg' in result
    assert 'linearGradient' in result
    assert 'Puppet Catalog Compilation' in result
    assert 'Puppet::Resource::Catalog#compile' in result
    assert 'fill="url(#bg)"' in result
    # Nothing important should be stripped
    assert '<rect' in result
    assert '<text' in result


def test_multiple_scripts_stripped():
    """Multiple <script> blocks in one SVG are all removed."""
    dirty = '<svg><script>evil1()</script><script>evil2()</script><text>safe</text></svg>'
    result = _sanitize_svg(dirty)
    assert 'evil1' not in result
    assert 'evil2' not in result
    assert '<text>safe</text>' in result


def test_case_insensitive_script():
    """<SCRIPT> in uppercase is also stripped."""
    dirty = '<svg><SCRIPT>alert("xss")</SCRIPT><text>ok</text></svg>'
    result = _sanitize_svg(dirty)
    assert 'alert' not in result
    assert '<text>ok</text>' in result


# ── N6/N7: unquoted href and animate/set elements ─────────────────────────────


def test_unquoted_href_javascript_neutralized():
    """href=javascript:alert(1) without quotes is neutralized."""
    dirty = '<a href=javascript:alert(1)>click</a>'
    result = _sanitize_svg(dirty)
    assert 'javascript:' not in result.lower()
    assert 'href=#' in result or 'href="' in result


def test_animate_element_stripped():
    """<animate> element that could animate href to javascript: is stripped."""
    dirty = '<animate attributeName="href" to="javascript:alert(1)"/>'
    result = _sanitize_svg(dirty)
    assert 'animate' not in result.lower()


def test_set_element_stripped():
    """<set> element that could set href to javascript: is stripped."""
    dirty = '<set attributeName="href" to="javascript:alert(1)"/>'
    result = _sanitize_svg(dirty)
    assert 'set attributeName' not in result


# ── N1: allowlist-based href tests ───────────────────────────────────────────


def test_entity_encoded_javascript_neutralized():
    """HTML entity-encoded javascript: scheme in href is neutralized (N1)."""
    dirty = '<a href="java&#115;cript:alert(1)">x</a>'
    result = _sanitize_svg(dirty)
    # href must not contain the dangerous URI — should be replaced with #
    assert 'java&#115;cript:' not in result
    assert 'href="#"' in result or "href='#'" in result


def test_vbscript_neutralized():
    """vbscript: href is neutralized by the allowlist approach (N1)."""
    dirty = '<a href="vbscript:msgbox(1)">x</a>'
    result = _sanitize_svg(dirty)
    assert 'vbscript:' not in result.lower()
    assert 'href="#"' in result or "href='#'" in result


def test_tab_split_javascript_neutralized():
    """Tab-split javascript: URI in href is neutralized (N1)."""
    dirty = '<a href="java\tscript:alert(1)">x</a>'
    result = _sanitize_svg(dirty)
    assert 'javascript:' not in result.lower()
    assert 'href="#"' in result or "href='#'" in result


def test_valid_https_href_preserved():
    """A valid https:// href is preserved by the allowlist (N1)."""
    dirty = '<a href="https://example.com/flame">stack</a>'
    result = _sanitize_svg(dirty)
    assert 'https://example.com/flame' in result


# ── N3 (round 5): style=url() bypass ─────────────────────────────────────────


def test_style_url_javascript_stripped():
    """style=url(javascript:) is neutralized (N3 round 5)."""
    dirty = '<rect style="fill:url(javascript:alert(1))" />'
    result = _sanitize_svg(dirty)
    assert 'javascript:' not in result


def test_style_url_data_stripped():
    """style=url(data:...) is neutralized (N3 round 5)."""
    dirty = '<rect style="fill:url(data:text/html,<script>evil()</script>)" />'
    result = _sanitize_svg(dirty)
    assert 'data:' not in result


def test_style_url_anchor_preserved():
    """style=url(#anchor) is preserved — legitimate SVG pattern (N3 round 5)."""
    clean = '<rect style="fill:url(#myGradient)" />'
    result = _sanitize_svg(clean)
    assert 'url(#myGradient)' in result


def test_style_non_url_preserved():
    """style attributes without url() are not modified (N3 round 5)."""
    clean = '<text style="font-size:12px;fill:#333">ok</text>'
    result = _sanitize_svg(clean)
    assert 'font-size:12px' in result
    assert 'fill:#333' in result
