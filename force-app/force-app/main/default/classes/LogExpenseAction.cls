public with sharing class LogExpenseAction {

    public class LogExpenseException extends Exception {}

    public class Response {
        @InvocableVariable(Label='Expense Id' Description='Salesforce Id of the newly created Expense record.')
        public String expenseId;
        @InvocableVariable(Label='Amount' Description='The decimal amount of the expense.')
        public Decimal amount;
        @InvocableVariable(Label='Transaction Date' Description='When the expense occurred, resolved from the rep utterance.')
        public Date transactionDate;
        @InvocableVariable(Label='Linked To Visit' Description='True if the expense attached to a WorkOrder derived from a prior Visit with the named physician.')
        public Boolean linkedToVisit;
        @InvocableVariable(Label='Physician Full Name' Description='The resolved physician Contact Name, or null if not named or not resolved.')
        public String physicianFullName;
        @InvocableVariable(Label='Venue' Description='The venue / place mentioned in the utterance, or null if not mentioned.')
        public String venue;
        @InvocableVariable(Label='Confirmation Message' Description='Human-readable single-sentence confirmation. Safe to show verbatim. No currency symbol; thousands-separated amount.')
        public String confirmationMessage;
    }

    private class Extraction {
        Decimal amount;
        String transactionDate;
        String physicianName;
        String venue;
        String descriptionClean;
    }

    private static final String PROMPT_TEMPLATE_API_NAME = 'Extract_Expense_From_Input';

    @InvocableMethod(
        Label='Log Expense'
        Description='Creates an Expense from a rep utterance. Invokes Extract_Expense_From_Input prompt template, resolves physician Contact best-effort, looks up most recent own-Visit for that physician, attaches Expense to that Visit WorkOrder if found.'
        Category='Agentforce'
    )
    public static List<Response> invoke(List<String> utterances) {
        List<Response> out = new List<Response>();
        for (String u : utterances) out.add(logOne(u));
        return out;
    }

    private static Response logOne(String utterance) {
        if (String.isBlank(utterance)) {
            throw new LogExpenseException('Expense utterance is required.');
        }
        Extraction e = extractViaPromptTemplate(utterance);
        if (e.amount == null || e.amount <= 0) {
            throw new LogExpenseException('Expense amount could not be determined from your request.');
        }
        Date txnDate = tryParseDate(e.transactionDate);
        if (txnDate == null) txnDate = Date.today();

        Contact physician = tryResolvePhysician(e.physicianName);
        Id workOrderId = null;
        Id accountId = null;
        if (physician != null) {
            Id woId = findMostRecentWorkOrderForPhysician(physician.Id);
            if (woId != null) {
                workOrderId = woId;
                accountId = getWorkOrderAccountId(woId);
            }
        }

        String descClean = e.descriptionClean == null ? '' : e.descriptionClean;
        Expense exp = new Expense(
            Amount = e.amount,
            Title = truncate(descClean, 255),
            Description = descClean + '\n\nRaw: ' + utterance,
            TransactionDate = txnDate,
            ExpenseType = 'Billable',
            WorkOrderId = workOrderId,
            AccountId = accountId,
            OwnerId = UserInfo.getUserId()
        );
        insert as user exp;

        Response resp = new Response();
        resp.expenseId = exp.Id;
        resp.amount = e.amount;
        resp.transactionDate = txnDate;
        resp.linkedToVisit = (workOrderId != null);
        resp.physicianFullName = physician == null ? null : physician.Name;
        resp.venue = e.venue;
        resp.confirmationMessage = buildConfirmation(e.amount, resp.physicianFullName, resp.linkedToVisit);
        return resp;
    }

    private static Extraction extractViaPromptTemplate(String utterance) {
        ConnectApi.EinsteinPromptTemplateGenerationsInput genInput =
            new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        genInput.inputParams = new Map<String, ConnectApi.WrappedValue>();
        ConnectApi.WrappedValue uwv = new ConnectApi.WrappedValue();
        uwv.value = utterance;
        genInput.inputParams.put('Input:ExpenseUtterance', uwv);
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
            throw new LogExpenseException('Prompt template call failed: ' + ex.getMessage());
        }
        if (resp == null || resp.generations == null || resp.generations.isEmpty()) {
            throw new LogExpenseException('Prompt template returned no generations.');
        }
        String raw = resp.generations[0].text;
        if (String.isBlank(raw)) {
            throw new LogExpenseException('Prompt template returned empty text.');
        }
        Map<String, Object> parsed;
        try {
            parsed = (Map<String, Object>) JSON.deserializeUntyped(raw);
        } catch (Exception ex) {
            throw new LogExpenseException('Could not parse extraction JSON. ' + ex.getMessage());
        }
        Extraction e = new Extraction();
        Object amtObj = parsed.get('amount');
        if (amtObj instanceof Decimal) e.amount = (Decimal) amtObj;
        else if (amtObj instanceof Integer) e.amount = Decimal.valueOf((Integer) amtObj);
        else if (amtObj instanceof Double) e.amount = Decimal.valueOf(String.valueOf(amtObj));
        else if (amtObj instanceof String) {
            try { e.amount = Decimal.valueOf((String) amtObj); } catch (Exception ex2) { e.amount = null; }
        }
        e.transactionDate = (String) parsed.get('transaction_date');
        e.physicianName = (String) parsed.get('physician_name');
        e.venue = (String) parsed.get('venue');
        e.descriptionClean = (String) parsed.get('description_clean');
        return e;
    }

    private static Date tryParseDate(String s) {
        if (String.isBlank(s)) return null;
        try { return Date.valueOf(s); } catch (Exception ex) { return null; }
    }

    private static Contact tryResolvePhysician(String physicianName) {
        if (String.isBlank(physicianName)) return null;
        String normalized = stripHonorific(physicianName);
        String pattern = '%' + String.escapeSingleQuotes(normalized) + '%';
        List<Contact> matches = [
            SELECT Id, Name FROM Contact
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

    private static Id findMostRecentWorkOrderForPhysician(Id physicianId) {
        List<VisitedParty> vps = [
            SELECT VisitId, Visit.ActualVisitStartTime
            FROM VisitedParty
            WHERE ContactId = :physicianId
              AND IsPrimaryContact = true
              AND Visit.VisitorId = :UserInfo.getUserId()
            WITH USER_MODE
            ORDER BY Visit.ActualVisitStartTime DESC
            LIMIT 1
        ];
        if (vps.isEmpty()) return null;
        Id visitId = vps[0].VisitId;
        List<WorkOrder> wos = [
            SELECT Id FROM WorkOrder
            WHERE Visit__c = :visitId
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        return wos.isEmpty() ? null : wos[0].Id;
    }

    private static Id getWorkOrderAccountId(Id woId) {
        List<WorkOrder> rows = [SELECT AccountId FROM WorkOrder WHERE Id = :woId WITH USER_MODE LIMIT 1];
        return rows.isEmpty() ? null : rows[0].AccountId;
    }

    private static String truncate(String s, Integer maxLen) {
        if (s == null) return null;
        return s.length() > maxLen ? s.substring(0, maxLen) : s;
    }

    private static String buildConfirmation(Decimal amount, String physicianFullName, Boolean linked) {
        String amt = amount.format();
        if (linked && physicianFullName != null) {
            return 'Logged. ' + amt + ' expense attached to your Visit WorkOrder for ' + physicianFullName + '.';
        }
        if (physicianFullName != null) {
            return 'Logged. ' + amt + ' expense for ' + physicianFullName + '. No matching Visit found — you can attach it manually.';
        }
        return 'Logged. ' + amt + ' expense for today.';
    }
}