import 'dart:ui';

import 'package:meta/meta.dart';

import 'highlight_range.dart';

/// Structured-text detection over a terminal's OWN cells (#767 Slice A).
///
/// This is the in-fork, content-anchored replacement for the app-side URL
/// detector that used to regex-scan formatter text in VIEWPORT coordinates and
/// re-push `controller.highlights` on every controller notify (the root cause
/// of the #748/#750/#751/#764 drift). Here the scanner reads the terminal's
/// authoritative cells (content + soft-wrap + wide-char width) via a
/// [CellReader], walks LOGICAL lines joined by the AUTHORITATIVE per-row wrap
/// flag, runs each [TextPattern]'s regex over the joined text, and emits
/// [HighlightRange]s DIRECTLY in ABSOLUTE buffer-row coordinates — the same
/// frame the selection model and [HighlightPainter] maintain across scroll,
/// wrap, resize, and eviction.
///
/// The [CellReader] is the headless seam: the real controller reads
/// libghostty's `GridRef`/`RenderState` (native FFI, not unit-testable), while
/// tests supply a fake reader, exactly as the old `detectGhosttyUrls` took
/// `rows`/`rowWraps` lists. The scanner + match mapping are PURE Dart, so the
/// wrap/range/eviction edge cases are unit-testable without an emulator.

/// The paint style a [TextPattern] applies to each emitted [HighlightRange].
///
/// Carries the optional background fill and underline colors onto the ranges
/// the scanner produces, so a pattern's matches render in a consistent,
/// theme-supplied color. When [background] is null the highlight painter falls
/// back to [HighlightTheme.defaultBackground]; when [underline] is null no
/// underline is drawn.
@immutable
final class HighlightStyle {
  /// Translucent fill drawn behind matched cells (null → painter default).
  final Color? background;

  /// Underline color drawn under matched cells (null → no underline).
  final Color? underline;

  const HighlightStyle({this.background, this.underline});

  @override
  int get hashCode => Object.hash(background, underline);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HighlightStyle &&
          background == other.background &&
          underline == other.underline;
}

/// The anchoring TIER of a [TextPattern] (#998 slice A).
///
/// Tiers let a BLOCK-level anchor (a whole command line) CONTAIN span-level
/// anchors (the URLs/paths inside it) with NEITHER suppressing the other:
///   * [span] — an inline token (URL, path, OSC-8 link). The default; every
///     pre-tier pattern keeps today's behavior with zero registration changes.
///   * [block] — a whole-logical-line construct (a command line, #998 B). A
///     block match may OVERLAP span matches and OSC-8 hyperlinked cells; the
///     span-tier OSC-8-wins de-dup does not apply to it.
/// Hit-testing prefers the INNERMOST tier: [StructuredTextScanner] emits both,
/// and `TerminalController.matchAt` resolves a cell covered by both tiers to
/// the span match (inline taps never route to the containing block), with the
/// block match still resolvable via `matchAt(tier: TextTier.block)`.
enum TextTier { span, block }

/// A detectable structured-text pattern (#767).
///
/// A pattern names a class of structured text (URL, path, …) with a [regex]
/// run over each logical line's joined cell text, a [style] applied to every
/// emitted range, and an optional [normalize] that maps a raw match string to
/// an opaque payload (e.g. prefixing a bare `www.` host with `https://`). When
/// [normalize] is null the raw matched string is the payload.
///
/// The built-in [TextPattern.url] reproduces the old app-side URL detector:
/// the same http/https/www regex, the same trailing-punctuation trim, and the
/// same `www.` → `https://` normalization, MOVED inward to run over cells.
@immutable
final class TextPattern {
  /// Stable identifier for this pattern, copied onto each [StructuredMatch].
  final String id;

  /// The regex run over each logical line's joined cell text.
  final RegExp regex;

  /// The paint style applied to every [HighlightRange] this pattern emits.
  final HighlightStyle style;

  /// Maps a raw match string to its payload, or null to use the raw string.
  final Object? Function(String raw)? normalize;

  /// Trailing characters trimmed off the END of a raw match before it is
  /// accepted, or empty to keep the raw match as-is. Mirrors the old
  /// detector's sentence-punctuation / unbalanced-closer trim.
  final String trailingTrim;

  /// Whether this pattern is the regex-FREE OSC-8 HYPERLINK source (#767 Slice
  /// B) rather than a [regex]-driven text matcher. When true the scanner
  /// IGNORES [regex]/[trailingTrim]/[normalize] and instead walks the reader's
  /// cells, grouping MAXIMAL runs of adjacent cells that share the SAME non-null
  /// [CellReader.hyperlinkAt] URI into one [StructuredMatch] (payload = the URI).
  /// Because libghostty attaches the full OSC-8 URI to EVERY visible cell of the
  /// link — including soft/hard-wrapped continuation rows — a wrapped link spans
  /// its rows by construction, with NO regex, width, or wrap heuristic, and the
  /// payload is the EXACT full URI (so copy/open get the real link). An OSC-8
  /// match always WINS over an overlapping [regex] match (see [StructuredTextScanner.scan]).
  final bool isOsc8Source;

  /// The anchoring tier (#998 slice A). Defaults to [TextTier.span] — every
  /// existing pattern keeps today's behavior with no registration change. A
  /// [TextTier.block] pattern (a whole command line, #998 B) may CONTAIN span
  /// matches / OSC-8 links without the span-tier de-dup suppressing it, and
  /// loses hit-test ties to any covering span match (innermost wins).
  final TextTier tier;

  /// When set, emitted ranges cover THIS capture group's span instead of the
  /// full match (#998 slice A) — e.g. a command pattern `^\$ (.+)$` with
  /// `rangeGroup: 1` anchors only the command, so the prompt stays un-anchored
  /// ink. GEOMETRY only: [normalize] still receives the FULL raw match (a
  /// command scorer needs the prompt) and produces the payload as today. An
  /// EMPTY or absent group suppresses the match (nothing to anchor).
  ///
  /// Dart's [Match] exposes no per-group offsets, so the group's span is
  /// located as the LAST occurrence of the group text within the match — exact
  /// whenever the group extends to the END of the match (the prompt-strip
  /// shape this exists for); groups repeated elsewhere in the match resolve to
  /// their final occurrence.
  final int? rangeGroup;

  const TextPattern({
    required this.id,
    required this.regex,
    this.style = const HighlightStyle(),
    this.normalize,
    this.trailingTrim = '',
    this.isOsc8Source = false,
    this.tier = TextTier.span,
    this.rangeGroup,
  });

  /// The built-in URL pattern (#726/#764 moved in-fork, #767).
  ///
  /// Matches `http://` / `https://` absolute URLs and bare `www.` hosts,
  /// trims trailing sentence punctuation / unbalanced closers, and normalizes
  /// a bare `www.` host to `https://www…`. [style] supplies the highlight
  /// color (the session theme's selection color at the call site).
  factory TextPattern.url({String id = 'url', HighlightStyle style =
      const HighlightStyle()}) {
    return TextPattern(
      id: id,
      regex: _kUrlPattern,
      style: style,
      trailingTrim: _kUrlTrailingTrim,
      normalize: _normalizeUrl,
    );
  }

  /// The built-in ABSOLUTE FILE PATH pattern (#778, paths Slice 1).
  ///
  /// Matches ONLY paths that resolve WITHOUT a working directory, so Slice 1 can
  /// ship the whole detect→anchor→decorate→tap→explorer pipeline and defer
  /// pwd-relative resolution to a later slice:
  ///   * absolute — a leading `/` followed by one or more `/`-separated segments
  ///     of path chars (`[\w.\-~@+]`), e.g. `/etc/ssh/sshd_config`;
  ///   * home — `~/…` (a `~` followed by `/` and segments); a BARE `~` never
  ///     anchors (#1024 — it's usually prose: `cd ~`, `about ~5 seconds`);
  ///   * explicit-relative — `./x`, `../x`, or a `../` chain, e.g. `../../lib`.
  /// BARE relative tokens (`src/foo`) are DEFERRED to Slice 3 — including them
  /// would over-match ordinary prose like `and/or`.
  ///
  /// A `://` context is rejected by [_validatePath] so `file://…` (and any other
  /// scheme whose authority starts with `//`) stays a URL — the URL/OSC-8 source
  /// wins the de-dup, and this pattern simply declines that span.
  ///
  /// Reuses the scanner's wrap-join + `_rangesFor` machinery UNCHANGED — only the
  /// regex and validate differ from [TextPattern.url]. [style] supplies the
  /// highlight color (the widget-layer decorator draws the affordance, #767 B).
  factory TextPattern.path({String id = 'path', HighlightStyle style =
      const HighlightStyle()}) {
    return TextPattern(
      id: id,
      regex: _kPathPattern,
      style: style,
      trailingTrim: _kPathTrailingTrim,
      normalize: _validatePath,
    );
  }

