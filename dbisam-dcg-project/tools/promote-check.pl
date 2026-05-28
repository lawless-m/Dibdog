% Promotion check — verifies CORPUS.md promotion-bar criteria 2 and 3
% for a single corpus entry.
%
% Usage:
%   scryer-prolog -g main promote-check.pl -- <query.sql> <expected.term>
%
% Outputs (one per line, to stdout):
%   parsed_term: <Term>
%   roundtrip_term: <Term>
%   term_match: pass | fail
%   roundtrip_match: pass | fail
%
% Returns:
%   exit 0 if both checks pass
%   exit 1 if either check fails (with details printed)

:- use_module(library(os)).
:- use_module(library(pio)).
:- use_module(library(lists)).
:- use_module('../grammar/dcg').

main :-
    (   argv([SqlPath, TermPath])
    ->  run(SqlPath, TermPath)
    ;   format(user_error,
               "promote-check: expected exactly two args (query.sql, expected.term)~n",
               []),
        halt(2)
    ).

run(SqlPath, TermPath) :-
    % Read expected term from file
    open(TermPath, read, S),
    read_term(S, Expected, []),
    close(S),

    % Parse SQL via DCG
    catch(
        phrase_from_file(statement(Actual), SqlPath),
        Err,
        ( format("parse_error: ~q~n", [Err]),
          halt(1)
        )
    ),

    format("parsed_term: ~q~n", [Actual]),

    % Criterion 2: term match
    (   Expected == Actual
    ->  format("term_match: pass~n", []),
        TermOk = true
    ;   format("term_match: fail~n", []),
        format("  expected: ~q~n", [Expected]),
        format("  actual:   ~q~n", [Actual]),
        TermOk = false
    ),

    % Criterion 3: round-trip
    (   catch(roundtrip_term(Actual, RT), _, fail)
    ->  format("roundtrip_term: ~q~n", [RT]),
        (   Actual == RT
        ->  format("roundtrip_match: pass~n", []),
            RtOk = true
        ;   format("roundtrip_match: fail~n", []),
            RtOk = false
        )
    ;   format("roundtrip_term: ERROR~n", []),
        format("roundtrip_match: fail~n", []),
        RtOk = false
    ),

    (   TermOk == true, RtOk == true
    ->  halt(0)
    ;   halt(1)
    ).
