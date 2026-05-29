% ============================================================
% gate.pl — the railroad equivalence gate
% ============================================================
%
% Proves the extracted EBNF (grammar.ebnf.pl) accepts the same SQL
% language as the DCG (grammar/dcg.pl). Three complementary checks:
%
%   1. CORPUS REPLAY (necessary). Every corpus query is parsed by BOTH
%      the DCG and the EBNF; their accept/reject verdicts must agree.
%      Corpus paths arrive on stdin, one per line.
%
%   2. DCG→EBNF DIFFERENTIAL (the strong necessary check). The DCG run
%      backwards — generate_statement/2 — emits canonical SQL for a
%      broad curated AST set spanning every grammar feature; the EBNF
%      must parse each. If the extractor narrowed the language anywhere
%      (a dropped construct, a mis-fired `_list` fold), this fails.
%
%   3. OVER-PERMISSIVENESS NEGATIVES (guards against widening). A set of
%      malformed strings the DCG rejects — heavy on fold edge-cases
%      (`a,,b`, `,a`, `a,`, dangling separators) — must ALSO be rejected
%      by the EBNF. This is the EBNF→DCG direction made automatable:
%      free generation from the EBNF would mostly re-discover the
%      semantic guards the syntax-only diagrams intentionally elide
%      (function-name/arity validity, alias-terminator look-ahead), so
%      we probe over-permissiveness with targeted negatives instead.
%
% Exit 0 iff all three pass; exit 1 (loudly, naming offenders) otherwise.

% dcg is imported ONLY by interp (Scryer corrupts dcg's discontiguous
% generate_statement if two modules import dcg). We reach the DCG through
% interp's dcg_accepts/1 and dcg_generate/2.
:- use_module(interp).
:- use_module(curated).
:- use_module(library(lists)).
:- use_module(library(format)).

% Entry points are selected by `scryer-prolog -g <goal>` rather than by
% reading stdin: get_char on a pipe under -g races EOF on tiny inputs and
% hangs. The gate runs as bounded short-lived processes (one process over
% the whole corpus + curated + negatives grows heap past the box memory),
% orchestrated by run.sh:
%   -g run_curated            the curated differential
%   -g run_negatives          the over-permissiveness negatives
%   -g "corpus('paths.txt')"  corpus replay for the batch listed in the file

run_curated :-
    curated_check(Fails, N),
    report("DCG->EBNF curated  ", N, Fails),
    ( Fails == [] -> halt(0) ; halt(1) ).

run_negatives :-
    negative_check(Fails, N),
    report("over-perm negatives", N, Fails),
    ( Fails == [] -> halt(0) ; halt(1) ).

% Corpus batch: read the newline-separated paths from File and print one
% line per outcome so run.sh can aggregate.
%   DIVERGE <term>   a real disagreement (gate fails)
%   DOC <term>       a documented elided-guard divergence (informational)
corpus(File) :-
    read_lines_file(File, Paths),
    replay_paths(Paths, Fails, Docs),
    print_lines("DOC", Docs),
    print_lines("DIVERGE", Fails),
    ( Fails == [] -> halt(0) ; halt(1) ).

print_lines(_, []).
print_lines(Tag, [X|Xs]) :- format("~w ~q~n", [Tag, X]), print_lines(Tag, Xs).

report(Label, N, Fails) :-
    length(Fails, NF),
    P is N - NF,
    ( NF =:= 0
    -> format("  [~s]  ~w/~w ok~n", [Label, P, N])
    ;  format("  [~s]  ~w/~w ok — ~w FAILED:~n", [Label, P, N, NF]),
       print_fails(Fails)
    ).

print_fails([]).
print_fails([F|Fs]) :- format("        ~q~n", [F]), print_fails(Fs).

% ------------------------------------------------------------
% 1. Corpus replay
% ------------------------------------------------------------

replay_paths([], [], []).
replay_paths([Path|Ps], Fails, Docs) :-
    ( replay_one(Path, R)
    -> ( R == none            -> Fails = Fs, Docs = Ds
       ; R = documented(_, _) -> Fails = Fs, Docs = [R|Ds]
       ; Fails = [R|Fs], Docs = Ds
       )
    ;  Fails = [corpus_error(Path)|Fs], Docs = Ds
    ),
    replay_paths(Ps, Fs, Ds).

replay_one(Path, Result) :-
    read_file_chars(Path, Chars),
    dcg_verdict(Chars, D),
    ebnf_verdict(Chars, E),
    ( D == E
    -> Result = none
    ;  documented_divergence(Chars, Why)
    -> Result = documented(Path, Why)
    ;  Result = corpus_divergence(Path, dcg(D), ebnf(E))
    ).

% Known, documented divergences: the DCG rejects (semantic guard) but
% the SYNTAX-ONLY EBNF accepts, because the diagrams intentionally elide
% the DCG's `{...}` semantic guards (per the doc: "No semantic
% annotations in the track"). Matched by normalised token sequence so
% whitespace/case don't matter. Each is genuine and worth knowing — it
% marks where a prose note belongs beneath the diagram, not a bug.
documented_divergence(Chars, Why) :-
    tokenize(Chars, Toks),
    expected_divergent(SampleSql, Why),
    tokenize(SampleSql, SampleToks),
    Toks == SampleToks.

