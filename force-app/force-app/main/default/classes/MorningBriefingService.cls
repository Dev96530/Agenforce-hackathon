public with sharing class MorningBriefingService {

    public class MorningBriefingException extends Exception {}

    private static final String PROMPT_TEMPLATE_API_NAME = 'Generate_Morning_Briefing';
    private static final Integer DAYS_WINDOW = 3;
    private static final Integer MAX_BODY_LEN = 400;
    private static final Integer SECTION_CAP = 1;

    public class BriefingCandidate {
        public String sourceType;
        public String physicianName;
        public String physicianContactId;
        public String detail;
        public Integer priorityScore;
    }

    public class Briefing {
        @InvocableVariable(Label='Rep User Id' Required=true)
        public String repUserId;

        @InvocableVariable(Label='Rep First Name')
        public String repFirstName;

        @InvocableVariable(Label='Briefing Body' Description='Natural language body for WhatsApp {{2}} variable')
        public String briefingBody;

        @InvocableVariable(Label='Priority Count')
        public Integer priorityCount;

        @InvocableVariable(Label='Generated At')
        public Datetime generatedAt;
    }

    @InvocableMethod(
        Label='Generate Morning Briefing'
        Description='Generates a personalized morning briefing for reps from Data Cloud insights and open Tasks'
    )
    public static List<Briefing> generateBriefings(List<String> repUserIds) {
        List<Briefing> out = new List<Briefing>();
        for (String repId : repUserIds) {
            try {
                out.add(generateForRep(repId));
            } catch (Exception ex) {
                System.debug('[UC8] briefing failed for ' + repId + ': ' + ex.getMessage());
                out.add(buildCalmDayFallback(repId));
            }
        }
        return out;
    }

    private static Briefing generateForRep(String repUserId) {
        List<User> users = [SELECT Id, FirstName FROM User WHERE Id = :repUserId WITH USER_MODE LIMIT 1];
        if (users.isEmpty()) {
            throw new MorningBriefingException('Rep user not found: ' + repUserId);
        }
        User rep = users[0];

        List<BriefingCandidate> sections = new List<BriefingCandidate>();
        sections.addAll(getRecentArrivals(repUserId));
        sections.addAll(getNeedsAttention(repUserId));
        sections.addAll(getStaleHighValue(repUserId));
        sections.addAll(getOpenTasks(repUserId));

        String body;
        if (sections.isEmpty()) {
            body = 'Nothing urgent for today. Good day to build new relationships.';
        } else {
            body = enforceMaxLength(callPromptTemplate(rep.FirstName, sections), MAX_BODY_LEN);
        }

        Briefing b = new Briefing();
        b.repUserId = repUserId;
        b.repFirstName = rep.FirstName;
        b.briefingBody = body;
        b.priorityCount = sections.size();
        b.generatedAt = Datetime.now();
        return b;
    }

    // -------- Section 1: Recent Arrivals (DMO direct, ingested from HIS via AWS S3) --------

    private static List<BriefingCandidate> getRecentArrivals(String repUserId) {
        List<BriefingCandidate> results = new List<BriefingCandidate>();
        try {
            ConnectApi.CdpQueryInput input = new ConnectApi.CdpQueryInput();
            input.sql =
                'SELECT ' +
                '    HIS_Admission_Event__dlm.Id__c, ' +
                '    HIS_Admission_Event__dlm.Referring_Physician_Name_c__c, ' +
                '    HIS_Admission_Event__dlm.Admission_Date_c__c, ' +
                '    HIS_Admission_Event__dlm.Admission_Status_c__c ' +
                'FROM HIS_Admission_Event__dlm ' +
                'WHERE HIS_Admission_Event__dlm.Admission_Status_c__c = \'Arrived\' ' +
                'ORDER BY HIS_Admission_Event__dlm.Admission_Date_c__c DESC';

            ConnectApi.CdpQueryOutputV2 res = ConnectApi.CdpQuery.queryAnsiSqlV2(input);
            if (res == null || res.data == null) return results;

            Date today = Date.today();
            Integer included = 0;
            for (ConnectApi.CdpQueryV2Row row : res.data) {
                if (included >= SECTION_CAP) break;
                String physicianName = String.valueOf(row.rowData[1]);
                Date admissionDate = parseAdmissionDate(row.rowData[2]);
                if (admissionDate == null) continue;
                Integer daysSince = admissionDate.daysBetween(today);
                if (daysSince < 0 || daysSince > DAYS_WINDOW) continue;

                BriefingCandidate c = new BriefingCandidate();
                c.sourceType = 'recent_arrival';
                c.physicianName = physicianName;
                c.detail = physicianName + '\'s referred patient arrived ' +
                           (daysSince == 0 ? 'today' :
                            daysSince == 1 ? 'yesterday' :
                            daysSince + ' days ago') +
                           ' — worth a thank-you call';
                c.priorityScore = daysSince <= 1 ? 75 : 60;
                results.add(c);
                included++;
            }
        } catch (Exception ex) {
            System.debug('[UC8] getRecentArrivals failed: ' + ex.getMessage());
        }
        return results;
    }

    // -------- Section 2: Needs Attention (Physician_Referral_Conversio__cio) --------
    // NOTE: API name is truncated by Salesforce — missing trailing 'n'. Do NOT use 'Conversion'.

    private static List<BriefingCandidate> getNeedsAttention(String repUserId) {
        List<BriefingCandidate> results = new List<BriefingCandidate>();
        try {
            ConnectApi.CdpQueryInput input = new ConnectApi.CdpQueryInput();
            input.sql =
                'SELECT ' +
                '    Physician_Referral_Conversio__cio.Physician_Contact_Id__c, ' +
                '    Physician_Referral_Conversio__cio.Physician_Name__c, ' +
                '    Physician_Referral_Conversio__cio.Specialty__c, ' +
                '    Physician_Referral_Conversio__cio.Referral_Count__c, ' +
                '    Physician_Referral_Conversio__cio.Arrival_Count__c ' +
                'FROM Physician_Referral_Conversio__cio ' +
                'WHERE Physician_Referral_Conversio__cio.Referral_Count__c >= 1 ' +
                'AND Physician_Referral_Conversio__cio.Arrival_Count__c < 1';

            ConnectApi.CdpQueryOutputV2 res = ConnectApi.CdpQuery.queryAnsiSqlV2(input);
            if (res == null || res.data == null) return results;

            Integer included = 0;
            for (ConnectApi.CdpQueryV2Row row : res.data) {
                if (included >= SECTION_CAP) break;
                String physicianName = String.valueOf(row.rowData[1]);
                Decimal referralCount = parseDecimal(row.rowData[3]);

                BriefingCandidate c = new BriefingCandidate();
                c.sourceType = 'needs_attention';
                c.physicianName = physicianName;
                c.physicianContactId = String.valueOf(row.rowData[0]);
                c.detail = physicianName + ' sent ' + referralCount.intValue() +
                           ' referral(s) but none arrived — time for a check-in';
                c.priorityScore = referralCount >= 2 ? 65 : 45;
                results.add(c);
                included++;
            }
        } catch (Exception ex) {
            System.debug('[UC8] getNeedsAttention failed: ' + ex.getMessage());
        }
        return results;
    }

    // -------- Section 3: Stale High Value (cross-CI INNER JOIN) --------

    private static List<BriefingCandidate> getStaleHighValue(String repUserId) {
        List<BriefingCandidate> results = new List<BriefingCandidate>();
        try {
            String escapedRep = String.escapeSingleQuotes(repUserId);
            ConnectApi.CdpQueryInput input = new ConnectApi.CdpQueryInput();
            input.sql =
                'SELECT ' +
                '    Referral_ROI_Attribution__cio.Physician_Contact_Id__c, ' +
                '    Referral_ROI_Attribution__cio.Physician_Name__c, ' +
                '    Referral_ROI_Attribution__cio.Specialty__c, ' +
                '    Referral_ROI_Attribution__cio.Attributed_Revenue__c, ' +
                '    Rep_Physician_Visit_Recency__cio.Last_Visit_Date__c ' +
                'FROM Referral_ROI_Attribution__cio ' +
                'INNER JOIN Rep_Physician_Visit_Recency__cio ' +
                '    ON Rep_Physician_Visit_Recency__cio.Rep_User_Id__c = Referral_ROI_Attribution__cio.Rep_User_Id__c ' +
                '    AND Rep_Physician_Visit_Recency__cio.Physician_Contact_Id__c = Referral_ROI_Attribution__cio.Physician_Contact_Id__c ' +
                'WHERE Referral_ROI_Attribution__cio.Rep_User_Id__c = \'' + escapedRep + '\' ' +
                'AND Referral_ROI_Attribution__cio.Attributed_Revenue__c > 0';

            ConnectApi.CdpQueryOutputV2 res = ConnectApi.CdpQuery.queryAnsiSqlV2(input);
            if (res == null || res.data == null) return results;

            Date today = Date.today();
            Integer included = 0;
            for (ConnectApi.CdpQueryV2Row row : res.data) {
                if (included >= SECTION_CAP) break;
                String physicianName = String.valueOf(row.rowData[1]);
                Decimal revenue = parseDecimal(row.rowData[3]);
                Datetime lastVisit = parseDatetime(row.rowData[4]);
                if (lastVisit == null) continue;

                Integer daysSince = lastVisit.date().daysBetween(today);
                if (daysSince <= 30) continue;

                BriefingCandidate c = new BriefingCandidate();
                c.sourceType = 'stale_high_value';
                c.physicianName = physicianName;
                c.physicianContactId = String.valueOf(row.rowData[0]);
                c.detail = physicianName + ' is your top ROI at $' +
                           formatCurrency(revenue) + ' but ' + daysSince +
                           ' days since last visit — schedule a touchpoint';
                c.priorityScore = daysSince > 60 ? 70 : 55;
                results.add(c);
                included++;
            }
        } catch (Exception ex) {
            System.debug('[UC8] getStaleHighValue failed: ' + ex.getMessage());
        }
        return results;
    }

    // -------- Section 4: Open Tasks (supplementary, max 2) --------

    private static List<BriefingCandidate> getOpenTasks(String repUserId) {
        List<BriefingCandidate> results = new List<BriefingCandidate>();
        // Cap at 1 task so the briefing stays 4 items max (3 DC sections + 1 task)
        // and never truncates against the 400-char WhatsApp body limit.
        List<Task> tasks = [
            SELECT Id, Subject, ActivityDate, WhoId, Who.Name
            FROM Task
            WHERE OwnerId = :repUserId
              AND Status != 'Completed'
              AND ActivityDate <= TODAY
            WITH USER_MODE
            ORDER BY ActivityDate ASC
            LIMIT 1
        ];
        Date today = Date.today();
        for (Task t : tasks) {
            BriefingCandidate c = new BriefingCandidate();
            Integer daysOverdue = today.daysBetween(t.ActivityDate) * -1;
            if (daysOverdue > 0) {
                c.sourceType = 'overdue_task';
                c.priorityScore = 90 + (daysOverdue * 5);
            } else {
                c.sourceType = 'due_today_task';
                c.priorityScore = 80;
            }
            String whoLabel = (t.Who != null && t.Who.Name != null) ? ' (' + t.Who.Name + ')' : '';
            c.detail = t.Subject + whoLabel;
            results.add(c);
        }
        return results;
    }

    // -------- Prompt template invocation with deterministic fallback --------

    private static String callPromptTemplate(String firstName, List<BriefingCandidate> priorities) {
        try {
            String prioritiesJson = JSON.serialize(priorities);

            ConnectApi.EinsteinPromptTemplateGenerationsInput genInput =
                new ConnectApi.EinsteinPromptTemplateGenerationsInput();
            genInput.inputParams = new Map<String, ConnectApi.WrappedValue>();

            ConnectApi.WrappedValue nameWrap = new ConnectApi.WrappedValue();
            nameWrap.value = firstName;
            genInput.inputParams.put('Input:RepFirstName', nameWrap);

            ConnectApi.WrappedValue jsonWrap = new ConnectApi.WrappedValue();
            jsonWrap.value = prioritiesJson;
            genInput.inputParams.put('Input:PrioritiesJson', jsonWrap);

            genInput.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
            genInput.additionalConfig.applicationName = 'PromptBuilderPreview';
            genInput.isPreview = false;

            ConnectApi.EinsteinPromptTemplateGenerationsRepresentation resp =
                ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(
                    PROMPT_TEMPLATE_API_NAME, genInput);

            if (resp != null && resp.generations != null && !resp.generations.isEmpty()) {
                String text = resp.generations[0].text;
                if (String.isNotBlank(text)) return text.trim();
            }
        } catch (Exception ex) {
            System.debug('[UC8] prompt template call failed, falling back to deterministic synthesis: ' + ex.getMessage());
        }
        return synthesizeDeterministic(priorities);
    }

    private static String synthesizeDeterministic(List<BriefingCandidate> priorities) {
        String[] words = new String[]{'Zero','One','Two','Three','Four','Five','Six','Seven','Eight'};
        Integer n = priorities.size();
        String countWord = (n < words.size()) ? words[n] : String.valueOf(n);
        String head = countWord + ' thing' + (n == 1 ? '' : 's') + ' for today.';
        List<String> sentences = new List<String>();
        for (BriefingCandidate c : priorities) {
            sentences.add(c.detail + '.');
        }
        return head + ' ' + String.join(sentences, ' ');
    }

    private static String enforceMaxLength(String input, Integer maxLen) {
        if (input == null || input.length() <= maxLen) return input;
        return input.substring(0, maxLen - 3) + '...';
    }

    private static Briefing buildCalmDayFallback(String repUserId) {
        String firstName = '';
        try {
            List<User> users = [SELECT FirstName FROM User WHERE Id = :repUserId WITH USER_MODE LIMIT 1];
            if (!users.isEmpty()) firstName = users[0].FirstName;
        } catch (Exception ignored) {}
        Briefing b = new Briefing();
        b.repUserId = repUserId;
        b.repFirstName = firstName;
        b.briefingBody = 'Nothing urgent for today. Good day to build new relationships.';
        b.priorityCount = 0;
        b.generatedAt = Datetime.now();
        return b;
    }

    // -------- Helpers (verified) --------

    private static Decimal parseDecimal(Object val) {
        if (val == null) return 0;
        try { return Decimal.valueOf(String.valueOf(val)); }
        catch (Exception parseErr) { return 0; }
    }

    private static Datetime parseDatetime(Object val) {
        if (val == null) return null;
        String s = String.valueOf(val);
        try { return (Datetime) JSON.deserialize('"' + s + '"', Datetime.class); }
        catch (Exception parseErr1) {
            try { return Datetime.valueOf(s); }
            catch (Exception parseErr2) { return null; }
        }
    }

    private static Date parseAdmissionDate(Object val) {
        if (val == null) return null;
        String s = String.valueOf(val);
        try {
            Datetime dt = (Datetime) JSON.deserialize('"' + s + '"', Datetime.class);
            return dt.date();
        } catch (Exception parseErr1) {
            try {
                Integer cut = Math.min(10, s.length());
                return Date.valueOf(s.substring(0, cut));
            } catch (Exception parseErr2) { return null; }
        }
    }

    private static String formatCurrency(Decimal amount) {
        if (amount == null) return '0';
        if (amount >= 1000000) return (amount / 1000000).setScale(1) + 'M';
        if (amount >= 1000) return (amount / 1000).setScale(0) + 'K';
        return String.valueOf(amount.intValue());
    }
}