-- Extracted from: /nonreplicated/Public/java/bitB/ri-crm-poller/src/main/java/com/ramsden/intl/crmpoller/dao/CustomerDao.java
-- 1 SQL string(s)

-- line 22
SELECT Customer.CODE, Customer.CPYNAME, Customer.CUSCLASS, Customer.PROFILE, Customer.CURR, Customer.TERR, Exchange.RATE, Exchange.DESC, Customer.UF_ALTPROF1, Customer.UF_ALTPROF2, Customer.UF_ALTPROF3, Customer.UF_ALTPROF4, Customer.UF_ALTPROF5, Customer.UF_ALTPROF6, Customer.UF_ALTPROF7, Customer.UF_ALTPROF8, Customer.UF_ALTPROF9, Customer.UF_ALTPROF10, Customer.UF_ALTPROF11, IF (profile.sppversion > 0, 'Y', 'N') AS PROMOTION FROM Customer Join Profile on customer.profile = profile.sppcode JOIN Exchange ON Customer.CURR = Exchange.CODE WHERE Customer.CODE = ?;

