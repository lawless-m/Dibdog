% Grammar harness runner — long-running variant.
%
% Reads one SQL file path per line from stdin, parses each via the DCG,
% writes the result as one atom per line to stdout (flushed). EOF on
% stdin (or an empty line) terminates the loop.
%
% Protocol (paired):
%   bash → scryer:  "/abs/path/to/query.sql\n"
%   scryer → bash:  one of:
%     parsed             — DCG accepted; entry has no expected.term to match
%     parsed_match       — DCG accepted; parsed term `==` expected.term
%     parsed_drift       — DCG accepted; parsed term DIFFERS from expected.term
%     failed             — DCG rejected the input
%     no_grammar         — no DCG rule for `statement` defined
%     io_error           — couldn't read query.sql or expected.term
%     error(<term>)      — other Prolog error
%
% The runner looks for `expected.term` in the same directory as the
% supplied query.sql. If present, the parsed term is unified against
% it; mismatch surfaces as `parsed_drift` so the differential
% harness's `failing` axis catches term-shape regressions on
% meaningful/scaffolded entries (per CORPUS.md "Promotion bar"
% criterion 2 as a *runtime* invariant, not just at promotion time).
%
% The 1-line-in 1-line-out shape lets `run.sh` pair paths with results
% by simple FIFO ordering — no JSON, no IPC complexity.
%
% Per ANTI_STUBS.md, `statement//1` is supplied by the DCG module
% (../../grammar/dcg.pl). Constructs without rules must fail loudly
% with `failed`, not pass via a stub.

:- use_module(library(lists)).
:- use_module(library(pio)).
:- use_module(library(format)).
:- use_module('../../grammar/dcg').

main :- read_loop.

read_loop :-
    read_one_line(Line),
    (   Line == end_of_file
    ->  halt
    ;   Line == []
    ->  halt
    ;   atom_chars(Path, Line),
        classify(Path, Result),
        format("~q~n", [Result]),
        flush_output,
        read_loop
    ).

read_one_line(Result) :-
    get_char(C),
    (   C == end_of_file
    ->  Result = end_of_file
    ;   C == '\n'
    ->  Result = []
    ;   gather([C], Acc),
        reverse(Acc, Result)
    ).

gather(Acc, Result) :-
    get_char(C),
    (   C == end_of_file
    ->  Acc = Result
    ;   C == '\n'
    ->  Acc = Result
    ;   gather([C|Acc], Result)
    ).

classify(Path, Result) :-
    catch(
        (   phrase_from_file(statement(Term), Path)
        ->  classify_match(Path, Term, Result)
        ;   Result = failed
        ),
        Err,
        classify_error(Err, Result)
    ).

% Parsed cleanly — now check whether an expected.term file is co-located
% with the query.sql and, if so, whether the parsed term matches it.
%
% Path layout per CORPUS.md: `<entry>/query.sql` and `<entry>/expected.term`
% live in the same directory.
classify_match(SqlPath, Term, Result) :-
    expected_term_path(SqlPath, ExpectedPath),
    (   exists_file_p(ExpectedPath)
    ->  read_term_file(ExpectedPath, Expected, ReadErr),
        (   ReadErr == none
        ->  (   Expected == Term
            ->  Result = parsed_match
            ;   Result = parsed_drift
            )
        ;   Result = ReadErr     % typically io_error
        )
    ;   Result = parsed
    ).

% Replace the trailing "query.sql" with "expected.term" in the path
% to derive the expected-term file location.
expected_term_path(SqlPath, TermPath) :-
    atom_chars(SqlPath, Chars),
    reverse(Chars, RChars),
    atom_chars(SqlFileSuffix, ['l','q','s','.','y','r','e','u','q']),
    atom_chars(SqlFileSuffix, SfxRChars),
    append(SfxRChars, RestR, RChars),
    !,
    reverse(RestR, BaseChars),
    atom_chars(Term, ['e','x','p','e','c','t','e','d','.','t','e','r','m']),
    atom_chars(Term, TermChars),
    append(BaseChars, TermChars, AllChars),
    atom_chars(TermPath, AllChars).

% Test for file existence by attempting to open it for reading.
% Avoids depending on a `exists_file/1` builtin that may not be
% present in every Scryer version.
exists_file_p(Path) :-
    catch(
        ( open(Path, read, S),
          close(S)
        ),
        _,
        fail
    ).

read_term_file(Path, Term, ErrKind) :-
    catch(
        ( open(Path, read, S),
          read_term(S, T, []),
          close(S),
          Term = T,
          ErrKind = none
        ),
        Err,
        ( classify_error(Err, ErrKind),
          Term = '$read_failed'
        )
    ).

classify_error(error(existence_error(procedure, _), _), no_grammar).
classify_error(error(existence_error(source_sink, _), _), io_error).
classify_error(Err, error(Err)).
