/**
 * UC4 LWC polish — wraps PhysicianInsightsService and repacks its String-only
 * Response into a richer typed shape (Integers, Decimals, List<String>) that
 * the physicianInsightsCard Lightning Type renders as an SLDS card.
 *
 * Business logic stays in PhysicianInsightsService — this class is shape-only.
 */
public with sharing class PhysicianInsightsServiceLWC {

    public class Response {
        @InvocableVariable(Label='Physician Insights Card' Description='Structured insights for LWC card render')
        public PhysicianInsightsCard insights;
    }

    public class PhysicianInsightsCard {
        // Header
        @InvocableVariable public String physicianFullName;
        @InvocableVariable public String department;
        @InvocableVariable public String specialty;
        @InvocableVariable public String practicesAt;
        @InvocableVariable public Boolean physicianFound;

        // KPI tiles — proper numeric types
        @InvocableVariable public Integer visitCountThisYear;
        @InvocableVariable public Integer openTaskCount;
        @InvocableVariable public Decimal totalExpenseThisYear;
        @InvocableVariable public Integer daysSinceLastVisit;

        // Sentiment trend (last 3 visits, oldest to newest)
        @InvocableVariable public List<String> sentimentTrend;

        // Last visit / open task narrative
        @InvocableVariable public String lastVisitSummary;
        @InvocableVariable public String openTaskSummary;
        @InvocableVariable public Boolean hasRelationshipHistory;

        // Referral chain
        @InvocableVariable public Boolean hasReferralHistory;
        @InvocableVariable public Integer referralsThisYear;
        @InvocableVariable public Integer referralsConvertedToAppointments;
        @InvocableVariable public Integer appointmentsArrived;
        @InvocableVariable public String facilityBreakdown;
        @InvocableVariable public String lastReferralSummary;

        // ROI (Data Cloud)
        @InvocableVariable public String roiSummaryLine;
        @InvocableVariable public Decimal roiAttributedRevenue;
        @InvocableVariable public Integer roiArrivedCount;

        // CTA
        @InvocableVariable public String suggestedNextAction;
    }

    @InvocableMethod(
        Label='Get Physician Insights (LWC card)'
        Description='Read-only. Returns physician insights structured for custom Lightning Type rendering. Delegates business logic to PhysicianInsightsService.'
        Category='Agentforce'
    )
    public static List<Response> getInsightsForCard(List<String> queryUtterances) {
        List<Response> out = new List<Response>();
        List<PhysicianInsightsService.Response> raw =
            PhysicianInsightsService.getPhysicianInsights(queryUtterances);
        for (PhysicianInsightsService.Response r : raw) {
            Response wrapper = new Response();
            wrapper.insights = repack(r);
            out.add(wrapper);
        }
        return out;
    }

    private static PhysicianInsightsCard repack(PhysicianInsightsService.Response r) {
        PhysicianInsightsCard c = new PhysicianInsightsCard();
        c.physicianFullName = r.physicianFullName;
        c.department = r.department;
        c.specialty = r.specialty;
        c.practicesAt = r.practicesAt;
        c.physicianFound = parseBool(r.physicianFound);

        c.visitCountThisYear = parseInteger(r.visitCountThisYear);
        c.openTaskCount = parseInteger(r.openTaskCount);
        c.totalExpenseThisYear = parseDecimal(r.totalExpenseThisYear);
        c.daysSinceLastVisit = extractLeadingDays(r.lastVisitSummary);

        c.sentimentTrend = splitSentiment(r.sentimentTrend);

        c.lastVisitSummary = r.lastVisitSummary;
        c.openTaskSummary = r.openTaskSummary;
        c.hasRelationshipHistory = parseBool(r.hasRelationshipHistory);

        c.hasReferralHistory = parseBool(r.hasReferralHistory);
        c.referralsThisYear = parseInteger(r.referralsThisYear);
        c.referralsConvertedToAppointments = parseInteger(r.referralsConvertedToAppointments);
        c.appointmentsArrived = parseInteger(r.appointmentsArrived);
        c.facilityBreakdown = r.facilityBreakdown;
        c.lastReferralSummary = r.lastReferralSummary;

        c.roiSummaryLine = r.roiSummaryLine;
        c.roiAttributedRevenue = extractRoiRevenue(r.roiSummaryLine);
        c.roiArrivedCount = extractRoiArrivedCount(r.roiSummaryLine);

        c.suggestedNextAction = composeSuggestedNextAction(r, c);
        return c;
    }

    /**
     * UC9 hook — when the physician has a Department populated, override the
     * generic next-best-action with the clinical-briefing offer so the agent's
     * follow-up turn can chain into GetClinicalBriefingActionLWC.
     * Falls back to the underlying service's suggestedNextAction otherwise.
     */
    private static String composeSuggestedNextAction(
        PhysicianInsightsService.Response r,
        PhysicianInsightsCard c
    ) {
        Boolean found = parseBool(r.physicianFound);
        if (found && String.isNotBlank(c.department)) {
            String shortName = shortPhysicianName(c.physicianFullName);
            return 'Would you like me to prepare you for a visit with '
                + shortName + ' (' + c.department + ')?';
        }
        return r.suggestedNextAction;
    }

    /**
     * "Dr. Priya Mehta" → "Dr. Mehta"
     * "Dr. Arjun Sharma" → "Dr. Sharma"
     * "Priya Mehta" → "Dr. Mehta"
     * Falls back to original on any parse anomaly.
     */
    private static String shortPhysicianName(String fullName) {
        if (String.isBlank(fullName)) return fullName;
        String trimmed = fullName.trim();
        // Detect leading honorific
        Boolean hadHonorific = false;
        String honorificPrefix = '';
        for (String h : new List<String>{ 'Dr. ', 'Dr ', 'Prof. ', 'Prof ' }) {
            if (trimmed.startsWith(h)) { honorificPrefix = h; hadHonorific = true; break; }
        }
        String body = hadHonorific ? trimmed.substring(honorificPrefix.length()) : trimmed;
        List<String> parts = body.split('\\s+');
        if (parts.isEmpty()) return fullName;
        String last = parts[parts.size() - 1];
        return 'Dr. ' + last;
    }

    // ---------- Helpers (all null-safe) ----------

    private static Boolean parseBool(String s) {
        if (String.isBlank(s)) return null;
        return s.equalsIgnoreCase('true');
    }

    private static Integer parseInteger(String s) {
        if (String.isBlank(s)) return null;
        try { return Integer.valueOf(s.trim()); } catch (Exception ignore) { return null; }
    }

    private static Decimal parseDecimal(String s) {
        if (String.isBlank(s)) return null;
        try { return Decimal.valueOf(s.trim()); } catch (Exception ignore) { return null; }
    }

    private static List<String> splitSentiment(String joined) {
        List<String> result = new List<String>();
        if (String.isBlank(joined)) return result;
        for (String part : joined.split(',')) {
            String trimmed = part.trim();
            if (String.isNotBlank(trimmed)) result.add(trimmed);
        }
        return result;
    }

    /**
     * lastVisitSummary format: "<N> days ago, <snippet>"
     * Returns the leading day count, or null if no match.
     */
    private static Integer extractLeadingDays(String summary) {
        if (String.isBlank(summary)) return null;
        Matcher m = Pattern.compile('^(\\d+)\\s+days\\s+ago').matcher(summary);
        return m.find() ? Integer.valueOf(m.group(1)) : null;
    }

    /**
     * roiSummaryLine format (when revenue > 0):
     *   "$<N>K attributed revenue this quarter from <M> arrived patient(s)."
     * Returns N * 1000 as Decimal, or null if no match.
     */
    private static Decimal extractRoiRevenue(String line) {
        if (String.isBlank(line)) return null;
        Matcher m = Pattern.compile('\\$(\\d+)K').matcher(line);
        if (!m.find()) return null;
        return Decimal.valueOf(m.group(1)) * 1000;
    }

    /**
     * Extracts the "<M>" from "from <M> arrived patient(s)".
     */
    private static Integer extractRoiArrivedCount(String line) {
        if (String.isBlank(line)) return null;
        Matcher m = Pattern.compile('from\\s+(\\d+)\\s+arrived').matcher(line);
        return m.find() ? Integer.valueOf(m.group(1)) : null;
    }
}