  /// The built-in RELATIVE FILE PATH pattern (paths Slice 3 — MobiSSH #1036).
  ///
  /// Matches BARE >=2-segment relative tokens (`specs/x/spec.md`, `a/b.txt`)
  /// that [TextPattern.path] deliberately defers: tokens with no leading `/`,
  /// `~/`, `./` or `../` anchor. The shape is DELIBERATELY BROAD — `and/or`
  /// matches it — because the CONSUMER is expected to gate visibility on an
  /// out-of-band precision check (MobiSSH resolves the token against the
  /// session cwd and only shows an affordance once an SFTP stat verifies the
  /// resolved absolute path; a prose token simply never verifies). What the
  /// shape itself excludes is anything ANOTHER pattern owns or that cannot be
  /// cwd-relative:
  ///   * absolute / home / explicit-relative starts (`/`, `~/`, `./`, `../`)
  ///     — [TextPattern.path]'s territory (a `(?!(?:\.{1,2}|~)/)` lookahead;
  ///     the shared lookbehind already blocks mid-token anchoring);
  ///   * `://` contexts — the same lookbehind rejects a start after `/` or
  ///     `:`, so `https://example.com/docs` never yields `example.com/docs`;
  ///   * `~user/...` — the first segment excludes a leading `~`;
  ///   * glob / shell-var / command-sub contamination — the #826 swallow +
  ///     #874 terminator machinery, REUSED via [_validateRelativePath].
  ///
  /// Distinct id (`relpath`) and [TextTier.span] so gating / telemetry /
  /// decorators treat it separately from absolute paths. Reuses the scanner's
  /// wrap-join + `_rangesFor` machinery unchanged; the existing
  /// [TextPattern.path] is untouched.
  factory TextPattern.relativePath({String id = 'relpath',
      HighlightStyle style = const HighlightStyle()}) {
    return TextPattern(
      id: id,
      regex: _kRelativePathPattern,
      style: style,
      trailingTrim: _kPathTrailingTrim,
      normalize: _validateRelativePath,
    );
  }

  /// The built-in COMMAND-LINE pattern (#998 slice B) — a BLOCK-tier anchor
  /// over a whole prompt-anchored command line, for copy-to-paste.
  ///
  /// Implements the issue's measured heuristic (design comment on #998,
  /// validated against 15 real owner byte-traces / 379 joined logical lines
  /// with zero prose misfires). Detection runs on the scanner's JOINED
  /// logical line (the existing #925/#928/#996/#1007 wrap-join — this pattern
  /// adds NO join logic of its own):
  ///
  /// **Stage 1 — prompt anchor (mandatory; no unanchored tier in v1):**
  ///   * STRONG prompts fire at body score >= 2: a bash `user@host:path$ `
  ///     prompt, a TUI line-number gutter (`56      curl …` — Claude Code
  ///     code blocks AND shell `history` output, whose entries ARE commands),
  ///     and Claude Code's `⎿  $ ` tool-result inner prompt.
  ///   * WEAK prompts need score >= 3 AND a lexicon hit: `❯ ` (Claude's
  ///     user-message echo — usually prose, so `❯ go` / `❯ /model` stay
  ///     silent) and bare `$`/`#`/`%` doc-style prompts.
  ///   * Bare `>` is EXCLUDED entirely (PS2 continuation and markdown
  ///     blockquote both render as `> `; FP risk swamps value).
  ///   * Diff-marked gutter rows (`\d+` gutter followed by `+`/`-`) are
  ///     SKIPPED: the diff marker sits INSIDE the wrap join, so a naive
  ///     extraction pastes corrupted text (`se`+`+ssion`). A context row of
  ///     the same diff (no marker) still detects.
  ///
  /// **Stage 2 — body score** (each signal counts once): first token — or its
  /// basename — in [lexicon] +2, OR first token executable-shaped
  /// (`./x`, `/x`, `~/x`, `scripts/x`) +2; leading `VAR=value` assignment(s)
  /// +1; a flag (`-x`/`--long`) +1; a shell operator (`| ; < > && $( `` ` ``)
  /// +1. The first-token signals are mutually exclusive (a token is scored as
  /// a lexicon word or as a path shape, not both) — the design lists them as
  /// alternative identities of one token.
  ///
  /// The [lexicon] is APP-SUPPLIED so the fork stays app-agnostic;
  /// [kDefaultCommandLexicon] (the design's curated ~100-word list) is the
  /// default. It is a static list, NOT PATH-derived (would need remote exec).
  ///
  /// The pattern is [TextTier.block] with [rangeGroup] 1: the anchor covers
  /// the COMMAND only (the prompt stays un-anchored ink) and inner url/path/
  /// OSC-8 SPAN anchors coexist inside it (#998 slice A mechanics). The
  /// payload is the prompt-stripped command with internal quoting/spacing
  /// preserved verbatim (paste-ability is the point); there is NO
  /// trailingTrim (a command legitimately ends in `"`, `)`, `&2`).
  factory TextPattern.command({
    String id = 'command',
    HighlightStyle style = const HighlightStyle(),
    List<String> lexicon = kDefaultCommandLexicon,
  }) {
    final lexiconSet = Set<String>.of(lexicon);
    return TextPattern(
      id: id,
      regex: _kCommandPattern,
      style: style,
      tier: TextTier.block,
      rangeGroup: 1,
      normalize: (raw) => _extractCommand(raw, lexiconSet),
    );
  }

  /// The built-in OSC-8 HYPERLINK source (#767 Slice B) — the PRIMARY, exact
  /// URL source.
  ///
  /// Unlike [TextPattern.url] (a regex over the visible glyph text), this reads
  /// the OSC-8 hyperlink URI libghostty attaches to each cell
  /// ([CellReader.hyperlinkAt]). The scanner groups maximal same-URI cell runs
  /// into one match whose payload is the EXACT full URI — so a wrapped link
  /// spans all its rows by construction and copy/open get the real link, with no
  /// regex / wrap / width heuristic. An OSC-8 match WINS over an overlapping
  /// regex URL match (the partial first-row `https://…` the regex would catch is
  /// suppressed on the hyperlinked cells), so a hyperlinked URL yields ONE exact
  /// anchor, not a partial regex bubble beside it. [style] supplies the highlight
  /// color (omitted by the app — the widget-layer bubble draws the affordance).
  factory TextPattern.osc8({String id = 'osc8', HighlightStyle style =
      const HighlightStyle()}) {
    return TextPattern(
      id: id,
      // Unused for an OSC-8 source — the scanner walks cells, not text. A
      // never-matching regex keeps [regex] non-null without false positives.
      regex: _kNeverMatch,
      style: style,
      isOsc8Source: true,
    );
  }
}

/// A regex that matches nothing — the placeholder [TextPattern.regex] for an
/// OSC-8 source, whose detection walks cells rather than running a regex.
final RegExp _kNeverMatch = RegExp(r'(?!x)x');

/// The shell metacharacter / glob set (#826) a real, tap-to-open filesystem path
/// NEVER holds — `$ { } * ? [ ] ( ) ` backtick ` | < > & ; = ' " \` — is SPLIT
/// into two roles (#874):
///   * [_kPathTerminator] — separators/quotes that merely BOUND a path; the path
///     TERMINATES at one and is the clean PREFIX before it (trim, don't reject).
///   * [_kPathReject] — glob/var/command-sub chars whose presence means the token
///     is NOT an openable path; the whole candidate is SUPPRESSED.
/// Whitespace already bounds a token. Inside a `[...]` class only `] \ ^ -` need
/// escaping; the rest are literal.

/// Shell delimiters that merely BOUND a path and where the path TERMINATES
/// (#874): a path followed by one of these is the clean prefix BEFORE it, not a
/// path-plus-tail. Members: `; | & < > =` (command/redirect separators) and `'`
/// `"` (quotes that wrap a path). [_validatePath] TRIMS the raw match at the
/// first of these, keeping only the leading clean path — so
/// `/tmp/tt.md; echo x` → `/tmp/tt.md`, `/a/b|grep` → `/a/b`, and `"/a/b"` →
/// `/a/b` (quote-stripped). Inside a `[...]` class only `] ^ -` need escaping;
/// the rest are literal.
const String _kPathTerminator = r'''|&<>=;'"''';

/// REJECT-class metachars (#826/#874): a path containing one of these adjacent
/// to path chars is a glob / shell-var / command-substitution TOKEN, not an
/// openable path, so [_validatePath] SUPPRESSES the whole candidate rather than
/// trimming a clean-looking sub-path out of it (Dart's backtracking would
/// otherwise carve `~/.zshrc.bak` out of `~/.zshrc.bak.*`). This is the full
/// metachar set MINUS the [_kPathTerminator] separators that legitimately bound
/// a path: it keeps `$ { } * ? [ ] ( ) ` backtick ` \`.
const String _kPathReject = r'''${}*?\[\]()`\\''';

/// The lookbehind metachar class (#874): the full metachar set MINUS the QUOTES
/// (`'` `"`). The negative lookbehind keeps a path from anchoring mid-token
/// (after a path char, `:`, `/`, or a glob/var metachar — the `://` and #826
/// glob-tail cases). A QUOTE, however, legitimately PRECEDES a path (`"/a/b"`,
/// `'/etc/hosts'`), so it must NOT block the anchor — the leading quote is a
/// boundary like whitespace, and [_kPathTrailingTrim] / [_validatePath] strip the
/// trailing quote. Dropping `'"` from the lookbehind lets a quoted path match.
const String _kPathLookbehindMeta = r'''${}*?\[\]()`|<>&;=\\''';

