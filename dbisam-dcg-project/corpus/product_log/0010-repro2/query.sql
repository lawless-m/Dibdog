select orderh.ref, sum(quantity), sum(cast(cunit as integer)*quantity) from orderh, orderi
where orderh.ref = orderi.ref
and ORDERH.OHINVREF IS NULL
AND ORDERH.INSTATUS=1
AND ORDERH.UF_EXPREPRODATE is not null and 
commodity is not null
group by orderh.ref

union

select quoteh.ref, sum(quantity), sum(cast(cunit as integer)*quantity) from quoteh, quotei
where quoteh.ref = quotei.ref
and QUOTEH.QTRESULTORDERREF IS NULL
AND quoteH.INSTATUS=1
AND quoteH.UF_EXPREPRODATE is not null and 
commodity is not null
group by quoteh.ref

