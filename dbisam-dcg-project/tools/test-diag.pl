% test-diag.pl — pinned-position regression test for the furthest-failure
% diagnostic (parse_statement_diag/2, grammar/dcg.pl).
%
% Each case is a known-bad SQL string with the furthest 0-based char
% offset the parser reaches before failing. These positions are an
% intentional, stable contract: if the grammar changes such that a case
% now reaches a different point, this test fails and the new value must
% be re-pinned deliberately (not silently). Each case also asserts the
% input is genuinely rejected (parse_statement/2 fails first) — the
% diagnostic is only meaningful post-failure.
%
% Usage:   scryer-prolog -g main tools/test-diag.pl
% Exit:    0 all cases match; 1 at least one mismatch.

:- set_prolog_flag(double_quotes, chars).
:- use_module(library(lists)).
:- use_module(library(format)).
:- use_module('../grammar/dcg').
:- initialization(main).

% case(SQL, ExpectedFurthest)
cases([
    case("select from where",                    17),
    case("select code, from CUSTOMER",           26),
    case("select * from CUSTOMER where IS NULL", 32),
    case("select cast(code) from CUSTOMER",      16),
    case("select (code from CUSTOMER",           13)
]).

main :-
    cases(Cases),
    foldl(check, Cases, 0, Fail),
    ( Fail =:= 0
    -> format("test-diag: all cases passed~n", []), halt(0)
    ;  format("test-diag: ~w case(s) FAILED~n", [Fail]), halt(1)
    ).

check(case(Sql, Expected), F0, F1) :-
    (   parse_statement(Sql, _)
    ->  format("  FAIL  input unexpectedly PARSED :: ~s~n", [Sql]),
        F1 is F0 + 1
    ;   parse_statement_diag(Sql, diag(Got)),
        (   Got =:= Expected
        ->  format("  ok    furthest=~w :: ~s~n", [Got, Sql]),
            F1 = F0
        ;   format("  FAIL  expected=~w got=~w :: ~s~n", [Expected, Got, Sql]),
            F1 is F0 + 1
        )
    ).