/// The ABSOLUTE FILE PATH regex (#778, paths Slice 1; precision #826). Matches
/// three shapes that resolve WITHOUT a working directory:
///   * absolute — `/` + one-or-more `/`-separated segments of path chars;
///   * home — `~/…` only (a BARE `~` never anchors, #1024: prose tildes like
///     `cd ~` / `about ~5 seconds` are far more common than a tap-worthy lone
///     home reference, and the #990 stat gate would happily VERIFY `~`);
///   * explicit-relative — `./…`, `../…`, or a `../` chain.
/// A path char is `[\w.\-~@+]` (mirrors the issue's class). A NEGATIVE LOOKBEHIND
/// keeps the match from starting MID-token — critically it rejects the `//` after
/// a `:` (so `https://`/`file://` never starts a path at the `//`), from inside
/// another path char run, AND (#826) immediately AFTER a shell metachar/glob char
/// so a glob-tail fragment like `/Listeners` in `…launchd.*/Listeners` does not
/// anchor.
///
/// #826: a TRAILING `(?:[metachar][^\s]*)?` group GREEDILY SWALLOWS any adjacent
/// shell-var/glob suffix INTO the match (e.g. `${UID}_*` after `/tmp/.ssh_loaded_`,
/// `.*` after `~/.zshrc.bak`). Folding the contamination into the raw match — rather
/// than relying on a trailing negative lookahead — defeats Dart's greedy
/// BACKTRACKING, which would otherwise carve a clean-looking sub-path (`~/.zshrc.bak`)
/// out of a glob token to satisfy a bare lookahead. [_validatePath] then sees the
/// metachar in the raw and SUPPRESSES the whole candidate. The match stops at the
/// same stop set URLs use (whitespace). BARE relative tokens (`src/foo`) are
/// deliberately NOT matched (deferred to Slice 3) — only a leading `/`, `~`, `.`
/// anchors a match.
final RegExp _kPathPattern = RegExp(
  '(?<![\\w.\\-~@+:/$_kPathLookbehindMeta])'
  r'(?:'
  r'/(?:[\w.\-~@+]+/?)+' // absolute: /a/b/c
  r'|~/(?:[\w.\-~@+]+/?)*' // home: ~/a/b (a BARE ~ never anchors, #1024)
  r'|\.\.?/(?:[\w.\-~@+]+/?|\.\.?/)*' // ./x ../x ../../ chains
  r')'
  // #826: swallow any adjacent REJECT-class (glob/var/command-sub) suffix so
  // [_validatePath] can reject the WHOLE contaminated token (backtracking can't
  // peel off a clean sub-path). #874: TERMINATOR chars (`; | & < > = ' "`) are
  // deliberately NOT swallowed — they are not path chars, so the regex stops at
  // them and the span ends at the clean path (no over-highlight of the tail);
  // `_validatePath` still trims a terminator that a reject-class `[^\s]*` grab may
  // span (e.g. `/a*;b`).
  '(?:[$_kPathReject][^\\s]*)?',
);

/// Trailing characters trimmed off the END of a raw path match — a path that
/// ends a sentence picks up `.,;:!?` and closers; mirrors the URL trim.
const String _kPathTrailingTrim = '.,;:!?)]}>\'"';

/// REJECT-class metachar detector (#826/#874): true iff [raw] contains a glob /
/// shell-var / command-substitution char a real, tap-to-open filesystem path
/// never holds (`$ { } * ? [ ] ( ) ` backtick ` \`). The path regex deliberately
/// SWALLOWS an adjacent metachar/glob suffix into the raw match (see
/// [_kPathPattern]) so this validate sees the whole contaminated token and can
/// reject it — a backtracking-proof gate the trailing lookahead alone could not be.
final RegExp _kPathRejectProbe = RegExp('[$_kPathReject]');

/// First-terminator detector (#874): the index of the first [_kPathTerminator]
/// char (`; | & < > = ' "`) in a raw match, or `-1` if none. A path TERMINATES at
/// such a separator/quote, so the openable path is the clean PREFIX before it.
final RegExp _kPathTerminatorProbe = RegExp('[$_kPathTerminator]');

/// Validate a raw path match (#826 + #874). Returns the openable path as its own
/// payload, or `null` to SUPPRESS the candidate.
///
/// #874: a path TERMINATES at a shell separator/quote ([_kPathTerminator]: `; | &
/// < > = ' "`). The swallow group in [_kPathPattern] may have grabbed such a tail
/// (e.g. `/tmp/tt.md;`, `/a/b|grep`, or the trailing quote of `"/a/b"`), so first
/// TRIM the raw at the first terminator — keeping only the leading clean path —
/// and strip any leading quote left by the swallow/anchor (`"/a/b"` → `/a/b`).
///
/// #826: AFTER trimming, if the surviving prefix still holds a REJECT-class
/// metachar ([_kPathReject]: `$ { } * ? [ ] ( ) ` backtick ` \`), the candidate is
/// a glob / shell-var / command-substitution TOKEN (`/tmp/.ssh_loaded_${UID}_*`,
/// `~/.ssh/*.pub`), NOT an openable path — SUPPRESS it (don't carve a clean-looking
/// sub-path out of a glob). An empty prefix (the candidate was ALL tail) also
/// suppresses. The scanner DROPS a match whose normalize returns null (the `://`
/// URL case is additionally rejected by the lookbehind, so `file://…` stays a URL).
String? _validatePath(String raw) {
  var path = raw;
  // #874: terminate at the first shell separator / quote — the path is the
  // clean prefix before it.
  final term = _kPathTerminatorProbe.firstMatch(path);
  if (term != null) path = path.substring(0, term.start);
  // Strip a leading quote the anchor/swallow may have included (`"/a/b"`); the
  // trailing quote is already gone via the terminator trim above.
  while (path.isNotEmpty && (path[0] == '"' || path[0] == "'")) {
    path = path.substring(1);
  }
  if (path.isEmpty) return null;
  // #826: a surviving glob/var/command-sub token is not an openable path.
  if (_kPathRejectProbe.hasMatch(path)) return null;
  return path;
}

/// The RELATIVE FILE PATH regex (paths Slice 3 — MobiSSH #1036). Matches a
/// BARE >=2-segment relative token:
///   * the SAME negative lookbehind as [_kPathPattern] — no mid-token anchor,
///     no start after `/` or `:` (so `https://example.com/docs` never yields
///     `example.com/docs`), no start after a glob/var metachar;
///   * a lookahead excluding the starts [TextPattern.path] owns (`./`, `../`)
///     — `~/` cannot occur because the FIRST segment excludes a leading `~`
///     (which also keeps `~user/x` — a home reference, not cwd-relative — out);
///     a dot-LEADING first segment (`.claude/rules`) still matches;
///   * first segment + one-or-more `/`-joined further segments (>=2 segments
///     total — a single token or a lone `src/` never anchors), optional
///     trailing slash;
///   * the #826 trailing swallow group, so a glob/var-contaminated token
///     reaches [_validateRelativePath] whole and is suppressed (backtracking
///     can't carve a clean-looking sub-path out of it).
final RegExp _kRelativePathPattern = RegExp(
  '(?<![\\w.\\-~@+:/$_kPathLookbehindMeta])'
  r'(?!\.{1,2}/)' // ./ and ../ starts belong to TextPattern.path
  r'[\w.\-@+]+' // first segment (no leading ~ — see doc above)
  r'(?:/[\w.\-~@+]+)+' // >=1 further segment → >=2 segments total
  r'/?'
  '(?:[$_kPathReject][^\\s]*)?', // #826 swallow → validate sees the whole token
);

/// Validate a raw RELATIVE path match (#1036). Reuses [_validatePath]'s #874
/// terminator trim + quote strip + #826 reject gate, then RE-CHECKS the
/// >=2-segment shape: the trim can leave a single segment (`a` out of `a/;b`
/// is not a relative path anymore), which must suppress rather than anchor a
/// bare word.
String? _validateRelativePath(String raw) {
  final path = _validatePath(raw);
  if (path == null) return null;
  final core = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
  final slash = core.indexOf('/');
  if (slash <= 0 || slash >= core.length - 1) return null;
  return path;
}

/// The URL regex (moved verbatim from the app's `ghostty_url_detector.dart`,
/// #767). Matches absolute http/https URLs and bare `www.` hosts; the
/// character class stops at whitespace and the few characters terminals/shells
/// never put mid-URL.
final RegExp _kUrlPattern = RegExp(
  r'(?:https?://|www\.)[^\s<>"'
  "'"
  r'`]+',
  caseSensitive: false,
);

/// Trailing characters trimmed off the END of a raw URL match (moved verbatim
/// from `ghostty_url_detector.dart`, #767).
const String _kUrlTrailingTrim = '.,;:!?)]}>\'"';

/// Normalise a raw URL match: prefix a bare `www.` host with `https://`
/// (moved verbatim from `ghostty_url_detector.dart`, #767).
String _normalizeUrl(String raw) {
  final lower = raw.toLowerCase();
  if (lower.startsWith('http://') || lower.startsWith('https://')) return raw;
  return 'https://$raw';
}

