select ref, evcustomer, evregst, evvatno, evterms, evdestst, evtrantype, evmode, evind, currrate from orderh where sellco = 3 and ohinvdate > current_date() -60
