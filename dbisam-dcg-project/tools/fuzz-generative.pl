% fuzz-generative.pl — generative round-trip fuzzer for the DBISAM DCG.
%
% Complements the curated tools/fuzz-roundtrip.pl: instead of a hand-
% picked list, this DETERMINISTICALLY enumerates AST terms from a functor
% signature table and runs the same round-trip contract on each:
%
%     generate_statement(AST, Chars), parse_statement(Chars, AST2),
%     AST == AST2
%
% Enumeration is deterministic (no Math.random / Date) so a run is
% reproducible. It is capped (CAP below); on reaching the cap the run
% stops and says so — truncation is never silent. Terms are emitted
% shallow-first and the connective/precedence shapes (and/or/not nesting,
% arithmetic precedence) are enumerated EXPLICITLY, so the sample covers
% the composition corners where a bidirectional grammar is most likely to
% have a generator/parser asymmetry — not just a cross-product of atoms.
%
% Usage:   scryer-prolog -g main tools/fuzz-generative.pl
% Exit:    0 — every enumerated term round-tripped
%          1 — at least one asymmetry (each printed as FAIL with its SQL)

:- use_module(library(lists)).
:- use_module(library(format)).
:- use_module(library(iso_ext)).
:- use_module('../grammar/dcg').
:- initialization(main).

cap(5000).

% ---------------------------------------------------------------------
% Term generators — deterministic enumeration via backtracking.
% ---------------------------------------------------------------------

% Leaf values. Two "small" leaves feed the combinatorial connective
% shapes (keeps them bounded); the full leaf set feeds atoms and values.
sleaf(identifier(a)).
sleaf(integer_literal(1)).

vleaf(identifier(a)).
vleaf(identifier(b)).
vleaf(integer_literal(1)).
vleaf(string_literal(x)).
vleaf(qualified(identifier(t), identifier(a))).
vleaf(boolean_literal(true)).
vleaf(parameter(positional)).

% Values to depth D (D=0 leaves; D>0 one more compound layer).
v(0, V) :- vleaf(V).
v(D, V) :-
    D > 0, D1 is D - 1,
    (   vleaf(V)
    ;   member(Op, [add, sub, mul, div]), V = arith(Op, A, B), v(D1, A), v(D1, B)
    ;   V = neg(A), v(D1, A)
    ;   V = function_call('ABS', [A]), v(D1, A)
    ;   V = cast(A, type('INTEGER', [])), v(D1, A)
    ;   V = case_when([when(eq(identifier(a), integer_literal(1)), A)], else(B)),
        v(D1, A), v(D1, B)
    ).

% Predicate atoms over values of depth VD.
patom(VD, eq(L, R))                    :- v(VD, L), v(VD, R).
patom(VD, cmp(Op, L, R))               :- member(Op, [lt, gt, le, ge, ne]), v(VD, L), v(VD, R).
patom(VD, truth(V))                    :- v(VD, V).
patom(VD, is_null(V))                  :- v(VD, V).
patom(VD, is_not_null(V))              :- v(VD, V).
patom(VD, like(L, string_literal(z)))  :- v(VD, L).
patom(VD, between(V, Lo, Hi))          :- v(VD, V), v(VD, Lo), v(VD, Hi).
patom(VD, in(V, [A, B]))               :- v(VD, V), v(VD, A), v(VD, B).

% Small atoms — a fixed GROUND set (not a cross-product) so the 3-deep
% connective corners below stay bounded (~6^3 each) and the whole table
% enumerates under the cap. Chosen to span the atom kinds.
satom(eq(identifier(a), integer_literal(1))).
satom(cmp(gt, identifier(a), integer_literal(2))).
satom(cmp(le, identifier(b), integer_literal(3))).
satom(truth(identifier(a))).
satom(is_null(identifier(b))).
satom(like(identifier(a), string_literal(z))).