/// The default command LEXICON for [TextPattern.command] (#998 slice B) — the
/// design's curated ~100-word list of common command words. APP-SUPPLIABLE via
/// the factory's `lexicon` parameter; this is only the default. Deliberately
/// static (not PATH-derived — that would need remote exec). `command` and
/// `yes` are EXCLUDED on purpose: the design's measured corpus scored
/// `command -v wrangler…` at 2 (flag+operator, no lexicon hit) behind a strong
/// prompt, and both words are common English prose.
const List<String> kDefaultCommandLexicon = [
  // vcs / dev tooling
  'git', 'gh', 'make', 'cmake', 'gradle', 'mvn', 'cargo', 'rustc', 'go',
  'gcc', 'clang', 'java', 'javac', 'node', 'npm', 'npx', 'yarn', 'pnpm',
  'python', 'python3', 'pip', 'pip3', 'ruby', 'gem', 'dart', 'flutter',
  'adb', 'jq', 'diff', 'patch',
  // network / transfer
  'curl', 'wget', 'ssh', 'scp', 'sftp', 'rsync', 'ping', 'dig', 'nslookup',
  'traceroute', 'netstat', 'ss', 'ip', 'ifconfig', 'openssl', 'gpg',
  // containers / services
  'docker', 'podman', 'kubectl', 'systemctl', 'service', 'journalctl',
  // package managers
  'apt', 'apt-get', 'dpkg', 'yum', 'dnf', 'pacman', 'brew',
  // shells / multiplexers
  'bash', 'sh', 'zsh', 'fish', 'tmux', 'screen', 'env', 'export', 'source',
  'sudo', 'su',
  // files / text
  'ls', 'cd', 'cp', 'mv', 'rm', 'mkdir', 'rmdir', 'touch', 'ln', 'cat',
  'less', 'more', 'head', 'tail', 'grep', 'egrep', 'rg', 'ag', 'find', 'fd',
  'sed', 'awk', 'cut', 'sort', 'uniq', 'wc', 'tr', 'xargs', 'tee', 'echo',
  'printf', 'chmod', 'chown', 'chgrp', 'tar', 'gzip', 'gunzip', 'zip',
  'unzip', 'base64', 'md5sum', 'sha256sum',
  // system / processes
  'ps', 'top', 'htop', 'kill', 'pkill', 'killall', 'df', 'du', 'mount',
  'umount', 'crontab', 'history', 'which', 'whoami', 'uname', 'hostname',
  'man', 'date',
  // editors
  'nano', 'vim', 'vi', 'emacs', 'code',
];

/// STRONG prompt alternatives (#998 B): fire at body score >= 2.
///   * `user@host:path$ ` — bash prompt (sampled live from the owner's tmux).
///   * `\d+` + 2+ spaces — TUI line-number gutter (Claude Code code blocks,
///     shell `history`). The `(?!\s*[+-])` lookahead excludes DIFF-marked
///     rows (`53  +    echo …`) — with backtracking, `\s{2,}` could otherwise
///     shrink to leave a space before the `+` and defeat a bare `(?![+-])`.
///   * `⎿  $ ` — Claude Code's tool-result inner prompt.
const String _kStrongPromptAlt =
    r'[\w.\-]+@[\w.\-]+:[^\s#$]*[#$]\s+'
    r'|\d+\s{2,}(?!\s*[+\-])'
    r'|⎿\s+\$\s+';

/// WEAK prompt alternatives (#998 B): need body score >= 3 AND a lexicon hit.
/// `❯ ` is Claude Code's USER-MESSAGE echo in the corpus (body usually prose
/// — `❯ go`, `❯ /model`), so the stricter gate kills those while a real
/// pasted command still detects. Bare `>` is deliberately ABSENT (PS2 /
/// blockquote). Diff `+`/`-` rows can never reach here (they start with a
/// digit or `+`/`-`, matching no prompt).
const String _kWeakPromptAlt = r'❯\s+' r'|[$#%]\s+';

/// The COMMAND-LINE regex (#998 B): a prompt anchor at line start, then the
/// body as capture group 1 (the [TextPattern.rangeGroup] span — the prompt
/// stays un-anchored ink). One match per logical line by construction (`^`,
/// non-multiline). Scoring/suppression happens in [_extractCommand].
final RegExp _kCommandPattern =
    RegExp('^(?:$_kStrongPromptAlt|$_kWeakPromptAlt)(.+)\$');

/// Whether a raw command match is anchored by a STRONG prompt (vs a weak
/// one). Distinguishes the two score thresholds in [_extractCommand].
final RegExp _kStrongPromptProbe = RegExp('^(?:$_kStrongPromptAlt)');

/// A leading `VAR=value` shell assignment token (+1, counted once).
final RegExp _kAssignmentToken = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=\S*$');

/// An executable-shaped first token: `./x`, `/x`, `~/x`, `scripts/x` (+2).
final RegExp _kExecPathToken = RegExp(r'^(\./|/|~/|scripts/)[\w./\-]+$');

/// A flag anywhere in the body: whitespace-or-start, then `-x`/`--long` (+1).
final RegExp _kCommandFlagProbe = RegExp(r'(?:^|\s)-{1,2}[A-Za-z0-9]');

/// A shell operator anywhere in the body: `| ; < > && $( ` backtick (+1).
/// `>` also covers `2>`; `|` also covers `||`.
final RegExp _kShellOperatorProbe = RegExp(r'[|;<>`]|\$\(|&&');

/// Validate + extract a raw [_kCommandPattern] match (#998 B). Returns the
/// prompt-stripped command as the payload, or null to SUPPRESS the candidate.
///
/// Body score (each signal once): first non-assignment token in [lexicon]
/// (exact or basename) +2, else executable-shaped +2; leading assignment(s)
/// +1; flag +1; shell operator +1. STRONG prompts fire at score >= 2; WEAK
/// prompts need score >= 3 AND the lexicon hit. Glyphs are verbatim from the
/// joined cells, so internal quoting/spacing survives by construction; only
/// trailing whitespace is trimmed (no punctuation trim — a command
/// legitimately ends in `"`, `)`, `&2`).
String? _extractCommand(String raw, Set<String> lexicon) {
  final m = _kCommandPattern.firstMatch(raw);
  if (m == null) return null;
  final body = m.group(1)!.trimRight();
  if (body.isEmpty) return null;
  var score = 0;
  var lexiconHit = false;
  final tokens = body.split(RegExp(r'\s+'));
  var i = 0;
  while (i < tokens.length && _kAssignmentToken.hasMatch(tokens[i])) {
    i++;
  }
  if (i > 0) score += 1; // leading VAR=value assignment(s)
  if (i < tokens.length) {
    final first = tokens[i];
    final slash = first.lastIndexOf('/');
    final basename = slash >= 0 ? first.substring(slash + 1) : first;
    if (lexicon.contains(first) || lexicon.contains(basename)) {
      score += 2;
      lexiconHit = true;
    } else if (_kExecPathToken.hasMatch(first)) {
      score += 2;
    }
  }
  if (_kCommandFlagProbe.hasMatch(body)) score += 1;
  if (_kShellOperatorProbe.hasMatch(body)) score += 1;
  final strong = _kStrongPromptProbe.hasMatch(raw);
  if (strong ? score < 2 : (score < 3 || !lexiconHit)) return null;
  return body;
}

/// A single detected structured-text match (#767).
///
/// [ranges] are the per-row [HighlightRange]s the match occupies, in ABSOLUTE
/// buffer-row coordinates — one range per row a soft-wrapped match spans (a
/// single-row match has exactly one). Each range carries [payload] so a later
/// hit-test recovers what the cells represent. [patternId] identifies which
/// [TextPattern] produced the match.
@immutable
final class StructuredMatch {
  /// The [TextPattern.id] that produced this match.
  final String patternId;

  /// The per-row absolute-coordinate ranges this match occupies.
  final List<HighlightRange> ranges;

  /// The opaque value the match represents (e.g. the normalized URL string).
  final Object payload;

  /// The producing pattern's [TextPattern.tier] (#998 slice A), stamped by the
  /// scanner so hit-testing can prefer the innermost (span) match at a cell
  /// covered by both tiers. Defaults to [TextTier.span].
  final TextTier tier;

  const StructuredMatch({
    required this.patternId,
    required this.ranges,
    required this.payload,
    this.tier = TextTier.span,
  });

  /// Returns true if the cell at ABSOLUTE ([row], [col]) falls in any range.
  bool contains(int row, int col) {
    for (final range in ranges) {
      if (range.contains(row, col)) return true;
    }
    return false;
  }
}

/// A persistent structured-text ANCHOR exposed to the widget layer (#767 Slice B).
///
/// The fork OWNS persistent cell-sequence anchoring (the [StructuredTextScanner]
/// re-anchors matches across scroll/wrap/resize/eviction by re-scanning the live
/// cells). Slice A painted those matches with one baked-in [HighlightPainter]
/// style. Slice B instead EXPOSES the matches as anchors so the widget layer can
/// inject ITS OWN per-pattern decorators (a URL bubble/chip, a future file-path
/// or commit-sha treatment) WITHOUT the fork picking a paint style — the
/// "unblock persistent understanding of where the cells are so decorators can be
/// injected without constant maintenance" requirement.
///
/// An anchor is a thin, immutable view over a single [StructuredMatch]: the
/// [patternId] that produced it, the opaque [payload] the cells represent (e.g.
/// the normalized URL), and the per-row absolute-coordinate [ranges] it occupies
/// (one per soft-wrapped row). The widget resolves a range to CURRENT viewport
/// pixel rects each frame via `TerminalController.anchorRects`, so a decorator
/// tracks scroll/wrap/resize/eviction with NO re-detection.
@immutable
final class StructuredAnchor {
  /// The [TextPattern.id] that produced this anchor's underlying match.
  final String patternId;

  /// The opaque value the anchored cells represent (e.g. the URL string).
  final Object payload;

  /// The per-row absolute-coordinate ranges this anchor occupies — one per row
  /// a soft-wrapped match spans (a single-row match has exactly one).
  final List<HighlightRange> ranges;

  const StructuredAnchor({
    required this.patternId,
    required this.payload,
    required this.ranges,
  });

