# The hook-bypass scan's quoted-newline join fails open past its cap

The scanner joins lines while a quote is open, so `--no-{"x<newline>y",verify}` is read as bash builds it. That join stops after 20 lines or 4096 characters and the joined text is dropped unjudged, which is a deliberate fail-open (C9). Each line was already judged alone, so dropping the join only loses routes that need a quoted newline in the middle of a brace group. A quote left open by mistake, a long heredoc or a multi-line message would otherwise be read as one growing word, and failing closed there would refuse ordinary files that carry an unbalanced apostrophe in prose or a long quoted string.

The brace expansion cap fails the other way. Past 4096 characters expansion stops, and the line is refused when a word holding a brace group could still spell `--no-v` from its characters in order, since brace expansion never reorders them. That case is a single word bash would build in one step, so refusing it costs only the rare minified line whose characters happen to contain that sequence, while passing it would let any route through by padding the line.

The join's cap stays listed as still open in the CHANGELOG entry for card 991.
