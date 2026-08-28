% check.pl — single-query SQL checker over the DBISAM DCG.
%
% Answers, for one SQL statement: does the grammar accept it, what AST
% does it produce, does it round-trip, and — the part the bare grammar
% cannot tell you — which documented over-accepts it walks into, i.e.
% shapes the DCG admits but the live engine rejects.
%
% Usage:
%   scryer-prolog -g main check.pl -- <path-to.sql>
%
% Reads the SQL from a *file*, deliberately. An earlier version kept one
% long-lived process and took jobs over a framed protocol on piped stdin,
% which is ~30x faster per check. Scryer's piped-stdin behaviour is not
% stable across versions though: commit 8dffd72d reads pipes correctly,
% while main (e3df91e2) yields one character and then end_of_file, which
% silently breaks such a protocol (see mthom/scryer-prolog#1472 for the
% wider get_char/EOF trouble). phrase_from_file/2 behaves identically on
% both and is the path every other tool in this repo already uses, so
% correctness does not have to be re-established on each Scryer upgrade.
%
% Output — one `key=value` per line, terminated by a lone `end`. Values
% never contain a newline: writeq escapes them inside quoted atoms, and
% the generator emits single-line SQL. Repeated `warn=` lines are
% permitted.
%
%   verdict=accepted|rejected|error
%   kind=<top-level functor>          (accepted)
%   ast=<canonical Prolog term>       (accepted)
%   generated=<canonical SQL>         (accepted)
%   roundtrip=stable|unstable         (accepted)
%   warn=<CODE>|<message>             (accepted, zero or more)
%   offset=<0-based char offset>      (rejected; `unknown` if the
%                                      statement was too long to locate
%                                      the failure cheaply)
%   message=<text>                    (error)
%   end
%
% Exit codes: 0 accepted, 1 rejected, 2 invocation or I/O error.

:- set_prolog_flag(double_quotes, chars).

:- use_module(library(lists)).
:- use_module(library(format)).
:- use_module(library(os)).
:- use_module(library(pio)).
:- use_module('../../grammar/dcg').
:- use_module('../../grammar/function_sigs.pl').

main :-
    (   argv([Path])
    ->  run(Path)
    ;   format(user_error, "check: usage: check.pl -- <path.sql>~n", []),
        halt(2)
    ).

run(Path) :-
    catch(
        (   phrase_from_file(read_all(Chars), Path)
        ->  check(Chars, Verdict),
            emit(Verdict),
            (   Verdict = accepted(_, _, _, _)
            ->  halt(0)
            ;   halt(1)
            )
        ;   format(user_error, "check: could not read ~q~n", [Path]),
            halt(2)
        ),
        Err,
        (   format(user_error, "check: error ~q~n", [Err]),
            halt(2)
        )
    ).

read_all([C|Cs]) --> [C], read_all(Cs).
read_all([]) --> [].

% ============================================================
% The check itself
% ============================================================

% check(+SqlChars, -Verdict)
%   accepted(Kind, Term, gen(Generated, Roundtrip), Warnings)
%   rejected(FurthestOffset | unknown)
check(Sql, Verdict) :-
    (   parse_statement(Sql, Term)
    ->  functor(Term, Kind, _),
        generated(Term, Gen),
        roundtrip(Term, RT),
        warnings(Term, Warns),
        Verdict = accepted(Kind, Term, gen(Gen, RT), Warns)
    ;   length(Sql, Len),
        diag_char_limit(Limit),
        (   Len =< Limit
        ->  parse_statement_diag(Sql, diag(Furthest)),
            Verdict = rejected(Furthest)
        ;   Verdict = rejected(unknown)
        )
    ).

% parse_statement_diag/2 re-parses with position tracking and costs
% about O(n^2.1) in practice (measured: 0.6s at 500 chars, 11s at 2000,
% 172s at 8000). It runs only on rejected input, which is fine for a
% local tool but not for a service where a caller picks the length. Above
% this many characters, report the rejection without a position rather
% than occupy the checker for minutes. The largest real corpus query is
% 2785 chars, so ordinary work is unaffected; only oversized *rejected*
% input loses its caret.
diag_char_limit(2000).

% The generator is total over terms the parser produces, so a generation
% failure is a real (and interesting) grammar bug rather than a reason to
% lose the parse result — report it as such.
generated(Term, Gen) :-
    (   catch(generate_statement(Term, Cs), _, fail)
    ->  Gen = ok(Cs)
    ;   Gen = failed
    ).

roundtrip(Term, RT) :-
    (   catch(roundtrip_term(Term, Back), _, fail)
    ->  (   Back == Term
        ->  RT = stable
        ;   RT = unstable
        )
    ;   RT = unstable
    ).

% ============================================================
% Divergence warnings
%
% Each rule below detects a shape the DCG accepts and the engine
% rejects, drawn from docs/DIVERGENCES.md. Only the mechanically
% decidable ones live here: the schema-dependent divergences (table
% and column existence, sections 1 and 2) cannot be decided without a
% catalog and are deliberately absent rather than guessed at.
% ============================================================