% Predicates — atoms, then connectives, then EXPLICIT precedence corners.
gen_pred(P)                    :- patom(0, P).
gen_pred(and(L, R))            :- satom(L), satom(R).
gen_pred(or(L, R))             :- satom(L), satom(R).
gen_pred(not(Q))               :- patom(0, Q).
gen_pred(and(or(L, R), S))     :- satom(L), satom(R), satom(S).
gen_pred(or(and(L, R), S))     :- satom(L), satom(R), satom(S).
gen_pred(and(S, or(L, R)))     :- satom(S), satom(L), satom(R).
gen_pred(or(S, and(L, R)))     :- satom(S), satom(L), satom(R).
gen_pred(not(and(L, R)))       :- satom(L), satom(R).
gen_pred(not(or(L, R)))        :- satom(L), satom(R).
gen_pred(and(and(L, R), S))    :- satom(L), satom(R), satom(S).  % left-assoc
gen_pred(and(S, and(L, R)))    :- satom(S), satom(L), satom(R).  % right-assoc (needs parens)
gen_pred(or(or(L, R), S))      :- satom(L), satom(R), satom(S).
gen_pred(or(S, or(L, R)))      :- satom(S), satom(L), satom(R).

% Values for the projection slot — depth-1 plus explicit arithmetic
% precedence corners (paren insertion is the round-trip risk here).
gen_val(V)                                  :- v(1, V).
gen_val(arith(add, arith(mul, A, B), C))    :- sleaf(A), sleaf(B), sleaf(C).
gen_val(arith(mul, A, arith(add, B, C)))    :- sleaf(A), sleaf(B), sleaf(C).  % needs parens
gen_val(arith(sub, A, arith(sub, B, C)))    :- sleaf(A), sleaf(B), sleaf(C).  % needs parens
gen_val(neg(arith(add, A, B)))              :- sleaf(A), sleaf(B).

% ---------------------------------------------------------------------
% Scaffolds — wrap a predicate in WHERE, a value in a projection slot.
% ---------------------------------------------------------------------
gen_ast(select_statement(all_rows, [V], [table(identifier(t), no_alias)], [])) :-
    gen_val(V).
gen_ast(select_statement(all_rows, [identifier(code)],
                         [table(identifier(t), no_alias)], [where(P)])) :-
    gen_pred(P).

% ---------------------------------------------------------------------
% Driver — bounded fail-driven loop; the cap is enforced with a
% non-backtrackable counter and an exception to break out cleanly.
% ---------------------------------------------------------------------
main :-
    cap(Cap),
    bb_put(fg_idx, 0),
    bb_put(fg_fail, 0),
    catch(fuzz_loop(Cap), Stop, true),
    bb_get(fg_idx, Gen),
    bb_get(fg_fail, Fails),
    ( Stop = capped -> Checked = Cap ; Checked = Gen ),
    format("fuzz-generative: ~w terms enumerated, ~w checked, ~w failed~n",
           [Gen, Checked, Fails]),
    ( Stop = capped
    -> format("  NOTE: hit cap ~w — enumeration truncated here (not silent)~n", [Cap])
    ;  format("  enumeration exhausted below cap ~w (full coverage of the table)~n", [Cap])
    ),
    ( Fails =:= 0 -> halt(0) ; halt(1) ).

fuzz_loop(Cap) :-
    (   gen_ast(AST),
        bb_get(fg_idx, I0), I1 is I0 + 1, bb_put(fg_idx, I1),
        ( I1 > Cap -> throw(capped) ; true ),
        ( roundtrip_ok(AST) -> true ; note_fail(AST) ),
        fail
    ;   throw(exhausted)
    ).

roundtrip_ok(AST) :-
    catch(( generate_statement(AST, Chars),
            parse_statement(Chars, AST2),
            AST == AST2 ),
          _, false).

note_fail(AST) :-
    (   catch(generate_statement(AST, Chars), _, fail)
    ->  ( catch(parse_statement(Chars, AST2), _, (AST2 = '$parse_error'))
        -> true ; AST2 = '$parse_failed' ),
        format("FAIL: ~q~n  sql:      ~s~n  reparsed: ~q~n", [AST, Chars, AST2])
    ;   format("FAIL: ~q~n  generate: FAILED~n", [AST])
    ),
    bb_get(fg_fail, F0), F1 is F0 + 1, bb_put(fg_fail, F1).
