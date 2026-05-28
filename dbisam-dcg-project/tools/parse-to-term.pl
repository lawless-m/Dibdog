% Parse a SQL file via the DBISAM DCG and emit the canonical Prolog
% term (ending with `.` and newline). Output is suitable to redirect
% directly into an entry's `expected.term`.
%
% Usage:
%   scryer-prolog -g main parse-to-term.pl -- <path-to-query.sql>
%
% Exit codes:
%   0 — parsed successfully; term written to stdout
%   1 — grammar rejected the SQL
%   2 — file I/O error or invalid invocation

:- use_module(library(os)).
:- use_module(library(pio)).
:- use_module(library(lists)).
:- use_module('../grammar/dcg').

main :-
    (   argv([Path])
    ->  run(Path)
    ;   format(user_error,
               "parse-to-term: expected exactly one positional arg (SQL file path)~n",
               []),
        halt(2)
    ).

run(Path) :-
    catch(
        (   phrase_from_file(statement(Term), Path)
        ->  format("~q.~n", [Term]),
            halt(0)
        ;   format(user_error, "parse-to-term: grammar rejected ~q~n", [Path]),
            halt(1)
        ),
        Err,
        ( format(user_error, "parse-to-term: error ~q~n", [Err]),
          halt(2)
        )
    ).
