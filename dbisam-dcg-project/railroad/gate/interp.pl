% ============================================================
% interp.pl — the extracted-EBNF interpreter (tokenise + parse)
% ============================================================
%
% Decides whether a raw SQL string is in the language of the extracted
% EBNF (ebnf_rule/2 from grammar.ebnf.pl).
%
% Two stages:
%
%   1. TOKENISE (deterministic, maximal-munch). Whitespace and comments
%      are dropped; the remaining lexemes become tokens. The lexical
%      leaf recognisers are the DCG's OWN — identifier//1,
%      string_literal//1, integer_literal//1, decimal_literal//1 and
%      ws//0 are imported verbatim from grammar/dcg.pl and driven with
%      once/1 to take their greedy (longest) reading. So the tokeniser
%      shares the DCG's lexer rather than re-deriving it; only the
%      word/quoted distinction and the operator set are local.
%
%   2. PARSE the token list against the EBNF IR. Because tokenising
%      removes all lexical non-determinism (no half-consumed identifiers,
%      no 0-vs-1 whitespace choice points), the parser only ever explores
%      genuine grammar choices, which keeps it fast even on the large
%      production queries.
%
% Token shapes:
%   word(Upper)   bare word — may be a keyword OR an identifier
%   qident        "double-quoted" or [bracketed] identifier (never a keyword)
%   str           string literal
%   int           integer literal
%   dec           decimal literal
%   op(Atom)      operator / punctuation
%
% A keyword terminal term("FROM") matches word('FROM'); a leaf(identifier)
% matches word(_) or qident — exactly mirroring the DCG, where a bare
% word can serve as either a keyword or an identifier depending on
% position, while a quoted name can only be an identifier.

:- module(interp, [ebnf_accepts/1, tokenize/2]).

:- use_module('../../grammar/dcg').
:- use_module('../grammar.ebnf.pl').    % explicit .pl: Scryer mis-resolves the dotted name
:- use_module(library(lists)).

:- dynamic(tok/2).
:- dynamic(memo/3).

ebnf_accepts(Chars) :-
    tokenize(Chars, Tokens),
    retractall(tok(_, _)),
    retractall(memo(_, _, _)),
    assert_tokens(Tokens, 0),
    length(Tokens, N),
    once(parse(nt(statement), 0, N)).   % must consume every token

assert_tokens([], _).
assert_tokens([T|Ts], I) :- assertz(tok(I, T)), I1 is I + 1, assert_tokens(Ts, I1).

% ============================================================
% Stage 1 — tokeniser
% ============================================================

tokenize(Chars, Tokens) :-
    skip_ws(Chars, C1),
    tok_loop(C1, Tokens).

tok_loop([], []).
tok_loop(S0, [Tok|Ts]) :-
    S0 = [_|_],
    next_token(S0, Tok, S1),
    skip_ws(S1, S2),
    tok_loop(S2, Ts).

next_token(S0, Tok, S) :-
    ( S0 = ['\''|_]
    -> once(phrase(string_literal(_), S0, S)), Tok = str
    ; S0 = ['"'|_]
    -> once(phrase(identifier(_), S0, S)), Tok = qident
    ; S0 = ['['|_]
    -> once(phrase(identifier(_), S0, S)), Tok = qident
    ; starts_number(S0)
    -> ( once(phrase(decimal_literal(_), S0, S)) -> Tok = dec
       ; once(phrase(integer_literal(_), S0, S)), Tok = int )
    ; S0 = [C|_], ident_start_l(C)
    -> once(phrase(identifier(identifier(Atom)), S0, S)),
       atom_upper(Atom, Up), Tok = word(Up)
    ; match_operator(S0, OpAtom, S)
    -> Tok = op(OpAtom)
    ; fail   % unlexable char (e.g. ODBC `{d '...'}`): not in the language,
    ).       % so tokenising fails and the string is rejected — as the DCG rejects it

starts_number([D|_])      :- digit_l(D).
starts_number(['.', D|_]) :- digit_l(D).

