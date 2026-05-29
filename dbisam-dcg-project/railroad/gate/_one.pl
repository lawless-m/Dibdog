:- use_module('../../grammar/dcg').
:- use_module(interp).
:- use_module(library(lists)).
:- use_module(library(format)).
:- initialization(main).
rd(P,Cs) :- open(P,read,S), rc(S,Cs), close(S).
rc(S,Cs) :- get_char(S,C), (C==end_of_file -> Cs=[] ; Cs=[C|R], rc(S,R)).
main :- read_line(L), atom_chars(P,L), rd(P,Cs),
  ( ebnf_accepts(Cs) -> E=acc ; E=rej ),
  ( phrase(statement(_),Cs) -> D=acc ; D=rej ),
  format("~w ~w~n",[D,E]), halt.
read_line(R) :- get_char(C), ( C=='\n' -> R=[] ; g([C],A), reverse(A,R) ).
g(A,R) :- get_char(C), ( C==end_of_file -> A=R ; C=='\n' -> A=R ; g([C|A],R) ).
