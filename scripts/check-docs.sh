#!/bin/bash
# Fails (exit 1, listing what is missing) when docs/API.md does not mention every shipped symbol:
#   - every public/open declaration in the library targets (Sources/ExactJPEG, Sources/ExactJPEGC): types as
#     `Name`, members as `Type.member`, functions and inits with their argument labels, e.g.
#     `Decoder.decode(bytes:format:output:)`, `Encoder.init(ctx:)`, `parseJPEGHeader(_:)`; cases of public enums as
#     `Enum.case`; the @_cdecl C entry points of ExactJPEGC by their C name (`ejm_decode`);
#   - every function, typedef, enum constant and #define in include/exact_jpeg.h;
#   - every EJM_* environment variable read anywhere in Sources or Tools/Sources (the ejm tool).
# A symbol counts as mentioned when it appears in docs/API.md as a whole word (grep -Fw).
#   ./scripts/check-docs.sh          check (cheap: no build, no Metal)
#   ./scripts/check-docs.sh --list   print the symbols it requires, one per line
# Limitations: ShaderSource.swift is skipped (generated, internal, holds Metal source in raw strings); enum cases
# are found only on `case` lines inside a public enum whose body spans several lines; declarations are expected
# to open their body on the same line (the style of this code base).
set -euo pipefail
cd "$(dirname "$0")/.."
doc=docs/API.md

read -r -d '' SWIFT_PL <<'PERL' || true
local $/; my $src = <>;
# blank out string literals and comments so braces and keywords inside them do not count
$src =~ s{("(?:[^"\\\n]|\\.)*")|//[^\n]*|/\*.*?\*/}{defined $1 ? '""' : ''}gse;
my @lines = split /\n/, $src;
my $depth = 0; my @stack;                        # [type name, body depth, is a public enum]

sub split_top {                                  # split at commas outside () [] <>
    my ($s) = @_; my @parts; my ($d, $cur) = (0, '');
    for my $c (split //, $s) {
        if ($c =~ /[(\[<]/) { $d++ } elsif ($c =~ /[)\]>]/) { $d-- }
        if ($c eq ',' && $d == 0) { push @parts, $cur; $cur = '' } else { $cur .= $c }
    }
    push @parts, $cur if $cur =~ /\S/;
    return @parts;
}
sub params {                                     # text inside the first balanced (...) of $s
    my ($s) = @_; my ($d, $body) = (1, '');
    for my $c (split //, $s) { $d++ if $c eq '('; $d-- if $c eq ')'; last if $d == 0; $body .= $c }
    return $body;
}
sub labels { join '', map { /^\s*(\w+)/ ? "$1:" : '' } split_top($_[0]) }
sub names { my ($s) = @_; $s =~ s/\{.*$//s; map { /^\s*(\w+)/ ? $1 : () } split_top($s) }

for (my $i = 0; $i < @lines; $i++) {
    my $l = $lines[$i];
    if ($l =~ /\b(?:public|open)\b/) {           # join a multi-line signature until its parentheses balance
        while (($l =~ tr/(//) > ($l =~ tr/)//) && $i + 1 < @lines) { $l .= ' ' . $lines[++$i] }
    }
    my $pfx = @stack ? "$stack[-1][0]." : '';
    if ($l =~ /\b(?:public|open)\b(?:\s+(?:final|static|class|override|mutating|nonisolated(?:\(unsafe\))?|(?:private|fileprivate|internal)\(set\)))*\s+(struct|class|enum|protocol|typealias|func|init|var|let|case)\b\s*(.*)$/) {
        my ($kw, $rest) = ($1, $2);
        if ($kw =~ /^(?:struct|class|enum|protocol|typealias)$/) {
            print "$pfx$1\n" if $rest =~ /^(\w+)/;
        } elsif ($kw eq 'func') {
            if ($rest =~ /^(\w+)\s*(?:<[^>]*>)?\s*\((.*)$/) {
                my ($n, $p) = ($1, $2);
                if ($n =~ /^ejm_/) { print "$n\n" }          # C entry points: documented by their C name
                else { print "$pfx$n(" . labels(params($p)) . ")\n" }
            }
        } elsif ($kw eq 'init') {
            print "${pfx}init(" . labels(params($1)) . ")\n" if $l =~ /\binit\s*[?!]?\s*\((.*)$/;
        } else {                                  # var, let, case: possibly several names on one line
            print "$pfx$_\n" for names($rest);
        }
    } elsif (@stack && $stack[-1][2] && $depth == $stack[-1][1] && $l =~ /^\s*(?:indirect\s+)?case\s+(.*)$/) {
        print "$pfx$_\n" for names($1);           # cases of a public enum (no access modifier of their own)
    }
    if ($l =~ /\b(struct|class|enum|protocol|extension|actor)\s+(\w+)/) {
        my ($kind, $name) = ($1, $2);
        my $pub = ($kind eq 'enum' && $l =~ /\b(?:public|open)\b/) ? 1 : 0;
        push @stack, [$name, $depth + 1, $pub] if $l =~ /\{/;
    }
    for my $c (split //, $l) {
        if ($c eq '{') { $depth++ }
        elsif ($c eq '}') { $depth--; pop @stack while @stack && $depth < $stack[-1][1] }
    }
}
PERL

read -r -d '' C_PL <<'PERL' || true
s{/\*.*?\*/}{}g; s{//.*}{};
if (/^\s*#\s*define\s+(\w+)/) { print "$1\n"; next }
if (/^\s*typedef\b.*?(\w+)\s*;/) { print "$1\n"; next }
if (/^\s*enum\s*\{(.*)\}/) { my $b = $1; print "$_\n" for ($b =~ /\b([A-Za-z_]\w*)\s*(?:=[^,]*)?(?:,|$)/g); next }
print "$1\n" if /\b(ejm_\w+)\s*\(/;
PERL

symbols() {
  for f in Sources/ExactJPEG/*.swift Sources/ExactJPEGC/*.swift; do
    case "$f" in */ShaderSource.swift) continue ;; esac
    perl -e "$SWIFT_PL" "$f"
  done
  perl -ne "$C_PL" include/exact_jpeg.h
  grep -rhoE 'environment\["EJM_[A-Z0-9_]+"\]|getenv\("EJM_[A-Z0-9_]+"\)' Sources Tools/Sources | grep -oE 'EJM_[A-Z0-9_]+'
}

all="$(symbols | sort -u)"
if [ "${1:-}" = "--list" ]; then echo "$all"; exit 0; fi
[ -f "$doc" ] || { echo "FAIL: $doc missing"; exit 1; }
missing=()
while IFS= read -r s; do
  [ -n "$s" ] || continue
  grep -qFw -- "$s" "$doc" || missing+=("$s")
done <<< "$all"
n=$(printf '%s\n' "$all" | grep -c .)
if [ ${#missing[@]} -gt 0 ]; then
  echo "FAIL: ${#missing[@]} of $n shipped symbols are not mentioned in $doc:"
  printf '  %s\n' "${missing[@]}"
  exit 1
fi
echo "docs: all $n shipped symbols are mentioned in $doc"
