public without sharing class PhysicianInsightsService {

    public class PhysicianInsightsException extends Exception {}

    public class Response {
        @InvocableVariable(Label='Physician Full Name')
        public String physicianFullName;
        @InvocableVariable(Label='Specialty')
        public String specialty;
        @InvocableVariable(Label='Credentials')
        public String credentials;
        @InvocableVariable(Label='Practices At')
        public String practicesAt;
        @InvocableVariable(Label='Physician Found')
        public String physicianFound;

        @InvocableVariable(Label='Visit Count This Year')
        public String visitCountThisYear;
        @InvocableVariable(Label='Last Visit Summary')
        public String lastVisitSummary;
        @InvocableVariable(Label='Sentiment Trend')
        public String sentimentTrend;
        @InvocableVariable(Label='Open Task Count')
        public String openTaskCount;
        @InvocableVariable(Label='Open Task Summary')
        public String openTaskSummary;
        @InvocableVariable(Label='Total Expense This Year')
        public String totalExpenseThisYear;
        @InvocableVariable(Label='Has Relationship History')
        public String hasRelationshipHistory;

        @InvocableVariable(Label='Referrals This Year')
        public String referralsThisYear;
        @InvocableVariable(Label='Referrals Converted To Appointments')
        public String referralsConvertedToAppointments;
        @InvocableVariable(Label='Appointments Arrived')
        public String appointmentsArrived;
        @InvocableVariable(Label='Facility Breakdown')
        public String facilityBreakdown;
        @InvocableVariable(Label='Last Referral Summary')
        public String lastReferralSummary;
        @InvocableVariable(Label='Has Referral History')
        public String hasReferralHistory;

        @InvocableVariable(Label='Suggested Next Action')
        public String suggestedNextAction;

        @InvocableVariable(Label='ROI Summary Line' Description='Pre-formatted ROI sentence from Data Cloud attribution. Relay verbatim if present.')
        public String roiSummaryLine;

        @InvocableVariable(Label='Department' Description='Physician department/specialty for visit prep, e.g. "Medical Oncology - Hematology". May be blank.')
        public String department;
    }

    private class Extraction {
        String physicianName;
        String queryFocus;
    }

    private static final String PROMPT_TEMPLATE_API_NAME = 'Extract_Physician_Query';

    @InvocableMethod(
        Label='Get Physician Insights'
        Description='Read-only. Returns profile, relationship history, referral ROI, and a deterministic next-best-action for the physician the rep asked about.'
        Category='Agentforce'
    )
    public static List<Response> getPhysicianInsights(List<String> queryUtterances) {
        List<Response> out = new List<Response>();
        for (String q : queryUtterances) out.add(answerOne(q));
        return out;
    }

    private static Response answerOne(String utterance) {
        Response r = new Response();
        if (String.isBlank(utterance)) {
            r.physicianFound = 'false';
            r.hasRelationshipHistory = 'false';
            r.hasReferralHistory = 'false';
            r.suggestedNextAction = 'Could you tell me which physician you want to know about?';
            return r;
        }

        Extraction e = extractViaPromptTemplate(utterance);
        if (String.isBlank(e.physicianName)) {
            r.physicianFound = 'false';
            r.hasRelationshipHistory = 'false';
            r.hasReferralHistory = 'false';
            r.suggestedNextAction = 'Could you confirm the physician\'s name? I couldn\'t pick one out of your question.';
            return r;
        }

        Contact physician = tryResolvePhysician(e.physicianName);
        if (physician == null) {
            r.physicianFound = 'false';
            r.physicianFullName = e.physicianName;
            r.hasRelationshipHistory = 'false';
            r.hasReferralHistory = 'false';
            r.suggestedNextAction = 'Could you confirm the physician\'s name? I couldn\'t find a match in the system.';
            return r;
        }
        HealthcareProvider hcp = tryResolveHcp(physician.Name);

        r.physicianFound = 'true';
        r.physicianFullName = physician.Name;
        r.department = (physician.Department == null) ? '' : physician.Department;

        populateLayer1(r, hcp);
        populateLayer2(r, physician.Id);
        Integer daysSinceLastArrival = populateLayer3(r, hcp);

        Integer daysSinceLastVisit = daysSinceLastVisitFor(physician.Id);
        Task priorityTask = findOpenPriorityTask(physician.Id);
        r.suggestedNextAction = computeSuggestedNextAction(
            r, priorityTask, daysSinceLastArrival, daysSinceLastVisit
        );

        // UC7 — attach Data Cloud ROI line. Failures here do not block the rest of the response.
        try {
            ReferralROIService.PhysicianROI roi = ReferralROIService.getPhysicianROI(String.valueOf(physician.Id));
            r.roiSummaryLine = buildROILine(roi);
        } catch (Exception ex) {
            System.debug('[PhysicianInsightsService] ROI fetch failed: ' + ex.getMessage());
        }

        return r;
    }

    private static String buildROILine(ReferralROIService.PhysicianROI roi) {
        if (roi == null) return null;
        Decimal rev = (roi.attributedRevenue == null) ? 0 : roi.attributedRevenue;
        Integer arrived = (roi.arrivedCount == null) ? 0 : roi.arrivedCount;
        Integer refs = (roi.referralCount == null) ? 0 : roi.referralCount;
        if (rev > 0) {
            Decimal lakhs = (rev / 1000).setScale(0);  // thousands for USD — $630K style
            return '$' + String.valueOf(lakhs) + 'K attributed revenue this quarter from ' + arrived + ' arrived patient(s).';
        }
        return 'No attributed revenue yet this quarter — ' + refs + ' referral(s) in the pipeline.';
    }

    // ---------- Layer 1 ----------
    private static void populateLayer1(Response r, HealthcareProvider hcp) {
        if (hcp == null) return;
        List<HealthcarePractitionerFacility> hpfs = [
            SELECT HealthcareFacility.Name
            FROM HealthcarePractitionerFacility
            WHERE HealthcareProviderId = :hcp.Id
            WITH USER_MODE
        ];
        List<String> names = new List<String>();
        for (HealthcarePractitionerFacility hpf : hpfs) {
            if (hpf.HealthcareFacility != null && hpf.HealthcareFacility.Name != null) {
                names.add(hpf.HealthcareFacility.Name);
            }
        }
        r.practicesAt = names.isEmpty() ? null : String.join(names, ', ');
        List<HealthcareProvider> rich = [
            SELECT Name, ProviderType FROM HealthcareProvider WHERE Id = :hcp.Id WITH USER_MODE LIMIT 1
        ];
        if (!rich.isEmpty()) {
            r.specialty = rich[0].ProviderType;
            r.credentials = null;
        }
    }

    // ---------- Layer 2 ----------
    private static void populateLayer2(Response r, Id contactId) {
        Id runningUserId = UserInfo.getUserId();
        Date yearStart = Date.newInstance(Date.today().year(), 1, 1);

        List<VisitedParty> vps = [
            SELECT VisitId, Visit.ActualVisitStartTime, Visit.StatusRemarks, Visit.Rep_Sentiment__c
            FROM VisitedParty
            WHERE ContactId = :contactId
              AND IsPrimaryContact = true
              AND Visit.VisitorId = :runningUserId
              AND Visit.ActualVisitStartTime >= :DateTime.newInstance(yearStart, Time.newInstance(0,0,0,0))
            WITH USER_MODE
            ORDER BY Visit.ActualVisitStartTime DESC
        ];
        Integer visitCount = vps.size();
        r.visitCountThisYear = String.valueOf(visitCount);
        r.hasRelationshipHistory = (visitCount > 0) ? 'true' : 'false';

        if (visitCount > 0) {
            VisitedParty mostRecent = vps[0];
            Integer days = daysBetween(mostRecent.Visit.ActualVisitStartTime, DateTime.now());
            String summary = (mostRecent.Visit.StatusRemarks == null) ? '' : mostRecent.Visit.StatusRemarks;
            if (summary.length() > 70) summary = summary.substring(0, 70) + '...';
            r.lastVisitSummary = days + ' days ago' + (String.isBlank(summary) ? '' : ', ' + summary);

            Integer take = Math.min(3, vps.size());
            List<String> trend = new List<String>();
            for (Integer i = take - 1; i >= 0; i--) {
                String s = vps[i].Visit.Rep_Sentiment__c;
                if (s == null) s = '—';
                trend.add(s);
            }
            r.sentimentTrend = String.join(trend, ', ');
        }

        List<Task> tasks = [
            SELECT Id, Subject, ActivityDate, Priority
            FROM Task
            WHERE WhoId = :contactId
              AND OwnerId = :runningUserId
              AND Status != 'Completed'
            WITH USER_MODE
            ORDER BY ActivityDate ASC NULLS LAST
        ];
        r.openTaskCount = String.valueOf(tasks.size());
        if (!tasks.isEmpty()) {
            Task t = tasks[0];
            String due = (t.ActivityDate == null) ? 'no date set' : formatRelativeDate(t.ActivityDate);
            r.openTaskSummary = tasks.size() + ' open task' + (tasks.size() == 1 ? '' : 's')
                                + ' — ' + t.Subject + ', due ' + due;
        }

        Set<Id> visitIds = new Set<Id>();
        for (VisitedParty vp : vps) visitIds.add(vp.VisitId);
        if (!visitIds.isEmpty()) {
            List<WorkOrder> wos = [
                SELECT Id FROM WorkOrder WHERE Visit__c IN :visitIds
            ];
            Set<Id> woIds = new Set<Id>();
            for (WorkOrder w : wos) woIds.add(w.Id);
            if (!woIds.isEmpty()) {
                AggregateResult[] ars = [
                    SELECT SUM(Amount) tot FROM Expense
                    WHERE WorkOrderId IN :woIds AND OwnerId = :runningUserId
                ];
                Object tot = ars[0].get('tot');
                r.totalExpenseThisYear = (tot == null) ? '0' : String.valueOf((Decimal) tot);
            } else {
                r.totalExpenseThisYear = '0';
            }
        } else {
            r.totalExpenseThisYear = '0';
        }
    }

    // ---------- Layer 3 (simplified: CSR → ServiceAppointment direct) ----------
    private static Integer populateLayer3(Response r, HealthcareProvider hcp) {
        if (hcp == null) {
            r.hasReferralHistory = 'false';
            return null;
        }
        Date yearStart = Date.newInstance(Date.today().year(), 1, 1);

        List<ClinicalServiceRequest> csrs = [
            SELECT Id FROM ClinicalServiceRequest
            WHERE RequesterId = :hcp.Id
              AND DateSigned >= :DateTime.newInstance(yearStart, Time.newInstance(0,0,0,0))
            WITH USER_MODE
            ORDER BY DateSigned DESC
        ];
        Integer csrCount = csrs.size();
        r.referralsThisYear = String.valueOf(csrCount);
        r.hasReferralHistory = (csrCount > 0) ? 'true' : 'false';
        if (csrCount == 0) return null;

        Set<Id> csrIds = new Set<Id>();
        for (ClinicalServiceRequest c : csrs) csrIds.add(c.Id);

        List<ServiceAppointment> sas = [
            SELECT Id, Status, WorkType.Name, ParentRecordId, SchedStartTime
            FROM ServiceAppointment
            WHERE ParentRecordId IN :csrIds
            WITH USER_MODE
            ORDER BY SchedStartTime DESC
        ];
        Integer converted = sas.size();
        r.referralsConvertedToAppointments = String.valueOf(converted);

        Integer arrived = 0;
        Map<String, Integer> byWorkType = new Map<String, Integer>();
        DateTime lastArrivalDt = null;
        String lastArrivalWorkType = null;
        for (ServiceAppointment sa : sas) {
            if (sa.Status == 'Completed') {
                arrived++;
                if (lastArrivalDt == null) {
                    lastArrivalDt = sa.SchedStartTime;
                    lastArrivalWorkType = (sa.WorkType == null) ? 'Unknown' : sa.WorkType.Name;
                }
            }
            String wtName = (sa.WorkType == null) ? 'Unknown' : sa.WorkType.Name;
            if (sa.Status == 'Scheduled' || sa.Status == 'Completed') {
                Integer c = byWorkType.containsKey(wtName) ? byWorkType.get(wtName) : 0;
                byWorkType.put(wtName, c + 1);
            }
        }
        r.appointmentsArrived = String.valueOf(arrived);

        List<String> parts = new List<String>();
        for (String wt : byWorkType.keySet()) {
            parts.add(byWorkType.get(wt) + ' at ' + wt);
        }
        r.facilityBreakdown = parts.isEmpty() ? null : String.join(parts, ', ');

        if (lastArrivalDt != null) {
            Integer days = daysBetween(lastArrivalDt, DateTime.now());
            r.lastReferralSummary = days + ' days ago, patient routed to ' + lastArrivalWorkType;
            return days;
        }
        return null;
    }

    // ---------- Next-best-action ----------
    private static String computeSuggestedNextAction(
        Response r, Task priorityTask, Integer daysSinceLastArrival, Integer daysSinceLastVisit
    ) {
        if (priorityTask != null && isDueTodayOrOverdue(priorityTask.ActivityDate)) {
            return 'Prioritize your open task: ' + priorityTask.Subject +
                   ', due ' + formatRelativeDate(priorityTask.ActivityDate) + '.';
        }
        if (daysSinceLastArrival != null && daysSinceLastArrival <= 7) {
            return 'Her last referral arrived ' + daysSinceLastArrival +
                   ' days ago — good moment to thank her.';
        }
        if (r.hasRelationshipHistory == 'true' && daysSinceLastVisit != null && daysSinceLastVisit > 60) {
            Integer weeks = daysSinceLastVisit / 7;
            return 'You haven\'t visited in ' + weeks + ' weeks — consider scheduling a catch-up.';
        }
        if (isRecentSentimentDown(r.sentimentTrend)) {
            return 'Recent sentiment (' + r.sentimentTrend +
                   ') suggests things have shifted — may want to explore what\'s changed.';
        }
        if (r.hasRelationshipHistory != 'true') {
            return 'You haven\'t logged a visit with this physician yet — might be worth an introduction.';
        }
        return 'Relationship looks healthy — maintain regular touchpoints.';
    }

    private static Boolean isDueTodayOrOverdue(Date d) {
        if (d == null) return false;
        return d <= Date.today();
    }

    private static Boolean isRecentSentimentDown(String trend) {
        if (String.isBlank(trend)) return false;
        List<String> parts = trend.split(', ');
        if (parts.isEmpty()) return false;
        String newest = parts[parts.size() - 1];
        return newest == 'Neutral' || newest == 'Negative';
    }

    // ---------- Helpers ----------
    private static Contact tryResolvePhysician(String physicianName) {
        if (String.isBlank(physicianName)) return null;
        String normalized = stripHonorific(physicianName);
        String pattern = '%' + String.escapeSingleQuotes(normalized) + '%';
        List<Contact> matches = [
            SELECT Id, Name, AccountId, Department FROM Contact
            WHERE Name LIKE :pattern
            WITH USER_MODE
            ORDER BY LastModifiedDate DESC
            LIMIT 5
        ];
        return matches.isEmpty() ? null : matches[0];
    }

    private static HealthcareProvider tryResolveHcp(String contactName) {
        String pattern = '%' + String.escapeSingleQuotes(contactName) + '%';
        List<HealthcareProvider> matches = [
            SELECT Id, Name FROM HealthcareProvider
            WHERE Name LIKE :pattern
            WITH USER_MODE
            ORDER BY LastModifiedDate DESC
            LIMIT 5
        ];
        return matches.isEmpty() ? null : matches[0];
    }

    private static String stripHonorific(String raw) {
        if (String.isBlank(raw)) return raw;
        String s = raw.trim();
        String lower = s.toLowerCase();
        for (String p : new List<String>{ 'dr. ', 'dr ', 'dr.', 'prof. ', 'prof ', 'prof.' }) {
            if (lower.startsWith(p)) return s.substring(p.length()).trim();
        }
        return s;
    }

    private static Integer daysBetween(DateTime fromDt, DateTime toDt) {
        Long ms = toDt.getTime() - fromDt.getTime();
        return (Integer)(ms / (1000L * 60 * 60 * 24));
    }

    private static String formatRelativeDate(Date d) {
        if (d == null) return 'no date';
        Date todayDt = Date.today();
        Integer diff = todayDt.daysBetween(d);
        if (diff == 0) return 'today';
        if (diff == 1) return 'tomorrow';
        if (diff == -1) return 'yesterday';
        if (diff > 1 && diff <= 7) {
            return DateTime.newInstance(d, Time.newInstance(0,0,0,0)).format('EEEE');
        }
        return DateTime.newInstance(d, Time.newInstance(0,0,0,0)).format('MMM d');
    }

    private static Integer daysSinceLastVisitFor(Id contactId) {
        List<VisitedParty> vps = [
            SELECT Visit.ActualVisitStartTime FROM VisitedParty
            WHERE ContactId = :contactId
              AND IsPrimaryContact = true
              AND Visit.VisitorId = :UserInfo.getUserId()
            WITH USER_MODE
            ORDER BY Visit.ActualVisitStartTime DESC
            LIMIT 1
        ];
        if (vps.isEmpty() || vps[0].Visit.ActualVisitStartTime == null) return null;
        return daysBetween(vps[0].Visit.ActualVisitStartTime, DateTime.now());
    }

    private static Task findOpenPriorityTask(Id contactId) {
        List<Task> tasks = [
            SELECT Id, Subject, ActivityDate, Priority
            FROM Task
            WHERE WhoId = :contactId
              AND OwnerId = :UserInfo.getUserId()
              AND Status != 'Completed'
              AND ActivityDate != null
            WITH USER_MODE
            ORDER BY ActivityDate ASC
            LIMIT 1
        ];
        return tasks.isEmpty() ? null : tasks[0];
    }

    private static Extraction extractViaPromptTemplate(String utterance) {
        ConnectApi.EinsteinPromptTemplateGenerationsInput genInput =
            new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        genInput.inputParams = new Map<String, ConnectApi.WrappedValue>();
        ConnectApi.WrappedValue uwv = new ConnectApi.WrappedValue();
        uwv.value = utterance;
        genInput.inputParams.put('Input:QueryUtterance', uwv);
        genInput.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        genInput.additionalConfig.applicationName = 'PromptBuilderPreview';
        genInput.isPreview = false;

        ConnectApi.EinsteinPromptTemplateGenerationsRepresentation resp;
        try {
            resp = ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(
                PROMPT_TEMPLATE_API_NAME, genInput);
        } catch (Exception ex) {
            throw new PhysicianInsightsException('Prompt template call failed: ' + ex.getMessage());
        }
        if (resp == null || resp.generations == null || resp.generations.isEmpty()) {
            throw new PhysicianInsightsException('Prompt template returned no generations.');
        }
        String raw = resp.generations[0].text;
        Map<String, Object> parsed;
        try {
            parsed = (Map<String, Object>) JSON.deserializeUntyped(raw);
        } catch (Exception ex) {
            throw new PhysicianInsightsException('Could not parse JSON from prompt template: ' + ex.getMessage());
        }
        Extraction e = new Extraction();
        e.physicianName = (String) parsed.get('physician_name');
        e.queryFocus = (String) parsed.get('query_focus');
        return e;
    }
}