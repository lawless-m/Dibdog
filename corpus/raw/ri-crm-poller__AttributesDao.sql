-- Extracted from: /nonreplicated/Public/java/bitB/ri-crm-poller/src/main/java/com/ramsden/intl/crmpoller/dao/AttributesDao.java
-- 1 SQL string(s)

-- line 17
SELECT PSATTRIB.SACODE, PSATTRIB.SATAG, ATTRIBS.ATDESC FROM PSATTRIB JOIN ATTRIBS ON PSATTRIB.SATAG = ATTRIBS.ATTAG WHERE PSATTRIB.SATAGTYPE = 2;

