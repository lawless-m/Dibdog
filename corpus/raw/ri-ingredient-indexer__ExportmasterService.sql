-- Extracted from: /nonreplicated/Public/java/bitB/ri-ingredient-indexer/src/main/java/com/ramsdens/intl/service/ExportmasterService.java
-- 1 SQL string(s)

-- line 22
SELECT NIINGRED.NIEAN AS niean, NIINGRED.NILDESC AS nildesc, NIINGRED.NIINGREDS AS niingreds, NIINGRED.NIABV AS niabv, NIINGRED.NIMANUFNADD AS nimanufnadd, NIINGRED.NIORIGIN AS niorigin, NIINGRED.NISTORAGE AS nistorage, NIINGRED.NISTORAGETYPE AS nistoragetype, NIINGRED.NINUTRITIONHTML AS ninutritionhtml, NIINGRED.NIPREPUSAGE AS niprepusage, NIINGRED.NICOOKGUIDE AS nicookguide, NIINGRED.NICOOKCONCISE AS nicookconcise, CONCAT(CONCAT(CAST(NIINGRED.NINETWGT, CHAR(10)) WITH ' ') WITH NIINGRED.NIWGTUNIT) AS unit_net_weight FROM NIINGRED WHERE NIINGRED.NIEAN IS NOT NULL AND NIINGRED.NILANG = 'ENGLISH';