warnings(Term, Warns) :-
    findall(W, warning(Term, W), Ws),
    sort(Ws, Warns).

% --- DIVERGENCES.md section 8: clause ordering ---
% Modifiers are held in source order, so the check is a subsequence
% test against DBISAM's fixed clause sequence.
warning(Term, w_clause_order(Names)) :-
    sub_term(select_statement(_, _, _, Mods), Term),
    modifier_names(Mods, Names),
    \+ subsequence(Names, [where, group_by, having, order_by, top]).

% --- DIVERGENCES.md section 7: HAVING without GROUP BY ---
warning(Term, w_having_no_group) :-
    sub_term(select_statement(_, _, _, Mods), Term),
    modifier_names(Mods, Names),
    memberchk(having, Names),
    \+ memberchk(group_by, Names).

% --- DIVERGENCES.md section 6: bare UNION inside an IN subquery ---
% UNION ALL is accepted there; bare UNION is not.
warning(Term, w_union_in_subquery) :-
    sub_term(Sub, Term),
    in_rhs_subselect(Sub, Inner),
    sub_term(union(_, _), Inner).

% --- DIVERGENCES.md section 3: literal argument type mismatch ---
% function_sigs.pl records the literal arg shapes the engine actually
% accepted when probed. The grammar checks arity but not type, so a
% call whose args are all literals and whose type shape matches no
% probed shape is an engine rejection waiting to happen.
warning(Term, w_arg_type(Name, Shape)) :-
    sub_term(function_call(Name, Args), Term),
    \+ function_variadic(Name),
    function_arg_shape(Name, _),
    literal_shape(Args, Shape),
    \+ function_arg_shape(Name, Shape).

modifier_names([], []).
modifier_names([M|Ms], [N|Ns]) :-
    functor(M, N, _),
    modifier_names(Ms, Ns).

in_rhs_subselect(in(_, subselect(S)), S).
in_rhs_subselect(not_in(_, subselect(S)), S).

% Succeeds only when EVERY argument is a literal — the only shape the
% probe table can speak to. A column reference makes the call schema-
% and type-dependent, which is the engine's business, not ours.
literal_shape([], []).
literal_shape([A|As], [T|Ts]) :-
    literal_type(A, T),
    literal_shape(As, Ts).

literal_type(integer_literal(_), numeric).
literal_type(decimal_literal(_), numeric).
literal_type(string_literal(_),  string).

subsequence([], _).
subsequence([X|Xs], [Y|Ys]) :-
    (   X == Y
    ->  subsequence(Xs, Ys)
    ;   subsequence([X|Xs], Ys)
    ).

sub_term(T, T).
sub_term(Sub, T) :-
    compound(T),
    T =.. [_|Args],
    member(A, Args),
    sub_term(Sub, A).

% ============================================================
% Record emission
% ============================================================

emit(accepted(Kind, Term, gen(Gen, RT), Warns)) :-
    format("verdict=accepted~n", []),
    format("kind=~w~n", [Kind]),
    format("ast=~q~n", [Term]),
    emit_generated(Gen),
    format("roundtrip=~w~n", [RT]),
    emit_warnings(Warns),
    format("end~n", []).
emit(rejected(Offset)) :-
    format("verdict=rejected~n", []),
    format("offset=~w~n", [Offset]),
    format("end~n", []).

emit_generated(ok(Cs)) :-
    format("generated=~s~n", [Cs]).
emit_generated(failed) :-
    format("generated_error=generator has no clause for this term~n", []).

emit_warnings([]).
emit_warnings([W|Ws]) :-
    emit_warning(W),
    emit_warnings(Ws).

emit_warning(w_clause_order(Names)) :-
    format("warn=DIV8-CLAUSE-ORDER|Clauses appear as ~w. DBISAM requires WHERE, GROUP BY, HAVING, ORDER BY, TOP in that order and rejects any other arrangement with Expected end of statement. See docs/DIVERGENCES.md section 8.~n", [Names]).
emit_warning(w_having_no_group) :-
    format("warn=DIV7-HAVING-NO-GROUP|HAVING without a GROUP BY clause. The grammar accepts it; the engine rejects it. See docs/DIVERGENCES.md section 7.~n", []).
emit_warning(w_union_in_subquery) :-
    format("warn=DIV6-UNION-IN-SUBQUERY|Bare UNION inside an IN subquery. The engine accepts UNION ALL there but rejects bare UNION. See docs/DIVERGENCES.md section 6.~n", []).
emit_warning(w_arg_type(Name, Shape)) :-
    format("warn=DIV3-ARG-TYPE|Call to ~w with literal argument types ~w matches no engine-verified shape for that function. The grammar checks arity but not argument type. See docs/DIVERGENCES.md section 3 and grammar/function_sigs.pl.~n", [Name, Shape]).