  /// Builds an anchor from a detected [StructuredMatch].
  StructuredAnchor.fromMatch(StructuredMatch match)
    : patternId = match.patternId,
      payload = match.payload,
      ranges = match.ranges;

  /// Returns true if the cell at ABSOLUTE ([row], [col]) falls in any range.
  bool contains(int row, int col) {
    for (final range in ranges) {
      if (range.contains(row, col)) return true;
    }
    return false;
  }
}

/// Read-only view of a terminal's cells for the [StructuredTextScanner].
///
/// The headless seam between the scanner (pure Dart, unit-testable) and
/// libghostty's native `GridRef`/`RenderState` (FFI). [rows] x [cols] is the
/// region to scan; [baseAbsRow] is the ABSOLUTE buffer row of local row 0, so
/// emitted ranges land in the absolute, top-anchored frame the painter and
/// selection model use. A scan re-reads [baseAbsRow] each pass, so when
/// scrollback EVICTS lines (every surviving line's absolute index shifts down)
/// a fresh scan emits the corrected rows by construction.
///
/// [cellContent] returns the cell's grapheme cluster as a string (empty for a
/// blank cell or a wide-character spacer tail). [rowWrap] is libghostty's
/// AUTHORITATIVE soft-wrap flag: true iff local [row] continues onto [row]+1.
abstract interface class CellReader {
  /// Number of local rows available to scan (e.g. viewport + bounded
  /// scrollback window).
  int get rows;

  /// Grid width in cells.
  int get cols;

  /// Absolute buffer row corresponding to local row 0.
  int get baseAbsRow;

  /// The grapheme content of the cell at local ([row], [col]); empty for a
  /// blank cell or a wide-character spacer tail.
  String cellContent(int row, int col);

  /// Whether local [row] is soft-wrapped onto local [row]+1 (authoritative).
  bool rowWrap(int row);

  /// The OSC-8 HYPERLINK URI attached to the cell at local ([row], [col]), or
  /// null when the cell carries no hyperlink (#767 Slice B).
  ///
  /// libghostty attaches the FULL OSC-8 URI to EVERY visible cell of a link —
  /// including soft/hard-wrapped continuation rows — so the OSC-8 source can
  /// group maximal same-URI runs into one match spanning all wrapped rows by
  /// construction. The real controller reads `GridRef.hyperlinkUri`; the test
  /// fake supplies a per-cell URI map. A blank/spacer-tail cell carries no
  /// hyperlink (null), so a non-link gap naturally breaks a run.
  String? hyperlinkAt(int row, int col);
}

/// One character of a logical line, tagged with the absolute cell it came from.
class _Glyph {
  _Glyph(this.text, this.absRow, this.col);

  /// The cell's grapheme content (always non-empty — blanks become a space).
  final String text;

  /// Absolute buffer row of the cell.
  final int absRow;

  /// Column of the cell on its row.
  final int col;
}

/// A logical line assembled from one or more soft-wrapped rows (#767).
///
/// Unlike the old viewport-offset arithmetic (`offset ~/ cols`), each glyph
/// carries its EXACT origin cell, so mapping a regex match's character span
/// back to per-row absolute ranges never depends on padding/width guesses.
class _LogicalLine {
  _LogicalLine(this.glyphs);

  final List<_Glyph> glyphs;

  /// The joined text of all member cells, one char per cell.
  String get text => glyphs.map((g) => g.text).join();
}

/// Scans a terminal's cells for [TextPattern]s and emits [StructuredMatch]es
/// in ABSOLUTE buffer coordinates (#767).
///
/// Pure Dart over a [CellReader] — no FFI, no widget — so every wrap / range /
/// eviction edge case is unit-testable headless.
class StructuredTextScanner {
  const StructuredTextScanner();

  /// Scan [reader]'s cells for every pattern in [patterns].
  ///
  /// Walks logical lines (rows joined by [CellReader.rowWrap]), runs each
  /// pattern's [TextPattern.regex] over the joined text, trims the configured
  /// trailing characters, and maps each accepted match back to per-row
  /// [HighlightRange]s in absolute coordinates. Two adjacent matches yield two
  /// distinct [StructuredMatch]es (never merged); each terminates at the
  /// match's real last cell (no trailing-pad, no bleed into the next line).
  List<StructuredMatch> scan(CellReader reader, List<TextPattern> patterns) {
    if (patterns.isEmpty) return const [];
    final rows = reader.rows;
    final cols = reader.cols;
    if (rows <= 0 || cols <= 0) return const [];

    final regexPatterns = [for (final p in patterns) if (!p.isOsc8Source) p];
    final osc8Patterns = [for (final p in patterns) if (p.isOsc8Source) p];

    // OSC-8 FIRST: it is the PRIMARY, exact source and WINS over any overlapping
    // regex match. Collect the hyperlinked cells so an overlapping regex match
    // (the partial first-row `https://…` over the link's visible text) is
    // suppressed — yielding ONE exact anchor, not a partial bubble beside it.
    final matches = <StructuredMatch>[];
    final hyperlinkedCells = <int, Set<int>>{}; // absRow -> set of cols
    if (osc8Patterns.isNotEmpty) {
      for (final pattern in osc8Patterns) {
        for (final m in _scanOsc8(reader, rows, cols, pattern)) {
          matches.add(m);
          for (final range in m.ranges) {
            final set = hyperlinkedCells.putIfAbsent(range.startRow, () => {});
            for (var c = range.startCol; c < range.endCol; c++) {
              set.add(c);
            }
          }
        }
      }
    }

    if (regexPatterns.isEmpty) return matches;

    final lines = _assembleLines(reader, rows, cols);
    for (final line in lines) {
      final text = line.text;
      if (text.isEmpty) continue;
      for (final pattern in regexPatterns) {
        for (final m in pattern.regex.allMatches(text)) {
          var start = m.start;
          var end = m.end; // exclusive
          // Trim trailing sentence punctuation / unbalanced closers from the
          // END, mirroring the old detector.
          final trim = pattern.trailingTrim;
          while (end > start && trim.contains(text[end - 1])) {
            end--;
          }
          if (end <= start) continue;
          // De-dup: OSC-8 wins WITHIN the span tier (#998 A). Drop a SPAN-tier
          // regex match that overlaps ANY OSC-8 hyperlinked cell, so a
          // hyperlinked URL (whose visible text is also URL-shaped) yields only
          // the exact OSC-8 anchor. A BLOCK-tier match (a command line, #998 B)
          // legitimately CONTAINS links — cross-tier containment is allowed, so
          // it is exempt. A plain-text URL (no OSC-8) is unaffected — the map
          // is empty, so this never fires.
          if (pattern.tier == TextTier.span &&
              hyperlinkedCells.isNotEmpty &&
              _overlapsHyperlink(line.glyphs, start, end, hyperlinkedCells)) {
            continue;
          }
          final raw = text.substring(start, end);
          // A pattern's normalize MAY reject (return null) to SUPPRESS the match
          // entirely — used by the path pattern to drop shell-var/glob fragments
          // (#826). Distinguish "has normalize, returned null → drop" from "no
          // normalize → use raw": only the former suppresses.
          final Object? payload =
              pattern.normalize != null ? pattern.normalize!(raw) : raw;
          if (payload == null) continue;
          // #998 A: rangeGroup narrows the ANCHORED span to the capture group
          // (the prompt stays un-anchored ink). Geometry only — [raw]/[payload]
          // above keep the full match. Dart's Match has no per-group offsets,
          // so locate the group text's LAST occurrence within the match (exact
          // for the suffix-group shape this exists for). The group span is
          // clamped to the trailing-trimmed end.
          var rangeStart = start;
          var rangeEnd = end;
          final rangeGroup = pattern.rangeGroup;
          if (rangeGroup != null) {
            final group =
                rangeGroup <= m.groupCount ? m.group(rangeGroup) : null;
            if (group == null || group.isEmpty) continue;
            final matched = text.substring(m.start, m.end);
            rangeStart = m.start + matched.lastIndexOf(group);
            rangeEnd = rangeStart + group.length;
            if (rangeEnd > end) rangeEnd = end;
            if (rangeEnd <= rangeStart) continue;
          }
          final ranges = _rangesFor(
            line.glyphs,
            rangeStart,
            rangeEnd,
            pattern.style,
            payload,
          );
          if (ranges.isEmpty) continue;
          matches.add(
            StructuredMatch(
              patternId: pattern.id,
              ranges: ranges,
              payload: payload,
              tier: pattern.tier,
            ),
          );
        }
      }
    }
    return matches;
  }

  /// Whether the regex match spanning glyphs `[start, end)` overlaps any cell in
  /// [hyperlinkedCells] (absRow → covered cols). Used to SUPPRESS a regex match
  /// over OSC-8-hyperlinked cells so OSC-8 wins the de-dup (#767 Slice B).
  bool _overlapsHyperlink(
    List<_Glyph> glyphs,
    int start,
    int end,
    Map<int, Set<int>> hyperlinkedCells,
  ) {
    for (var i = start; i < end; i++) {
      final cols = hyperlinkedCells[glyphs[i].absRow];
      if (cols != null && cols.contains(glyphs[i].col)) return true;
    }
    return false;
  }