% Operators, longest first (mirrors the DCG's cmp_op / arith / punctuation).
match_operator(S0, Op, S) :- two_char_op(A, B, Op), S0 = [A, B|S].
match_operator([C|S], Op, S) :- one_char_op(C, Op).

two_char_op('<','=','<=').
two_char_op('>','=','>=').
two_char_op('<','>','<>').
two_char_op('!','=','!=').
two_char_op('|','|','||').

one_char_op('(','(').
one_char_op(')',')').
one_char_op(',',',').
one_char_op('.','.').
one_char_op('=','=').
one_char_op('<','<').
one_char_op('>','>').
one_char_op('+','+').
one_char_op('-','-').
one_char_op('*','*').
one_char_op('/','/').
one_char_op('?','?').
one_char_op(';',';').
one_char_op('\\','\\').

% Deterministic, greedy whitespace + comment skip (whitespace is elided,
% so committing to the maximal munch can never change the parse).
skip_ws(S0, S) :- ws_one(S0, S1), !, skip_ws(S1, S).
skip_ws(S, S).

ws_one([C|S], S)            :- ws_char_l(C).
ws_one(['-','-'|S0], S)     :- line_comment_tail(S0, S).
ws_one(['/','*'|S0], S)     :- block_comment_tail(S0, S).

line_comment_tail(['\n'|S], S) :- !.
line_comment_tail(['\r'|S], S) :- !.
line_comment_tail([], []).
line_comment_tail([_|S0], S)   :- line_comment_tail(S0, S).

block_comment_tail(['*','/'|S], S) :- !.
block_comment_tail([_|S0], S)      :- block_comment_tail(S0, S).

% --- char classes (local) ---
ws_char_l(' '). ws_char_l('\t'). ws_char_l('\n'). ws_char_l('\r').
ident_start_l(C) :- alpha_l(C).
ident_start_l('_').
alpha_l(C) :- char_code(C, X), ( X >= 0'a, X =< 0'z ; X >= 0'A, X =< 0'Z ).
digit_l(C) :- char_code(C, X), X >= 0'0, X =< 0'9.

atom_upper(A, U) :- atom_chars(A, Cs), maplist(up_c, Cs, Us), atom_chars(U, Us).
up_c(C, U) :- ( char_code(C, X), X >= 0'a, X =< 0'z -> Y is X - 32, char_code(U, Y) ; U = C ).

% ============================================================
% Stage 2 — packrat parse over the indexed token array
% ============================================================
%
% parse(Node, P0, P): Node derives tokens [P0..P). Nonterminals are
% memoised at rule boundaries (packrat), so each (rule, position) is
% solved once — turning the otherwise-exponential meta-interpreter into
% a polynomial parser. The DCG's alternatives are authored longest-first,
% which makes this PEG-style ordered-choice memo accept the same language;
% the gate's corpus / curated / negative checks verify that empirically.

parse(eps, P, P).
parse(term(T), P0, P) :- tok(P0, Tk), match_term(T, Tk), P is P0 + 1.
parse(leaf(L), P0, P) :- tok(P0, Tk), match_leaf(L, Tk), P is P0 + 1.
% All-solutions memo: cache the full set of end positions a rule can
% reach from P0, computed once, then backtrack over them. This shares
% work (polynomial parsing) while preserving full CFG backtracking — so
% the elided alias guards, which the DCG resolves by backtracking, still
% resolve correctly here. (The grammar has no left recursion, so the
% findall terminates: every recursive call has consumed >= 1 token.)
parse(nt(R), P0, P) :-
    ( memo(R, P0, Sols) -> true
    ; findall(Pe, ( ebnf_rule(R, Node), parse(Node, P0, Pe) ), Raw),
      sort(Raw, Sols),
      assertz(memo(R, P0, Sols))
    ),
    member(P, Sols).
parse(seq([]), P, P).
parse(seq([N|Ns]), P0, P) :- parse(N, P0, P1), parse(seq(Ns), P1, P).
parse(choice([N|_]), P0, P) :- parse(N, P0, P).
parse(choice([_|Ns]), P0, P) :- Ns = [_|_], parse(choice(Ns), P0, P).
parse(opt(N), P0, P) :- parse(N, P0, P).
parse(opt(_), P, P).
parse(zero_or_more(N), P0, P) :- parse(N, P0, P1), P1 > P0, parse(zero_or_more(N), P1, P).
parse(zero_or_more(_), P, P).
parse(one_or_more(N, none), P0, P) :- !, parse(N, P0, P1), parse(zero_or_more(N), P1, P).
parse(one_or_more(N, Sep), P0, P) :- parse(N, P0, P1), parse(zero_or_more(seq([Sep, N])), P1, P).

% A word terminal (keyword) matches a bare-word token, case-insensitively
% (the token text is already upper-cased). A symbol terminal matches an
% operator token exactly.
match_term(T, Tk) :- atom_chars(T, [C0|_]), word_char_l(C0), !, Tk = word(T).
match_term(T, op(T)).

match_leaf(identifier, word(_)).
match_leaf(identifier, qident).
match_leaf(string_literal, str).
match_leaf(integer_literal, int).
match_leaf(decimal_literal, dec).

word_char_l(C) :- alpha_l(C).
word_char_l('_').
