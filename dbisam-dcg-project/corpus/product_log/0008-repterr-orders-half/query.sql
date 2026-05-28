select 'orders', custcode, sum(valnetbase) from orderh where instatus = 1 and ohinvref is null and extract(month from uf_shipout) = extract(month from current_date()) and extract(year from uf_shipout) = extract(year from current_date())
group by custcode