  /// Scan the reader's cells for OSC-8 hyperlink runs (#767 Slice B).
  ///
  /// Walks cells in READING ORDER (row 0..rows-1, col 0..cols-1) and groups each
  /// MAXIMAL contiguous run of cells sharing the SAME non-null
  /// [CellReader.hyperlinkAt] URI into one [StructuredMatch] (payload = the URI).
  /// "Contiguous" follows reading order: the next col on the same row, or col 0
  /// of the next row when the run reaches the row end — so a wrapped link (the
  /// same URI on row N's tail and row N+1's head) is ONE run spanning both rows
  /// by construction. A URI CHANGE or a non-link (null) cell ends the run, and a
  /// run is emitted as per-row [HighlightRange]s in absolute coordinates.
  List<StructuredMatch> _scanOsc8(
    CellReader reader,
    int rows,
    int cols,
    TextPattern pattern,
  ) {
    final base = reader.baseAbsRow;

    // Group ALL cells sharing the same hyperlink URI into ONE match — regardless
    // of intervening NON-link cells (trailing wrap padding) or row breaks.
    // libghostty attaches the SAME URI to every cell of a link, so same-URI cells
    // ARE the link even when an APP wraps it at its own content width (narrower
    // than the terminal) and PADS the rest of the row: that padding is a non-link
    // gap that must NOT split the link (the device bug — the link's first row
    // bubbled, the padded continuation did not). A flush-on-gap run breaks there;
    // grouping by URI does not. (No hyperlink-id is exposed by libghostty, so URI
    // is the grouping key; the rare case of the identical URI appearing as two
    // separate on-screen links merges into one anchor — harmless: both bubble and
    // copy the same exact URI.) `_rangesFor` turns the collected glyphs into one
    // range PER ROW, so a wrapped link spans its rows; intra-row padding is simply
    // absent from the glyph list and thus from the ranges.
    final byUri = <String, List<_Glyph>>{};
    final order = <String>[];
    for (var r = 0; r < rows; r++) {
      final absRow = base + r;
      for (var c = 0; c < cols; c++) {
        final uri = reader.hyperlinkAt(r, c);
        // Treat an EMPTY or whitespace-only URI the same as null (no hyperlink).
        // libghostty can return "" (not null) for a cell inside an empty-URI or
        // torn-down OSC-8 link (`ESC]8;;ESC\` appears in the #810 device trace);
        // grouping such cells would yield a NON-NULL match with an EMPTY payload
        // — a "URL" the tap-copy path reports as "Copied URL" while the clipboard
        // is empty (#810). An anchor must carry a real link.
        if (uri == null || uri.trim().isEmpty) continue;
        final glyphs = byUri.putIfAbsent(uri, () {
          order.add(uri);
          return <_Glyph>[];
        });
        glyphs.add(_Glyph(uri, absRow, c));
      }
    }

    final matches = <StructuredMatch>[];
    for (final uri in order) {
      final glyphs = byUri[uri]!;
      final ranges =
          _rangesFor(glyphs, 0, glyphs.length, pattern.style, uri);
      if (ranges.isNotEmpty) {
        matches.add(
          StructuredMatch(
            patternId: pattern.id,
            ranges: ranges,
            payload: uri,
            tier: pattern.tier,
          ),
        );
      }
    }
    return matches;
  }

  /// Assemble local rows into logical lines, joining soft-wrapped rows by the
  /// AUTHORITATIVE [CellReader.rowWrap] flag (never guessed from width). A
  /// blank cell becomes a single space so column positions stay aligned and a
  /// URL never silently swallows a gap.
  List<_LogicalLine> _assembleLines(CellReader reader, int rows, int cols) {
    final base = reader.baseAbsRow;
    // Infer the app's WRAP COLUMN — the dominant content-end among long rows. An
    // app (Claude TUI, gh, a pager) often wraps NARROWER than the terminal and
    // PADS the rest of the row with blanks, so the terminal's last cell is empty
    // even on a wrapped row (the device bug: a plain-text URL wrapping at the
    // CLI's ~53-col content width in a 55-col terminal only bubbled/copied its
    // first row). Joining must key off where wrapped rows ACTUALLY end, not the
    // terminal edge.
    final (wrapCol, wrapColCount) = _inferWrapCol(reader, rows, cols);
    final lines = <_LogicalLine>[];
    var r = 0;
    while (r < rows) {
      final glyphs = <_Glyph>[];
      // The logical block's LEFT INDENT — the content-start column of its FIRST
      // row (#925). An app (Claude TUI) emitting INDENTED output wraps its
      // continuation rows at the SAME indent; that leading indent is layout
      // padding, NOT part of the wrapped token. Continuation rows START their
      // cell walk at this indent so the indent is SKIPPED (not injected as
      // spaces between a URL's two halves, which would break `[^\s]+`). The
      // first row keeps its own leading indent dropped too (a leading blank run
      // never carries a match), but its glyphs already begin at content.
      final blockIndent = _contentStart(reader, r, cols);
      // Whether the CURRENT row was entered via the width-heuristic (TUI
      // hard-wrap) join rather than the authoritative soft-wrap flag. A width-
      // joined continuation row's ENTIRE leading blank margin is layout indent
      // by construction (#925 same-margin, #996 hanging indent) — there is no
      // content before its contentStart — so it is skipped wholesale. False for
      // the block's first row and for soft-wrap-flag continuations.
      var viaWidthJoin = false;
      // #998 B: the block's ESTABLISHED hanging indent — set when a #996
      // hanging-indent width-join fires (URL-token evidence), so FURTHER rows
      // of the SAME block at the SAME indent can continue the join without
      // per-row URL evidence (a wrapped command's middle rows carry none:
      // the 14-06-30 trace hard-wraps `…2>/dev/` / `null || echo …` / `&2`
      // at a 10-col hanging indent). -1 until established. [hangHeadEnd] is
      // the establishing row's content-end — the block-local wrap column the
      // continuation discipline keys off.
      var hangIndent = -1;
      var hangHeadEnd = -1;
      // Accumulate this row and every row it soft-wraps into.
      while (true) {
        final absRow = base + r;
        // Add cells up to the row's CONTENT end only — dropping TRAILING padding.
        // An app that wraps narrower than the terminal pads the rest of the row
        // with blanks; if those padding spaces were appended, they would sit
        // BETWEEN a wrapped URL's two halves and break the match ("https://e" +
        // "        " + "x.io"). Internal blanks (before content end) are kept (as
        // spaces) so column positions stay aligned and a gap isn't swallowed.
        final end = _contentEnd(reader, r, cols);
        // #925: skip the block's LEFT INDENT, but NEVER past this row's own
        // content start — so real content is never dropped. On the FIRST row and
        // an indented same-margin CONTINUATION row, the row's content begins at
        // the block indent, so this drops the repeated left margin (which would
        // otherwise be injected as spaces between a wrapped token's halves and
        // break `[^\s]+`). On a SOFT-WRAP continuation that resumes at col 0
        // (rowWrap=true, shallower than an indented first row), the row's content
        // start is 0, so `skip` is 0 and the leading cells are preserved. Cells
        // at/after the skip — content or internal blanks — are kept so alignment
        // and genuine gaps survive.
        //
        // #996: a WIDTH-JOINED row (TUI hard-wrap) skips its OWN full indent
        // instead. A TUI wrapping with a HANGING indent (Claude Code's diff view:
        // first row's content starts at the line-number gutter, continuations
        // start deeper) puts the continuation's contentStart PAST blockIndent;
        // min(blockIndent, rowStart) would keep the cols between them — blank
        // margin injected as spaces between a wrapped URL's halves, breaking
        // `[^\s]+`. For a width-join the margin left of contentStart is layout by
        // definition (the join heuristic itself keyed off content columns), so
        // skip = rowStart. Same-margin width joins are unaffected (rowStart ==
        // blockIndent there). Soft-wrap-flag rows keep the min() rule: their
        // leading blanks can be REAL logical-line content (e.g. aligned columns
        // split by the terminal edge), so only the block margin is dropped.
        // #998 B: in an ESTABLISHED hanging block, a continuation row's
        // in-band content starts at [hangIndent]; anything painted LEFT of the
        // block indent (a TUI spinner/status overlay leaving stray glyphs at
        // col 0, like the `Ra` residue in the 14-06-30 trace) is out-of-band
        // junk, not block content — clamp the walk to the hanging indent so
        // it is excluded from the joined line.
        final rowStart = _contentStart(reader, r, cols);
        var skip = viaWidthJoin
            ? (hangIndent > 0 && rowStart < hangIndent ? hangIndent : rowStart)
            : (blockIndent < rowStart ? blockIndent : rowStart);
        if (skip > end) skip = end;
        for (var c = skip; c < end; c++) {
          final content = reader.cellContent(r, c);
          glyphs.add(_Glyph(content.isEmpty ? ' ' : content, absRow, c));
        }
        if (r < rows - 1 &&
            _continuesOnto(reader, r, cols, wrapCol, wrapColCount, blockIndent,
                hangIndent, hangHeadEnd)) {
          final widthJoin = !reader.rowWrap(r);
          // #998 B: a width-join whose continuation starts DEEPER than the
          // block indent is the #996 hanging shape — record the hanging
          // indent + the head row's content-end so subsequent rows of this
          // block can continue at the same discipline (see _continuesOnto).
          if (widthJoin && hangIndent < 0) {
            final nextStart = _contentStart(reader, r + 1, cols);
            if (nextStart > blockIndent) {
              hangIndent = nextStart;
              hangHeadEnd = _contentEnd(reader, r, cols);
            }
          }
          viaWidthJoin = widthJoin;
          r++;
          continue;
        }
        break;
      }
      lines.add(_LogicalLine(glyphs));
      r++;
    }
    return lines;
  }

