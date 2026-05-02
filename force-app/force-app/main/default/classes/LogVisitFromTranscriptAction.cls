public with sharing class LogVisitFromTranscriptAction {

    public class LogVisitException extends Exception {}

    public class Response {
        @InvocableVariable(Label='Visit Id' Description='Salesforce Id of the newly created Visit record.')
        public String visitId;

        @InvocableVariable(Label='Physician Full Name' Description='The resolved physician Contact Name (e.g. "Priya Mehta"). Pulled from the Contact found via SOQL against the transcript-extracted physician name.')
        public String physicianFullName;

        @InvocableVariable(Label='Clinic Name' Description='The resolved clinic Account Name (e.g. "Sunrise Clinic"). Pulled from the Account found via SOQL against the transcript-extracted clinic name.')
        public String clinicName;

        @InvocableVariable(Label='Facility Name' Description='The OPD / ward / department name as extracted from the transcript. May be blank if the rep did not mention one.')
        public String facilityName;

        @InvocableVariable(Label='Visit Type Name' Description='The WorkType Name applied to the Visit (e.g. "Referral Discussion"). Defaults to Referral Discussion when the transcript is ambiguous.')
        public String visitTypeName;

        @InvocableVariable(Label='Confirmation Message' Description='Human-readable single-sentence confirmation summarizing the logged visit. Safe to show verbatim to the rep.')
        public String confirmationMessage;

        @InvocableVariable(Label='Task Count' Description='Number of follow-up Tasks created from the transcript action_items.')
        public Integer taskCount;
    }

    private static final String DEFAULT_VISIT_TYPE = 'Referral Discussion';
    private static final String PROMPT_TEMPLATE_API_NAME = 'Extract_Visit_From_Transcript';

    @InvocableMethod(
        Label='Log Visit From Transcript'
        Description='Creates a Visit + VisitedParty for a dictated physician-visit transcript. Invokes the Extract_Visit_From_Transcript prompt template to parse the six visit fields, resolves the Contact and Account via SOQL, inserts the records, and returns confirmation details.'
        Category='Agentforce'
    )
    public static List<Response> invoke(List<String> transcripts) {
        List<Response> results = new List<Response>();
        for (String transcript : transcripts) {
            results.add(logOne(transcript));
        }
        return results;
    }

    private static Response logOne(String transcript) {
        if (String.isBlank(transcript)) {
            throw newAgentError('Transcript is required.');
        }

        Extraction e = extractViaPromptTemplate(transcript);

        if (String.isBlank(e.clinicName)) {
            throw newAgentError('Clinic name could not be extracted from the transcript.');
        }
        if (String.isBlank(e.physicianName)) {
            throw newAgentError('Physician name could not be extracted from the transcript.');
        }

        Account clinic = resolveClinic(e.clinicName);
        Contact physician = resolvePhysician(e.physicianName, clinic.Id);
        Id placeId = resolveLocationIdOrNull(clinic.Id, e.facilityName);
        WorkType wt = resolveWorkType(e.visitType);

        Datetime nowDt = System.now();
        Visit v = new Visit(
            AccountId = clinic.Id,
            PlaceId = placeId,
            VisitorId = UserInfo.getUserId(),
            VisitTypeId = wt.Id,
            PlannedVisitStartTime = nowDt,
            ActualVisitStartTime = nowDt,
            StatusRemarks = e.visitSummary,
            Status = 'Completed',
            Rep_Sentiment__c = normalizeSentiment(e.sentiment)
        );
        insert as user v;

        VisitedParty vp = new VisitedParty(
            Name = physician.Name,
            VisitId = v.Id,
            ContactId = physician.Id,
            IsPrimaryContact = true
        );
        insert as user vp;

        Integer insertedTaskCount = tryInsertTasks(e.actionItems, v.Id, physician.Id);

        Response resp = new Response();
        resp.visitId = v.Id;
        resp.physicianFullName = physician.Name;
        resp.clinicName = clinic.Name;
        resp.facilityName = e.facilityName;
        resp.visitTypeName = wt.Name;
        resp.taskCount = insertedTaskCount;
        resp.confirmationMessage = buildConfirmation(physician.Name, clinic.Name, e.facilityName, wt.Name, insertedTaskCount);
        return resp;
    }

    private static Integer tryInsertTasks(List<Map<String, Object>> items, Id visitId, Id physicianId) {
        if (items == null || items.isEmpty()) return 0;
        List<Task> toInsert = new List<Task>();
        for (Map<String, Object> item : items) {
            String taskDesc = (String) item.get('description');
            if (String.isBlank(taskDesc)) continue;
            String subj = taskDesc.length() > 255 ? taskDesc.substring(0, 255) : taskDesc;
            Task t = new Task(
                Subject = subj,
                Description = taskDesc,
                ActivityDate = tryParseDate((String) item.get('due_date')),
                WhatId = visitId,
                WhoId = physicianId,
                OwnerId = UserInfo.getUserId(),
                Status = 'Not Started',
                Priority = 'Normal'
            );
            toInsert.add(t);
        }
        if (toInsert.isEmpty()) return 0;
        try {
            insert as user toInsert;
            return toInsert.size();
        } catch (Exception ex) {
            System.debug('Task insert failed; Visit still committed: ' + ex.getMessage());
            return 0;
        }
    }

    private static Date tryParseDate(String s) {
        if (String.isBlank(s)) return null;
        try { return Date.valueOf(s); }
        catch (Exception ex) { return null; }
    }

    private class Extraction {
        String physicianName;
        String clinicName;
        String facilityName;
        String visitType;
        String visitSummary;
        String sentiment;
        List<Map<String, Object>> actionItems = new List<Map<String, Object>>();
    }

    private static Extraction extractViaPromptTemplate(String transcript) {
        ConnectApi.EinsteinPromptTemplateGenerationsInput genInput =
            new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        genInput.inputParams = new Map<String, ConnectApi.WrappedValue>();
        ConnectApi.WrappedValue wv = new ConnectApi.WrappedValue();
        wv.value = transcript;
        genInput.inputParams.put('Input:Transcript', wv);

        ConnectApi.WrappedValue curDateWv = new ConnectApi.WrappedValue();
        curDateWv.value = DateTime.newInstance(Date.today(), Time.newInstance(0,0,0,0)).format('yyyy-MM-dd');
        genInput.inputParams.put('Input:CurrentDate', curDateWv);

        genInput.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        genInput.additionalConfig.applicationName = 'PromptBuilderPreview';
        genInput.isPreview = false;

        ConnectApi.EinsteinPromptTemplateGenerationsRepresentation resp;
        try {
            resp = ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(
                PROMPT_TEMPLATE_API_NAME, genInput);
        } catch (Exception ex) {
            throw newAgentError('Prompt template call failed: ' + ex.getMessage());
        }
        if (resp == null || resp.generations == null || resp.generations.isEmpty()) {
            throw newAgentError('Prompt template returned no generations.');
        }
        String raw = resp.generations[0].text;
        if (String.isBlank(raw)) {
            throw newAgentError('Prompt template returned empty text.');
        }

        Map<String, Object> parsed;
        try {
            parsed = (Map<String, Object>) JSON.deserializeUntyped(raw);
        } catch (Exception ex) {
            throw newAgentError('Could not parse the transcript extraction as JSON. Please re-dictate. (' + ex.getMessage() + ')');
        }

        Extraction e = new Extraction();
        e.physicianName = (String) parsed.get('physician_name');
        e.clinicName    = (String) parsed.get('clinic_name');
        e.facilityName  = (String) parsed.get('facility_name');
        e.visitType     = (String) parsed.get('visit_type');
        e.visitSummary  = (String) parsed.get('visit_summary');
        e.sentiment     = (String) parsed.get('sentiment');

        Object rawAi = parsed.get('action_items');
        if (rawAi instanceof List<Object>) {
            for (Object o : (List<Object>) rawAi) {
                if (o instanceof Map<String, Object>) {
                    e.actionItems.add((Map<String, Object>) o);
                }
            }
        }
        return e;
    }

    private static Account resolveClinic(String clinicName) {
        String pattern = '%' + String.escapeSingleQuotes(clinicName) + '%';
        List<Account> matches = [
            SELECT Id, Name FROM Account
            WHERE Name LIKE :pattern
            WITH USER_MODE
            ORDER BY LastModifiedDate DESC
            LIMIT 10
        ];
        if (matches.isEmpty()) {
            throw newAgentError('Clinic not found: ' + clinicName + '.');
        }
        for (Account a : matches) {
            if (a.Name.equalsIgnoreCase(clinicName)) return a;
        }
        return matches[0];
    }

    private static Contact resolvePhysician(String physicianName, Id clinicAccountId) {
        String normalized = stripHonorific(physicianName);
        String pattern = '%' + String.escapeSingleQuotes(normalized) + '%';
        List<Contact> matches = [
            SELECT Id, Name, AccountId FROM Contact
            WHERE Name LIKE :pattern
            WITH USER_MODE
            ORDER BY LastModifiedDate DESC
            LIMIT 20
        ];
        if (matches.isEmpty()) {
            throw newAgentError('Physician not found: ' + physicianName + '.');
        }
        for (Contact c : matches) {
            if (c.AccountId == clinicAccountId) return c;
        }
        return matches[0];
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

    private static Id resolveLocationIdOrNull(Id clinicAccountId, String facilityName) {
        if (!String.isBlank(facilityName)) {
            String pattern = '%' + String.escapeSingleQuotes(facilityName) + '%';
            List<HealthcareFacility> named = [
                SELECT Id, LocationId FROM HealthcareFacility
                WHERE AccountId = :clinicAccountId AND Name LIKE :pattern
                WITH USER_MODE
                ORDER BY LastModifiedDate DESC
                LIMIT 1
            ];
            if (!named.isEmpty() && named[0].LocationId != null) {
                return named[0].LocationId;
            }
        }
        List<HealthcareFacility> anyFac = [
            SELECT Id, LocationId FROM HealthcareFacility
            WHERE AccountId = :clinicAccountId AND LocationId != NULL
            WITH USER_MODE
            ORDER BY LastModifiedDate DESC
            LIMIT 1
        ];
        return anyFac.isEmpty() ? null : anyFac[0].LocationId;
    }

    private static WorkType resolveWorkType(String visitType) {
        if (!String.isBlank(visitType)) {
            List<WorkType> exact = [
                SELECT Id, Name FROM WorkType
                WHERE Name = :visitType
                WITH USER_MODE LIMIT 1
            ];
            if (!exact.isEmpty()) return exact[0];
        }
        List<WorkType> fallback = [
            SELECT Id, Name FROM WorkType
            WHERE Name = :DEFAULT_VISIT_TYPE
            WITH USER_MODE LIMIT 1
        ];
        if (fallback.isEmpty()) {
            throw newAgentError('Default Work Type "' + DEFAULT_VISIT_TYPE + '" is missing from the org.');
        }
        return fallback[0];
    }

    private static String buildConfirmation(String physician, String clinic, String facility, String visitType, Integer taskCount) {
        String venue = clinic;
        if (!String.isBlank(facility)) venue += '\'s ' + facility;
        String base = 'Logged visit with ' + physician + ' at ' + venue + ' as a ' + visitType + '.';
        if (taskCount != null && taskCount > 0) {
            base += ' ' + taskCount + ' follow-up' + (taskCount == 1 ? '' : 's') + ' queued.';
        }
        return base;
    }

    private static LogVisitException newAgentError(String message) {
        return new LogVisitException(message);
    }

    private static String normalizeSentiment(String raw) {
        if (String.isBlank(raw)) return null;
        String s = raw.trim().toLowerCase();
        if (s == 'positive') return 'Positive';
        if (s == 'neutral')  return 'Neutral';
        if (s == 'negative') return 'Negative';
        return null;
    }
}