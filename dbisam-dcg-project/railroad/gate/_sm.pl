:- use_module(interp).
:- use_module('../../grammar/dcg').
:- use_module(library(format)).
:- initialization((t("SELECT a, b FROM customer"),t("FROMcustomer"),t("SELECT a,,b FROM t"),t("select cast(uf_csa as varchar(10)) from CUSTOMER where uf_csa is not null top 3"),t("SELECT * FROM a LEFT OUTER JOIN b ON a.id=b.id WHERE x>1 AND y<2 ORDER BY x DESC"),t("select cast(code) from CUSTOMER"),halt)).
t(S):-(ebnf_accepts(S)->E=acc;E=rej),(phrase(statement(_),S)->D=acc;D=rej),(E==D->T=ok;T='**MISMATCH**'),format("~w d=~w e=~w ~s~n",[T,D,E,S]).