  /// Whether logical content on local row [r] continues onto row [r]+1.
  ///
  /// Prefer libghostty's AUTHORITATIVE soft-wrap flag. When it is absent — tmux
  /// HARD-wraps with no flag, and an app may wrap NARROWER than the terminal and
  /// pad the rest — fall back to a wrap-COLUMN signal: row [r]'s CONTENT reaches
  /// the inferred [wrapCol] (where wrapped rows actually end — NOT the terminal
  /// edge, which app padding leaves blank) AND row [r]+1 begins with a BARE
  /// continuation. "Bare" excludes a blank/whitespace start, a bullet marker, and
  /// a fresh URL scheme — so a genuinely wrapped URL joins, while a COMPLETE URL
  /// that merely ends a line is NOT merged into the next line's separate content
  /// (#764 over-capture stays fixed).
  ///
  /// #925: emitted (Claude-TUI) output carries a CONSISTENT LEFT INDENT, so a
  /// wrapped continuation row's col 0 is BLANK (the repeated margin) — testing
  /// col 0 literally rejected the join. Test instead at the block's
  /// [blockIndent]: the next row must START at the SAME indent (its content
  /// begins at the block margin, not deeper/shallower — a different margin is a
  /// separate block) AND the first non-blank glyph there is a bare continuation.
  ///
  /// #996: a HANGING indent — the continuation starting DEEPER than the block
  /// margin — is a real TUI wrap shape too (Claude Code's diff view: the first
  /// row's content starts at the line-number gutter, its wrapped tail resumes
  /// under the code column: `      56      curl … https://agent-hub.t` /
  /// `          ailbe5094.ts.net…`). Same-indent evidence is unavailable there
  /// — and the GLOBAL [wrapCol] inference is too: that TUI grid mixes blocks of
  /// DIFFERENT content widths (prose at ~50–55, the diff pane at 48), so the
  /// buffer-wide mode lands on the prose width and the diff row never "reaches"
  /// it. A deeper-indent join therefore demands two pieces of LOCAL evidence
  /// instead:
  ///   1. Row [r] ENDS WITH AN UNTERMINATED-LOOKING URL TOKEN
  ///      ([_endsWithUrlToken]: its last whitespace-delimited token holds a
  ///      scheme) — scoping the new join to exactly the reported class (a URL
  ///      split by a TUI hard-wrap) and leaving every non-URL row pairing —
  ///      prose, paths, diff bodies — byte-identical to the #925 behavior.
  ///   2. COLUMN DISCIPLINE: the continuation row ends at the SAME column as
  ///      row [r] (both hard-wrapped at the block-local content width), OR row
  ///      [r] reaches the global [wrapCol] when that inference does apply.
  ///   3. The continuation's HEAD TOKEN is a PLAUSIBLE URL TAIL
  ///      ([_headLooksLikeUrlTail]: its first whitespace-delimited token holds
  ///      URL structure — `.` `/` `:`). A URL long enough to hard-wrap always
  ///      continues with host/port/path structure (`ailbe5094.ts.net:8444/…`);
  ///      a deeper-indented PROSE line continues with a bare word (`indented
  ///      prose`, `a separately indented paragraph`). This is the gate that
  ///      keeps the pinned #764 guards green: a row ending in a COMPLETE URL
  ///      followed by an indented paragraph shares gates 1–2 (the guards'
  ///      prose rows are full-width too) but fails this one.
  /// REJECTED alternatives: (a) joining ANY deeper-indent continuation —
  /// reopens the #764 over-capture for a complete URL followed by an indented
  /// sub-item (`…example.com/x` + `    which explains…` would glue `/xwhich`);
  /// (b) keying only off the global wrapCol like the same-indent join — the
  /// multi-width TUI grid above defeats it; (c) gates 1–2 without gate 3 —
  /// fails the pinned #764 guards (full-width prose continuation glues);
  /// (d) validating the join by re-running the URL regex on the joined text —
  /// the glued prose ALSO matches (`…/aaindented`), so the result can't
  /// discriminate. KNOWN limitation, kept deliberately: a hanging-indent URL
  /// whose continuation row is SHORT (the URL ends there, nothing follows on
  /// the line) fails gate 2 unless the global wrapCol agrees — extend only
  /// with a real captured trace, not a synthetic one. Residual accepted risk:
  /// a COMPLETE URL row followed, at the same content-end column, by a deeper
  /// bare continuation whose first word carries `.`/`/`/`:` (e.g. a filename)
  /// glues that word onto the payload. A URL spanning 3+ rows only recovers
  /// its first two (the middle row's tail token carries no scheme).
  bool _continuesOnto(
    CellReader reader,
    int r,
    int cols,
    int wrapCol,
    int wrapColCount,
    int blockIndent,
    int hangIndent,
    int hangHeadEnd,
  ) {
    if (reader.rowWrap(r)) return true;
    final end = _contentEnd(reader, r, cols);
    final next = r + 1;
    final nextStart = _contentStart(reader, next, cols);
    if (nextStart >= cols) return false; // blank row
    // #998 B: an ESTABLISHED hanging-indent block (a prior #996 width-join at
    // [hangIndent], which demanded the full URL-token evidence) continues
    // through FURTHER rows without per-row evidence — a hard-wrapped command's
    // middle rows carry no URL token (`…2>/dev/` / `null || echo …` / `&2` in
    // the real 14-06-30 trace; the #996 doc's "extend only with a real
    // captured trace" case). Discipline instead of evidence:
    //   * row [r] is FULL-WIDTH at the block-local wrap column — its content
    //     ends exactly at [hangHeadEnd] (the establishing row's end) or
    //     reaches the global [wrapCol] where that inference applies;
    //   * the continuation's IN-BAND content (at/after [blockIndent] — stray
    //     glyphs a TUI overlay leaves LEFT of the block band, like the trace's
    //     `Ra` spinner residue at col 0, are not block content) starts at
    //     EXACTLY the established hanging indent;
    //   * the continuation does not start a new block (bullet / fresh scheme).
    // Once hanging, ONLY this rule continues the block (no fallthrough to the
    // same-margin rule — a row back at the block margin is a SIBLING entry,
    // not a wrap continuation of the hanging line).
    if (hangIndent > 0) {
      final bandStart = _contentStartFrom(reader, next, cols, blockIndent);
      return bandStart == hangIndent &&
          !_startsNewBlock(reader, next, cols, bandStart) &&
          (end == hangHeadEnd || (wrapCol > 0 && end >= wrapCol - 1));
    }
    // #996: hanging indent — deeper continuation; URL-token + local column
    // discipline evidence required (see the doc comment above).
    if (nextStart > blockIndent &&
        !_startsNewBlock(reader, next, cols, nextStart) &&
        _endsWithUrlToken(reader, r, cols) &&
        _headLooksLikeUrlTail(reader, next, cols, nextStart) &&
        (_contentEnd(reader, next, cols) == end ||
            (wrapCol > 0 && end >= wrapCol - 1))) {
      return true;
    }
    if (wrapCol <= 0) return false;
    // Row r's content must REACH the wrap column (it filled up and wrapped),
    // within 1 col of slack for a trailing wide-char/pad.
    if (end < wrapCol - 1) return false;
    // #925: the continuation row must begin at the SAME left margin as the
    // block. A row whose content starts at a DIFFERENT indent is a separate
    // paragraph/block, not a wrap of this one — keeps #764 two-match behavior
    // for a complete URL followed by a differently-indented line.
    if (nextStart != blockIndent) return false;
    if (_startsNewBlock(reader, next, cols, blockIndent)) return false;
    // #1007: the wrap column must be a PLAUSIBLE wrap boundary, not the head
    // row's own content-end echoed back. [_inferWrapCol] takes the MODE of long
    // rows' end columns, so with exactly ONE long row in the buffer that row
    // self-corroborates: a 38-col `SOMETEXT https://example.com/track993` line
    // in a 55-col grid — provably not wrapped, 17 cols of headroom — "reached"
    // its own wrapCol=38 and glued the next line's leading `1` onto the URL
    // (`…/track9931`, the #993 emulator find). The boundary is trusted as-is
    // when:
    //   * CORROBORATED — at least TWO long rows end there (wrapColCount >= 2):
    //     independent evidence of a consistent app content width (the #767
    //     padded-app device fixture has 3 sibling rows ending at col 12 in a
    //     20-col grid; a URL wrapping across 3+ rows corroborates itself with
    //     its own full continuation rows); OR
    //   * AT/NEAR THE GRID EDGE (wrapCol >= cols - 2) — the terminal itself
    //     wraps there, so even a lone full-width row is a plausible wrap head
    //     (the tmux hard-wrap class). The 2-col tolerance is the widest right
    //     margin any green fixture requires: the REAL captured Claude-TUI
    //     trace (`claude_wrapped_url_55col.cast.json`, the +22..+28
    //     regression) hard-breaks its lone URL head at col 53 in a 55-col
    //     grid — a TUI reserves a small FIXED right margin — and the reach
    //     test's own wide-char/pad slack is 1. Do NOT widen without a real
    //     captured trace: every extra col re-admits #1007-class false joins.
    // Otherwise (a lone long row well short of the grid edge) fall back to the
    // #996-class LOCAL token evidence: the head row must end in an
    // unterminated-looking URL token AND the continuation's head token must
    // look like a URL tail (`.` `/` `:`). This keeps the true single-sample
    // join — the SAME 53-col capture replayed into a REMOUNTED ~94-col grid
    // (#863's widget-tier harness) has no sibling rows and sits far from the
    // new grid's edge, yet its halves carry the URL evidence — while the #993
    // bug's bare `1` continuation fails it. Residual accepted risk (same class
    // as #996's): a lone short COMPLETE-URL row followed at the same margin by
    // a line whose first token carries `.`/`/`/`:` still glues that token.
    final plausibleBoundary = wrapColCount >= 2 || wrapCol >= cols - 2;
    if (!plausibleBoundary &&
        !(_endsWithUrlToken(reader, r, cols) &&
            _headLooksLikeUrlTail(reader, next, cols, nextStart))) {
      return false;
    }
    return true;
  }

