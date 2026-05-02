/**
 * ReferralROIService — reads the Referral_ROI_Attribution__cio Data Cloud CI
 * to produce per-rep ROI summaries and per-physician ROI rows.
 *
 * Data Cloud CI produces one row per (rep × physician) for physicians with
 * at least one arrived admission attributed to the rep. "Needs Attention" —
 * physicians the rep visited but has NOT converted — is derived via SOQL
 * because the CI excludes zero-arrival pairs.
 *
 * Referral counts come from SOQL (CSR via HealthcareProvider → Contact)
 * because the CI does not compute them.
 */
public with sharing class ReferralROIService {

    public class ReferralROIException extends Exception {}

    // CI identifiers — per docs/uc7-ci-live-handover.md
    private static final String CI_DMO = 'Referral_ROI_Attribution__cio';
    private static final Decimal REVENUE_PER_ADMISSION = 210000;

    // ===== DTOs =====

    public class RepROISummary {
        @AuraEnabled public String quarter;
        @AuraEnabled public Decimal totalAttributedRevenue;
        @AuraEnabled public Integer totalArrivedPatients;
        @AuraEnabled public Integer totalReferrals;
        @AuraEnabled public Integer totalContributingPhysicians;
        @AuraEnabled public List<PhysicianROIRow> topByROI;
        @AuraEnabled public List<PhysicianROIRow> needsAttention;
        // Company-wide — aggregated across all reps for the quarter.
        // Sorted by totalRevenue desc. Per-row: physicianName, specialty,
        // attributedRevenue (company total), arrivedCount (company total).
        @AuraEnabled public List<PhysicianROIRow> topPhysiciansCompanyWide;

        public RepROISummary() {
            this.topByROI = new List<PhysicianROIRow>();
            this.needsAttention = new List<PhysicianROIRow>();
            this.topPhysiciansCompanyWide = new List<PhysicianROIRow>();
            this.totalAttributedRevenue = 0;
            this.totalArrivedPatients = 0;
            this.totalReferrals = 0;
            this.totalContributingPhysicians = 0;
        }
    }

    public class PhysicianROIRow {
        @AuraEnabled public String contactId;
        @AuraEnabled public String physicianName;
        @AuraEnabled public String specialty;
        @AuraEnabled public Decimal attributedRevenue;
        @AuraEnabled public Integer arrivedCount;
        @AuraEnabled public Integer referralCount;
    }

    public class PhysicianROI {
        @AuraEnabled public String contactId;
        @AuraEnabled public String physicianName;
        @AuraEnabled public String specialty;
        @AuraEnabled public String quarter;
        @AuraEnabled public Integer referralCount;
        @AuraEnabled public Integer arrivedCount;
        @AuraEnabled public Decimal attributedRevenue;
    }

    // ===== Public API =====

    @AuraEnabled(cacheable=true)
    public static RepROISummary getRepROISummary(String userId) {
        if (String.isBlank(userId)) {
            userId = UserInfo.getUserId();
        }
        String currentQuarter = computeCurrentQuarter();

        // 1. Query CI for physicians this rep has attributed arrivals with
        List<PhysicianROIRow> attributedRows = queryCIForRep(userId);

        // 2. Enrich attributed rows with referral counts via SOQL
        Map<Id, Integer> referralCountByContactId = computeReferralCountsForContacts(contactIdsFromAsIds(attributedRows));
        for (PhysicianROIRow r : attributedRows) {
            r.referralCount = defaultZero(referralCountByContactId.get(Id.valueOf(r.contactId)));
        }

        // 3. Needs-Attention — physicians this rep visited but NOT in CI output
        List<PhysicianROIRow> needs = queryNeedsAttention(userId, contactIdsFromAsIds(attributedRows));

        // 4. Company-wide top physicians — aggregated across all reps, top 4
        List<PhysicianROIRow> companyTop = queryTopPhysiciansCompanyWide(4);

        return buildSummary(attributedRows, needs, companyTop, currentQuarter);
    }

    @AuraEnabled(cacheable=true)
    public static PhysicianROI getPhysicianROI(String contactId) {
        if (String.isBlank(contactId)) return null;
        String userId = UserInfo.getUserId();
        String currentQuarter = computeCurrentQuarter();

        // Direct CI query for this (rep, physician)
        String sql = 'SELECT Rep_User_Id__c, Physician_Contact_Id__c, Physician_Name__c, ' +
                     'Specialty__c, Arrived_Count__c, Attributed_Revenue__c ' +
                     'FROM ' + CI_DMO + ' ' +
                     'WHERE Rep_User_Id__c = \'' + String.escapeSingleQuotes(userId) + '\' ' +
                     'AND Physician_Contact_Id__c = \'' + String.escapeSingleQuotes(contactId) + '\'';

        List<PhysicianROIRow> rows = executeDCQuery(sql);

        PhysicianROI dto = new PhysicianROI();
        dto.contactId = contactId;
        dto.quarter = currentQuarter;
        dto.arrivedCount = 0;
        dto.attributedRevenue = 0;

        if (!rows.isEmpty()) {
            PhysicianROIRow r = rows[0];
            dto.physicianName = r.physicianName;
            dto.specialty = r.specialty;
            dto.arrivedCount = r.arrivedCount;
            dto.attributedRevenue = r.attributedRevenue;
        } else {
            // No CI attribution — fill name/specialty from Contact so the caller has them
            List<Contact> contacts = [
                SELECT Id, Name, Title FROM Contact
                WHERE Id = :contactId WITH USER_MODE LIMIT 1
            ];
            if (!contacts.isEmpty()) {
                dto.physicianName = contacts[0].Name;
                dto.specialty = contacts[0].Title;
            }
        }

        // Referral count (same SOQL path as in the summary)
        Map<Id, Integer> refMap = computeReferralCountsForContacts(new Set<Id>{ Id.valueOf(contactId) });
        dto.referralCount = defaultZero(refMap.get(Id.valueOf(contactId)));

        return dto;
    }

    // ===== CI query =====

    @TestVisible
    private static List<PhysicianROIRow> queryCIForRep(String userId) {
        String sql = 'SELECT Rep_User_Id__c, Physician_Contact_Id__c, Physician_Name__c, ' +
                     'Specialty__c, Arrived_Count__c, Attributed_Revenue__c ' +
                     'FROM ' + CI_DMO + ' ' +
                     'WHERE Rep_User_Id__c = \'' + String.escapeSingleQuotes(userId) + '\'';
        return executeDCQuery(sql);
    }

    /**
     * Aggregate CI rows across all reps to surface the company's most
     * valuable physicians this quarter. Returns top N sorted by total
     * attributed revenue descending.
     */
    @TestVisible
    private static List<PhysicianROIRow> queryTopPhysiciansCompanyWide(Integer topN) {
        String sql = 'SELECT Physician_Contact_Id__c, Physician_Name__c, Specialty__c, ' +
                     'SUM(Arrived_Count__c) AS total_arrivals, ' +
                     'SUM(Attributed_Revenue__c) AS total_revenue ' +
                     'FROM ' + CI_DMO + ' ' +
                     'GROUP BY Physician_Contact_Id__c, Physician_Name__c, Specialty__c ' +
                     'ORDER BY total_revenue DESC ' +
                     'LIMIT ' + String.valueOf(topN);

        List<PhysicianROIRow> out = new List<PhysicianROIRow>();
        try {
            ConnectApi.CdpQueryInput input = new ConnectApi.CdpQueryInput();
            input.sql = sql;
            ConnectApi.CdpQueryOutputV2 res = ConnectApi.CdpQuery.queryAnsiSqlV2(input);
            if (res.data == null) return out;
            for (ConnectApi.CdpQueryV2Row row : res.data) {
                List<Object> cols = row.rowData;
                // Column order: 0 contactId, 1 name, 2 specialty, 3 total_arrivals, 4 total_revenue
                PhysicianROIRow r = new PhysicianROIRow();
                r.contactId         = safeString(cols.get(0));
                r.physicianName     = safeString(cols.get(1));
                r.specialty         = safeString(cols.get(2));
                r.arrivedCount      = safeInteger(cols.get(3));
                r.attributedRevenue = safeDecimal(cols.get(4));
                r.referralCount     = 0;  // not relevant for company view
                out.add(r);
            }
        } catch (Exception ex) {
            // Company-wide section is a bonus — never block the rep summary on its failure
            System.debug('[ReferralROIService] queryTopPhysiciansCompanyWide failed: ' + ex.getMessage());
        }
        return out;
    }

    @TestVisible
    private static List<PhysicianROIRow> executeDCQuery(String sql) {
        List<PhysicianROIRow> out = new List<PhysicianROIRow>();
        try {
            ConnectApi.CdpQueryInput input = new ConnectApi.CdpQueryInput();
            input.sql = sql;
            ConnectApi.CdpQueryOutputV2 res = ConnectApi.CdpQuery.queryAnsiSqlV2(input);
            if (res.data == null) return out;
            for (ConnectApi.CdpQueryV2Row row : res.data) {
                List<Object> cols = row.rowData;
                // Column order (from SELECT above):
                // 0: Rep_User_Id__c, 1: Physician_Contact_Id__c, 2: Physician_Name__c,
                // 3: Specialty__c, 4: Arrived_Count__c, 5: Attributed_Revenue__c
                PhysicianROIRow r = new PhysicianROIRow();
                r.contactId         = safeString(cols.get(1));
                r.physicianName     = safeString(cols.get(2));
                r.specialty         = safeString(cols.get(3));
                r.arrivedCount      = safeInteger(cols.get(4));
                r.attributedRevenue = safeDecimal(cols.get(5));
                r.referralCount     = 0;  // populated later via SOQL
                out.add(r);
            }
        } catch (Exception ex) {
            throw new ReferralROIException('Data Cloud query failed: ' + ex.getMessage());
        }
        return out;
    }

    // ===== SOQL — referral counts =====

    /**
     * Given a set of physician Contact Ids, return a map of Contact Id -> referral count.
     * Referral chain: ClinicalServiceRequest.RequesterId -> HealthcareProvider.
     * HealthcareProvider links to Contact via a field that varies by org — try common
     * candidates at runtime. If nothing resolves, the map is empty and all counts are 0.
     */
    @TestVisible
    private static Map<Id, Integer> computeReferralCountsForContacts(Set<Id> contactIds) {
        Map<Id, Integer> result = new Map<Id, Integer>();
        if (contactIds == null || contactIds.isEmpty()) return result;

        // Discover the HealthcareProvider -> Contact link field.
        String hpContactField = discoverHealthcareProviderContactField();
        if (hpContactField == null) {
            // No discoverable link field — return zeros.
            return result;
        }

        // HPs tied to our target contacts
        String hpQuery = 'SELECT Id, ' + hpContactField + ' FROM HealthcareProvider WHERE '
                      + hpContactField + ' IN :contactIds WITH USER_MODE';
        Map<Id, Id> hpToContact = new Map<Id, Id>();
        for (SObject hp : Database.query(hpQuery)) {
            hpToContact.put((Id) hp.get('Id'), (Id) hp.get(hpContactField));
        }
        if (hpToContact.isEmpty()) return result;

        Set<Id> hpIds = hpToContact.keySet();
        for (AggregateResult ar : [
            SELECT RequesterId reqId, COUNT(Id) total
            FROM ClinicalServiceRequest
            WHERE RequesterId IN :hpIds
            WITH USER_MODE
            GROUP BY RequesterId
        ]) {
            Id hpId = (Id) ar.get('reqId');
            Integer total = (Integer) ar.get('total');
            Id contactId = hpToContact.get(hpId);
            result.put(contactId, defaultZero(result.get(contactId)) + total);
        }
        return result;
    }

    /**
     * Heuristically discover the HealthcareProvider field that references Contact.
     * Returns the field API name, or null if none found.
     */
    private static String discoverHealthcareProviderContactField() {
        Schema.DescribeSObjectResult hp = HealthcareProvider.SObjectType.getDescribe();
        for (Schema.SObjectField f : hp.fields.getMap().values()) {
            Schema.DescribeFieldResult d = f.getDescribe();
            if (d.getType() != Schema.DisplayType.REFERENCE) continue;
            for (Schema.sObjectType ref : d.getReferenceTo()) {
                if (ref == Contact.SObjectType) {
                    return d.getName();
                }
            }
        }
        return null;
    }

    // ===== SOQL — needs attention =====

    /**
     * Physicians the rep has visited (IsPrimaryContact=true) who do NOT appear
     * in the CI output for this rep. Enrich with referral counts.
     */
    @TestVisible
    private static List<PhysicianROIRow> queryNeedsAttention(String userId, Set<Id> excludedContactIds) {
        List<PhysicianROIRow> rows = new List<PhysicianROIRow>();

        // SOQL doesn't allow nested semi-join subselects, so split into 2 queries.
        Set<Id> visitIds = new Set<Id>();
        for (Visit v : [SELECT Id FROM Visit WHERE VisitorId = :userId WITH USER_MODE]) {
            visitIds.add(v.Id);
        }
        if (visitIds.isEmpty()) return rows;

        List<Contact> visited = [
            SELECT Id, Name, Title
            FROM Contact
            WHERE Id IN (
                SELECT ContactId FROM VisitedParty
                WHERE IsPrimaryContact = true
                  AND VisitId IN :visitIds
            )
            AND Id NOT IN :excludedContactIds
            AND Name LIKE 'Dr. %'
            WITH USER_MODE
            ORDER BY Name
        ];
        if (visited.isEmpty()) return rows;

        Set<Id> visitedIds = new Set<Id>();
        for (Contact c : visited) visitedIds.add(c.Id);
        Map<Id, Integer> refMap = computeReferralCountsForContacts(visitedIds);

        for (Contact c : visited) {
            PhysicianROIRow r = new PhysicianROIRow();
            r.contactId = String.valueOf(c.Id);
            r.physicianName = c.Name;
            r.specialty = c.Title;
            r.attributedRevenue = 0;
            r.arrivedCount = 0;
            r.referralCount = defaultZero(refMap.get(c.Id));
            rows.add(r);
        }
        return rows;
    }

    // ===== Summary builder =====

    @TestVisible
    private static RepROISummary buildSummary(
        List<PhysicianROIRow> attributed,
        List<PhysicianROIRow> needsCandidates,
        List<PhysicianROIRow> companyTop,
        String quarter
    ) {
        RepROISummary s = new RepROISummary();
        s.quarter = quarter;
        s.topPhysiciansCompanyWide = (companyTop == null) ? new List<PhysicianROIRow>() : companyTop;

        Set<Id> contributingPhysicians = new Set<Id>();
        for (PhysicianROIRow r : attributed) {
            Decimal rev = (r.attributedRevenue == null) ? 0 : r.attributedRevenue;
            Integer arr = (r.arrivedCount == null) ? 0 : r.arrivedCount;
            if (rev > 0) {
                s.totalAttributedRevenue += rev;
                s.totalArrivedPatients += arr;
                contributingPhysicians.add(Id.valueOf(r.contactId));
            }
            s.totalReferrals += defaultZero(r.referralCount);
        }
        for (PhysicianROIRow r : needsCandidates) {
            s.totalReferrals += defaultZero(r.referralCount);
        }
        s.totalContributingPhysicians = contributingPhysicians.size();

        // topByROI: revenue > 0, sorted desc, top 3
        List<PhysicianROIRow> withRevenue = new List<PhysicianROIRow>();
        for (PhysicianROIRow r : attributed) {
            if (r.attributedRevenue != null && r.attributedRevenue > 0) withRevenue.add(r);
        }
        withRevenue.sort(new RevenueDescComparator());
        s.topByROI = withRevenue.size() > 3 ? slice(withRevenue, 3) : withRevenue;

        // needsAttention: visited physicians with referrals > 0, top 3 by referralCount desc.
        // If NONE have referrals > 0, fall back to showing physicians with any visits
        // (empty referral pipeline) so Reddy appears even before CSRs are seeded.
        List<PhysicianROIRow> needsWithRefs = new List<PhysicianROIRow>();
        for (PhysicianROIRow r : needsCandidates) {
            if (r.referralCount != null && r.referralCount > 0) needsWithRefs.add(r);
        }
        needsWithRefs.sort(new ReferralsDescComparator());
        s.needsAttention = needsWithRefs.size() > 3 ? slice(needsWithRefs, 3) : needsWithRefs;
        if (s.needsAttention.isEmpty() && !needsCandidates.isEmpty()) {
            // Fallback — surface visited-but-unconverted physicians even with 0 referrals
            s.needsAttention = needsCandidates.size() > 3 ? slice(needsCandidates, 3) : needsCandidates;
        }
        return s;
    }

    // ===== Helpers =====

    @TestVisible
    private static String computeCurrentQuarter() {
        Date t = Date.today();
        Integer q = ((t.month() - 1) / 3) + 1;
        return 'Q' + String.valueOf(q) + '-' + String.valueOf(t.year());
    }

    private static Set<String> contactIdsFrom(List<PhysicianROIRow> rows) {
        Set<String> ids = new Set<String>();
        for (PhysicianROIRow r : rows) if (r.contactId != null) ids.add(r.contactId);
        return ids;
    }

    private static Set<Id> contactIdsFromAsIds(List<PhysicianROIRow> rows) {
        Set<Id> ids = new Set<Id>();
        for (PhysicianROIRow r : rows) if (r.contactId != null) ids.add(Id.valueOf(r.contactId));
        return ids;
    }

    private static List<PhysicianROIRow> slice(List<PhysicianROIRow> rows, Integer n) {
        List<PhysicianROIRow> out = new List<PhysicianROIRow>();
        for (Integer i = 0; i < n && i < rows.size(); i++) out.add(rows[i]);
        return out;
    }

    private static Integer defaultZero(Integer v) { return v == null ? 0 : v; }

    private static String safeString(Object o) {
        return (o == null) ? null : String.valueOf(o);
    }

    private static Decimal safeDecimal(Object o) {
        if (o == null) return 0;
        if (o instanceof Decimal) return (Decimal) o;
        try { return Decimal.valueOf(String.valueOf(o)); } catch (Exception e) { return 0; }
    }

    private static Integer safeInteger(Object o) {
        if (o == null) return 0;
        if (o instanceof Integer) return (Integer) o;
        if (o instanceof Decimal) return ((Decimal) o).intValue();
        try { return Integer.valueOf(String.valueOf(o)); } catch (Exception e) { return 0; }
    }

    public class RevenueDescComparator implements Comparator<PhysicianROIRow> {
        public Integer compare(PhysicianROIRow a, PhysicianROIRow b) {
            Decimal av = (a.attributedRevenue == null) ? 0 : a.attributedRevenue;
            Decimal bv = (b.attributedRevenue == null) ? 0 : b.attributedRevenue;
            if (bv > av) return 1;
            if (bv < av) return -1;
            return 0;
        }
    }

    public class ReferralsDescComparator implements Comparator<PhysicianROIRow> {
        public Integer compare(PhysicianROIRow a, PhysicianROIRow b) {
            Integer av = (a.referralCount == null) ? 0 : a.referralCount;
            Integer bv = (b.referralCount == null) ? 0 : b.referralCount;
            if (bv > av) return 1;
            if (bv < av) return -1;
            return 0;
        }
    }
}