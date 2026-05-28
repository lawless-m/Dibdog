select saref, sacust, sainv, sadate, sum(saval) from analysis group by saref, sacust, sainv, sadate
