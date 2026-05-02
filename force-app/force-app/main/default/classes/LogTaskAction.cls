public with sharing class LogTaskAction {

    public class LogTaskException extends Exception {}

    public class Response {
        @InvocableVariable(Label='Task Count' Description='Number of Tasks created from the rep\'s utterance.')
        public Integer taskCount;

        @InvocableVariable(Label='Confirmation Message' Description='Human-readable sentence summarizing all tasks created. Safe to show verbatim to the rep.')
        public String confirmationMessage;
    }

    private static final String PROMPT_TEMPLATE_API_NAME = 'Extract_Task_From_Input';

    @InvocableMethod(
        Label='Log Task'
        Description='Creates one or more Task records from a rep\'s direct task / reminder utterance. Invokes the Extract_Task_From_Input prompt template to parse one or more tasks, optionally resolves a physician Contact, parses due dates, bulk-inserts Tasks. Physician resolution is best-effort — no match leaves WhoId null. Due-date parse failure leaves ActivityDate null.'
        Category='Agentforce'
    )
    public static List<Response> invoke(List<String> utterances) {
        List<Response> out = new List<Response>();
        for (String u : utterances) {
            out.add(logOne(u));
        }
        return out;
    }

    private static Response logOne(String utterance) {
        List<Map<String, Object>> items = extractTasksViaPromptTemplate(utterance);
        if (items == null || items.isEmpty()) {
            throw new LogTaskException('No task description found. Please rephrase.');
        }

        List<Task> toInsert = new List<Task>();
        List<String> summaries = new List<String>();
        Id myUserId = UserInfo.getUserId();

        for (Map<String, Object> item : items) {
            String taskDesc = (String) item.get('description');
            if (String.isBlank(taskDesc)) continue;

            Date dueDate = tryParseDate((String) item.get('due_date'));
            Contact physician = tryResolvePhysician((String) item.get('physician_name'));

            String subj = taskDesc.length() > 255 ? taskDesc.substring(0, 255) : taskDesc;
            Task t = new Task(
                Subject = subj,
                Description = taskDesc,
                ActivityDate = dueDate,
                WhoId = physician == null ? null : physician.Id,
                OwnerId = myUserId,
                Status = 'Not Started',
                Priority = 'Normal'
            );
            toInsert.add(t);
            summaries.add(summarizeOne(taskDesc, dueDate, physician == null ? null : physician.Name));
        }

        if (toInsert.isEmpty()) {
            throw new LogTaskException('No task description found. Please rephrase.');
        }

        insert as user toInsert;

        Response resp = new Response();
        resp.taskCount = toInsert.size();
        resp.confirmationMessage = buildConfirmation(summaries);
        return resp;
    }

    private static List<Map<String, Object>> extractTasksViaPromptTemplate(String utterance) {
        ConnectApi.EinsteinPromptTemplateGenerationsInput genInput =
            new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        genInput.inputParams = new Map<String, ConnectApi.WrappedValue>();

        ConnectApi.WrappedValue uwv = new ConnectApi.WrappedValue();
        uwv.value = utterance;
        genInput.inputParams.put('Input:TaskUtterance', uwv);

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
            throw new LogTaskException('Prompt template call failed: ' + ex.getMessage());
        }
        if (resp == null || resp.generations == null || resp.generations.isEmpty()) {
            throw new LogTaskException('Prompt template returned no generations.');
        }
        String raw = resp.generations[0].text;
        if (String.isBlank(raw)) {
            throw new LogTaskException('Prompt template returned empty text.');
        }
        Map<String, Object> parsed;
        try {
            parsed = (Map<String, Object>) JSON.deserializeUntyped(raw);
        } catch (Exception ex) {
            throw new LogTaskException('Could not parse extraction JSON. ' + ex.getMessage());
        }
        Object rawTasks = parsed.get('tasks');
        List<Map<String, Object>> items = new List<Map<String, Object>>();
        if (rawTasks instanceof List<Object>) {
            for (Object o : (List<Object>) rawTasks) {
                if (o instanceof Map<String, Object>) items.add((Map<String, Object>) o);
            }
        }
        return items;
    }

    private static Date tryParseDate(String s) {
        if (String.isBlank(s)) return null;
        try { return Date.valueOf(s); }
        catch (Exception ex) { return null; }
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

    private static String summarizeOne(String taskDesc, Date dueDate, String physicianName) {
        String clause = taskDesc;
        String dateWord = formatDueDate(dueDate);
        if (dateWord != null) clause += ', due ' + dateWord;
        return clause;
    }

    private static String formatDueDate(Date d) {
        if (d == null) return null;
        Date today = Date.today();
        Integer diff = today.daysBetween(d);
        if (diff == 0) return 'today';
        if (diff == 1) return 'tomorrow';
        if (diff == -1) return 'yesterday';
        if (diff > 1 && diff <= 7) {
            return DateTime.newInstance(d, Time.newInstance(0,0,0,0)).format('EEEE');
        }
        return DateTime.newInstance(d, Time.newInstance(0,0,0,0)).format('MMM d');
    }

    private static String buildConfirmation(List<String> summaries) {
        if (summaries.isEmpty()) return 'No tasks created.';
        if (summaries.size() == 1) return 'Task added: ' + summaries[0] + '.';
        String result = summaries.size() + ' tasks added:';
        for (Integer i = 0; i < summaries.size(); i++) {
            result += ' (' + (i + 1) + ') ' + summaries[i] + '.';
        }
        return result;
    }
}