% A bare `CAST(x)` (no `AS type`) parses against the syntax-only
% function_call rule `identifier "(" args ")"`; the DCG rejects it
% because CAST is a special form (needs `AS`) and is not in the
% verified valid_function/1 catalogue — a semantic guard the track omits.
expected_divergent("select cast(code) from CUSTOMER",
    'CAST without AS: matches the generic function-call shape; the DCG\'s valid_function / cast-AS guard (elided from the diagram) rejects it').

dcg_verdict(Chars, V) :- ( dcg_accepts(Chars) -> V = accept ; V = reject ).
ebnf_verdict(Chars, V) :- ( ebnf_accepts(Chars) -> V = accept ; V = reject ).

% ------------------------------------------------------------
% 2. DCG→EBNF curated differential
% ------------------------------------------------------------

curated_check(Fails, N) :-
    curated_asts(Asts),
    length(Asts, N),
    check_asts(Asts, Fails).

check_asts([], []).
check_asts([Ast|As], Fails) :-
    ( catch(dcg_generate(Ast, Chars), _, fail)
    -> ( ebnf_accepts(Chars)
       -> Fails = Rest
       ;  Fails = [ebnf_rejected_dcg_sentence(Ast, Chars)|Rest]
       )
    ;  Fails = [generate_failed(Ast)|Rest]   % AST the DCG can't even emit
    ),
    check_asts(As, Rest).

% ------------------------------------------------------------
% 3. Over-permissiveness negatives
% ------------------------------------------------------------

negative_check(Fails, N) :-
    negatives(Negs),
    length(Negs, N),
    check_negs(Negs, Fails).

check_negs([], []).
check_negs([Str|Ss], Fails) :-
    ( dcg_accepts(Str)
    -> Fails = [negative_not_invalid(Str)|Rest]   % bad test datum: DCG accepts it
    ;  ( ebnf_accepts(Str)
       -> Fails = [ebnf_over_permissive(Str)|Rest]
       ;  Fails = Rest
       )
    ),
    check_negs(Ss, Rest).

% Malformed statements the DCG rejects. Heavy on the fold (the one
% risky transform): empty list slots, doubled/leading/trailing
% separators, and unterminated loops.
negatives([
    % --- bare breakage ---
    "SELECT FROM t",
    "SELECT a FROM",
    "FROM t",
    "SELECT a b c FROM t",
    % --- column-list fold ---
    "SELECT a, FROM t",
    "SELECT , a FROM t",
    "SELECT a,,b FROM t",
    "SELECT a, b, FROM t",
    % --- from / join ---
    "SELECT a FROM ,t",
    "SELECT a FROM t,",
    "SELECT a FROM t,,u",
    "SELECT * FROM a JOIN b",
    "SELECT * FROM a JOIN b ON",
    % --- value / in lists ---
    "SELECT a FROM t WHERE x IN ()",
    "SELECT a FROM t WHERE x IN (1,)",
    "SELECT a FROM t WHERE x IN (,1)",
    "SELECT a FROM t WHERE x IN (1,,2)",
    % --- predicate chains ---
    "SELECT a FROM t WHERE x = 1 AND",
    "SELECT a FROM t WHERE AND x = 1",
    "SELECT a FROM t WHERE x = 1 OR OR y = 2",
    % --- group/order fold ---
    "SELECT a FROM t GROUP BY",
    "SELECT a FROM t GROUP BY a,",
    "SELECT a FROM t ORDER BY ,a",
    "SELECT a FROM t ORDER BY a,,b",
    % --- union loop (second select incomplete; a trailing bare keyword
    %     after a table would instead trip the elided alias guard, so these
    %     keep a following SELECT to probe the loop itself) ---
    "SELECT a FROM t UNION SELECT b FROM",
    "SELECT a FROM t UNION ALL SELECT b FROM",
    % --- update set-list fold ---
    "UPDATE t SET a = 1,",
    "UPDATE t SET a = 1,, b = 2",
    "UPDATE t SET",
    % --- index col-list fold ---
    "CREATE INDEX i ON t ()",
    "CREATE INDEX i ON t (a,)",
    "CREATE INDEX i ON t (a,,b)",
    % --- insert col / value fold ---
    "INSERT INTO t (a,) VALUES (1)",
    "INSERT INTO t (a) VALUES (1,)",
    "INSERT INTO t (a) VALUES ()",
    % --- arithmetic ---
    "SELECT 1 + FROM t",
    "SELECT a FROM t WHERE x BETWEEN 1",
    "SELECT a FROM t WHERE x BETWEEN 1 AND"
]).

% ------------------------------------------------------------
% Reading helpers
% ------------------------------------------------------------

% Read newline-separated paths from a file (get_char on an opened file
% is reliable, unlike on a pipe).
read_lines_file(File, Lines) :-
    open(File, read, S),
    read_lines(S, Lines),
    close(S).

read_lines(S, Lines) :-
    get_char(S, C),
    ( C == end_of_file -> Lines = []
    ; C == '\n'        -> read_lines(S, Lines)            % skip blanks
    ; gather_line(S, [C], L), atom_chars(P, L),
      Lines = [P|Rest], read_lines(S, Rest)
    ).

gather_line(S, Acc, L) :-
    get_char(S, C),
    ( C == end_of_file -> reverse(Acc, L)
    ; C == '\n'        -> reverse(Acc, L)
    ; gather_line(S, [C|Acc], L)
    ).

read_file_chars(Path, Chars) :-
    open(Path, read, S),
    read_chars(S, Chars),
    close(S).

read_chars(S, Chars) :-
    get_char(S, C),
    ( C == end_of_file -> Chars = []
    ; Chars = [C|Rest], read_chars(S, Rest)
    ).