  /// Whether local [row]'s LAST whitespace-delimited token looks like a split
  /// URL: it contains a `://` scheme separator or starts with `www.` (#996).
  /// A URL is a single unbroken token, so whichever column a TUI hard-wraps
  /// its first row at, that row's tail token still holds the scheme. Used as
  /// the extra-evidence gate for the deeper-indent (hanging) wrap-join.
  bool _endsWithUrlToken(CellReader reader, int row, int cols) {
    final end = _contentEnd(reader, row, cols);
    var start = end;
    while (start > 0 && !_isBlankCell(reader, row, start - 1)) {
      start--;
    }
    if (start >= end) return false;
    final token =
        _rowHead(reader, row, cols, start, end - start).toLowerCase();
    return token.contains('://') || token.startsWith('www.');
  }

  /// Whether local [row]'s FIRST whitespace-delimited token (starting at
  /// [from], the row's content start) looks like the TAIL of a hard-wrapped
  /// URL: it contains URL structure — a `.`, `/`, or `:` (#996, gate 3 of the
  /// hanging-indent join). A URL long enough to wrap continues with host/
  /// port/path structure; an indented prose continuation starts with a bare
  /// word and must NOT be glued onto a preceding complete URL (#764 guards).
  bool _headLooksLikeUrlTail(CellReader reader, int row, int cols, int from) {
    var to = from;
    while (to < cols && !_isBlankCell(reader, row, to)) {
      to++;
    }
    if (to <= from) return false;
    final token = _rowHead(reader, row, cols, from, to - from);
    return token.contains('.') || token.contains('/') || token.contains(':');
  }

  /// Whether the cell at local ([row], [col]) carries NO visible content — an
  /// empty cell (cleared / wide-char spacer tail) OR a whitespace-only glyph.
  ///
  /// #928: a TUI paints an indented continuation row's LEFT MARGIN either as
  /// truly-blank (cleared) cells OR as literal SPACE glyphs (cursor-forward or
  /// emitted spaces). [CellReader.cellContent] returns `''` for the former but
  /// `' '` for the latter, so testing `.isNotEmpty` alone made an indented
  /// margin's content-start depend on HOW it was painted. The wrap-join's
  /// indent comparison (`nextStart == blockIndent`, #925) then INTERMITTENTLY
  /// failed when a URL's two rows painted their identical margins differently —
  /// the join was rejected and the link truncated to its first row (the device
  /// "wrote 56 chars" copy). Treating a whitespace cell as blank makes the
  /// indent/content boundary depend on VISIBLE content, not paint method.
  bool _isBlankCell(CellReader reader, int row, int col) {
    final ch = reader.cellContent(row, col);
    return ch.isEmpty || ch.trim().isEmpty;
  }

  /// The column of the first non-blank cell on local [row], or [CellReader.cols]
  /// when the row is entirely blank. I.e. the row's LEFT INDENT / content start.
  int _contentStart(CellReader reader, int row, int cols) =>
      _contentStartFrom(reader, row, cols, 0);

  /// [_contentStart] restricted to columns at/after [from] (#998 B): the
  /// hanging-block continuation test reads a row's IN-BAND content start,
  /// ignoring stray glyphs a TUI overlay painted LEFT of the block indent.
  int _contentStartFrom(CellReader reader, int row, int cols, int from) {
    for (var c = from; c < cols; c++) {
      if (!_isBlankCell(reader, row, c)) return c;
    }
    return cols;
  }

  /// The column AFTER the last non-blank cell on local [row] (0 if the row is
  /// blank). I.e. where the row's visible content ends. A whitespace-only cell
  /// is blank (#928): trailing painted spaces are layout padding, not content,
  /// so the wrap-reach gate and [_inferWrapCol] key off VISIBLE content.
  int _contentEnd(CellReader reader, int row, int cols) {
    for (var c = cols - 1; c >= 0; c--) {
      if (!_isBlankCell(reader, row, c)) return c + 1;
    }
    return 0;
  }

  /// Infer the app's effective WRAP COLUMN: the dominant content-end column
  /// among "long" rows (content past the half-width) that are followed by a
  /// non-empty row — i.e. wrap candidates. An app wraps at a consistent column,
  /// so that column dominates; the MODE (ties → higher) is robust against a stray
  /// full-terminal-width row that MAX would wrongly latch onto. Returns 0 when
  /// there are no wrap candidates (nothing to join by width).
  ///
  /// #1007: alongside the column, returns HOW MANY long rows end there (the
  /// mode's count) so [_continuesOnto] can tell a CORROBORATED wrap column (a
  /// consistent app content width shared by >= 2 rows) from a SELF-DEFINED one.
  /// With exactly ONE long row in the buffer, that row's own content-end IS the
  /// mode, making the join gate's `end >= wrapCol - 1` reach test vacuously
  /// true — a 38-col line in a 55-col grid (provably not wrapped: 17 cols of
  /// headroom) self-corroborated and glued the next line's leading `1` onto its
  /// URL (`…/track9931`). The count lets the join demand extra evidence in that
  /// degenerate case without losing the true single-sample joins (see
  /// [_continuesOnto]).
  (int, int) _inferWrapCol(CellReader reader, int rows, int cols) {
    final counts = <int, int>{};
    final threshold = cols ~/ 2;
    for (var r = 0; r < rows - 1; r++) {
      final end = _contentEnd(reader, r, cols);
      if (end <= threshold) continue;
      if (_contentEnd(reader, r + 1, cols) == 0) continue; // next row blank
      counts[end] = (counts[end] ?? 0) + 1;
    }
    var best = 0;
    var bestCount = 0;
    counts.forEach((col, n) {
      if (n > bestCount || (n == bestCount && col > best)) {
        best = col;
        bestCount = n;
      }
    });
    return (best, bestCount);
  }

  /// Whether row [row] STARTS a new block rather than continuing the prior row:
  /// a leading bullet marker (a bullet glyph followed by a space — NOT a URL
  /// hyphen like the '-' in 'mobissh-native', which is followed by a non-space)
  /// or a fresh URL scheme ('http://', 'https://', 'www.'). The test starts at
  /// the block's [indent] (#925) so an INDENTED bullet/scheme is detected — the
  /// repeated left margin is skipped, matching how the continuation row's content
  /// begins at the same indent.
  bool _startsNewBlock(CellReader reader, int row, int cols, int indent) {
    const bullets = {'-', '*', '+', '•', '·', '▪', '◦', '‣'};
    final c0 = reader.cellContent(row, indent);
    if (bullets.contains(c0) &&
        indent + 1 < cols &&
        reader.cellContent(row, indent + 1).isEmpty) {
      return true;
    }
    final head = _rowHead(reader, row, cols, indent, 8).toLowerCase();
    return head.startsWith('http://') ||
        head.startsWith('https://') ||
        head.startsWith('www.');
  }

  /// The first [n] characters of row [row] STARTING at [from] (blank cells as
  /// spaces). Used to inspect a continuation row's head at the block indent.
  String _rowHead(CellReader reader, int row, int cols, int from, int n) {
    final lim = (from + n) < cols ? (from + n) : cols;
    final sb = StringBuffer();
    for (var c = from; c < lim; c++) {
      final ch = reader.cellContent(row, c);
      sb.write(ch.isEmpty ? ' ' : ch);
    }
    return sb.toString();
  }

  /// Map a match's character span `[start, end)` in a logical line back to
  /// per-row [HighlightRange]s. Each contiguous run of glyphs on the SAME
  /// absolute row becomes one range; a wrapped match thus yields one range per
  /// row, each terminating at the match's real last cell on that row.
  List<HighlightRange> _rangesFor(
    List<_Glyph> glyphs,
    int start,
    int end,
    HighlightStyle style,
    Object payload,
  ) {
    final ranges = <HighlightRange>[];
    var i = start;
    while (i < end) {
      final rowAbs = glyphs[i].absRow;
      final startCol = glyphs[i].col;
      var lastCol = startCol;
      i++;
      // Extend while on the SAME row AND col-contiguous. A col GAP breaks the
      // range so the highlight never covers a non-match cell — needed for the
      // OSC-8 source, whose same-URI glyphs can skip cells (an app's wrap padding
      // between the link's rows, or a non-link cell between same-URI cells). The
      // regex path is unaffected: its glyphs come from the padded logical line, so
      // they are always col-contiguous within a row.
      while (i < end &&
          glyphs[i].absRow == rowAbs &&
          glyphs[i].col == lastCol + 1) {
        lastCol = glyphs[i].col;
        i++;
      }
      ranges.add(
        HighlightRange(
          startRow: rowAbs,
          startCol: startCol,
          endRow: rowAbs,
          endCol: lastCol + 1, // exclusive
          background: style.background,
          underline: style.underline,
          payload: payload,
        ),
      );
    }
    return ranges;
  }
}
