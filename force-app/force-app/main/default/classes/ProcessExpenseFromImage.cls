public without sharing class ProcessExpenseFromImage {

    public class ProcessExpenseFromImageException extends Exception {}

    private static final String PROMPT_TEMPLATE_API_NAME = 'Extract_Expense_From_Receipt';
    private static final Set<String> IMAGE_FILE_TYPES = new Set<String>{ 'PNG', 'JPG', 'JPEG', 'HEIC', 'WEBP' };

    public class Response {
        @InvocableVariable(Label='Success' Description='Whether the expense was successfully created.')
        public Boolean success;
        @InvocableVariable(Label='Expense Id' Description='Id of the newly created Expense, or null on failure.')
        public String expenseId;
        @InvocableVariable(Label='Amount' Description='The extracted amount.')
        public Decimal amount;
        @InvocableVariable(Label='Expense Type' Description='The descriptive expense type (Meals / Lodging / Mileage / Travel / Other).')
        public String expenseType;
        @InvocableVariable(Label='Venue' Description='The extracted venue / merchant.')
        public String venue;
        @InvocableVariable(Label='Confirmation Message' Description='Verbatim confirmation to relay to the user.')
        public String confirmationMessage;
    }

    public class Extraction {
        public Decimal amount;
        public String expenseType;
        public Date transactionDate;
        public String venue;
        public String descriptionClean;
    }

    @InvocableMethod(
        Label='Process Expense From Image'
        Description='Reads the latest receipt image from a WhatsApp messaging session, extracts expense details via a vision prompt template, creates an Expense record, and attaches the receipt to the record.'
        Category='Agentforce'
    )
    public static List<Response> invoke(List<String> messagingSessionIds) {
        System.debug('[UC5][invoke] ENTRY runningUser=' + UserInfo.getUserId()
            + ' userName=' + UserInfo.getUserName()
            + ' inputCount=' + (messagingSessionIds == null ? 0 : messagingSessionIds.size())
            + ' inputs=' + messagingSessionIds);

        List<Response> out = new List<Response>();
        for (String msId : messagingSessionIds) {
            out.add(processOne(msId));
        }

        System.debug('[UC5][invoke] EXIT responses=' + JSON.serialize(out));
        return out;
    }

    private static Response processOne(String messagingSessionId) {
        System.debug('[UC5][processOne] BEGIN sessionId=' + messagingSessionId);
        Response r = new Response();
        r.success = false;

        if (String.isBlank(messagingSessionId)) {
            System.debug('[UC5][processOne] blank sessionId — throwing');
            throw new ProcessExpenseFromImageException('Missing messaging session id.');
        }

        Id repUserId;
        try {
            repUserId = resolveRepUserId(messagingSessionId);
            System.debug('[UC5][processOne] resolved repUserId=' + repUserId);
        } catch (Exception ex) {
            System.debug('[UC5][processOne] resolveRepUserId FAILED: ' + ex.getTypeName() + ' | ' + ex.getMessage());
            throw ex;
        }

        ContentDocumentLink sessionLink = findLatestImageLink(messagingSessionId);
        if (sessionLink == null) {
            System.debug('[UC5][processOne] sessionLink=NULL — no recent image, soft-fail');
            r.confirmationMessage =
                'I don\'t see your receipt image yet. Could you resend it with the caption "process my expenses"?';
            return r;
        }
        System.debug('[UC5][processOne] sessionLink found: cdId=' + sessionLink.ContentDocumentId
            + ' title=' + sessionLink.ContentDocument.Title
            + ' fileType=' + sessionLink.ContentDocument.FileType
            + ' createdDate=' + sessionLink.ContentDocument.CreatedDate);

        Extraction e;
        try {
            e = extractViaPromptTemplate(sessionLink.ContentDocumentId);
            System.debug('[UC5][processOne] extraction: amount=' + e.amount
                + ' expenseType=' + e.expenseType
                + ' transactionDate=' + e.transactionDate
                + ' venue=' + e.venue
                + ' descriptionClean=' + e.descriptionClean);
        } catch (Exception ex) {
            System.debug('[UC5][processOne] extractViaPromptTemplate FAILED: ' + ex.getTypeName() + ' | ' + ex.getMessage());
            throw ex;
        }

        if (e.amount == null) {
            System.debug('[UC5][processOne] amount is null — non-receipt, soft-fail');
            r.confirmationMessage =
                'I couldn\'t read the amount on your receipt. Could you retry with a clearer photo, or dictate the expense instead?';
            return r;
        }

        String description = (String.isNotBlank(e.expenseType) ? '[' + e.expenseType + '] ' : '')
            + (String.isNotBlank(e.descriptionClean) ? e.descriptionClean : 'Receipt');

        Expense exp = new Expense(
            OwnerId = repUserId,
            Amount = e.amount,
            ExpenseType = 'Billable',
            TransactionDate = e.transactionDate,
            Title = String.isNotBlank(e.venue) ? e.venue : 'Receipt',
            Description = description
        );
        System.debug('[UC5][processOne] inserting Expense: ' + JSON.serialize(exp));
        try {
            insert exp;
            System.debug('[UC5][processOne] Expense inserted Id=' + exp.Id);
        } catch (Exception ex) {
            System.debug('[UC5][processOne] Expense insert FAILED: ' + ex.getTypeName() + ' | ' + ex.getMessage());
            throw ex;
        }

        Boolean imageAttached = true;
        try {
            ContentDocumentLink link = new ContentDocumentLink(
                ContentDocumentId = sessionLink.ContentDocumentId,
                LinkedEntityId = exp.Id,
                ShareType = 'V',
                Visibility = 'AllUsers'
            );
            System.debug('[UC5][processOne] inserting ContentDocumentLink: ' + JSON.serialize(link));
            insert link;
            System.debug('[UC5][processOne] ContentDocumentLink inserted Id=' + link.Id);
        } catch (Exception linkEx) {
            System.debug(LoggingLevel.WARN, '[UC5][processOne] CDLink attach FAILED: '
                + linkEx.getTypeName() + ' | ' + linkEx.getMessage());
            imageAttached = false;
        }

        r.success = true;
        r.expenseId = exp.Id;
        r.amount = e.amount;
        r.expenseType = e.expenseType;
        r.venue = e.venue;

        String amountStr = e.amount.setScale(0).format();
        String typePart = String.isNotBlank(e.expenseType) ? (' ' + e.expenseType) : '';
        String venuePart = String.isNotBlank(e.venue) ? (' at ' + e.venue) : '';
        String attachedPart = imageAttached
            ? ' Image attached to the expense record.'
            : ' (Note: the original image couldn\'t be attached to the record — you may want to add it manually.)';
        r.confirmationMessage =
            'Logged. ₹' + amountStr + typePart + ' expense created from your receipt' + venuePart + ' for today.' + attachedPart;

        System.debug('[UC5][processOne] END success=true confirmation=' + r.confirmationMessage);
        return r;
    }

    private static Id resolveRepUserId(String messagingSessionId) {
        System.debug('[UC5][resolveRep] BEGIN sessionId=' + messagingSessionId);

        List<MessagingSession> msList = [
            SELECT Id, MessagingEndUserId, Status, CreatedDate
            FROM MessagingSession
            WHERE Id = :messagingSessionId
            LIMIT 1
        ];
        System.debug('[UC5][resolveRep] MessagingSession query returned ' + msList.size() + ' rows');
        if (msList.isEmpty()) {
            throw new ProcessExpenseFromImageException(
                'MessagingSession ' + messagingSessionId + ' not found (session may be ended or inaccessible).'
            );
        }
        MessagingSession ms = msList[0];
        System.debug('[UC5][resolveRep] session: Id=' + ms.Id
            + ' MessagingEndUserId=' + ms.MessagingEndUserId
            + ' Status=' + ms.Status
            + ' CreatedDate=' + ms.CreatedDate);

        if (ms.MessagingEndUserId == null) {
            throw new ProcessExpenseFromImageException(
                'Could not identify the WhatsApp end user for this session.'
            );
        }

        List<MessagingEndUser> euList = [
            SELECT Id, MessagingPlatformKey, Name
            FROM MessagingEndUser
            WHERE Id = :ms.MessagingEndUserId
            LIMIT 1
        ];
        System.debug('[UC5][resolveRep] MessagingEndUser query returned ' + euList.size() + ' rows');
        if (euList.isEmpty()) {
            throw new ProcessExpenseFromImageException(
                'MessagingEndUser ' + ms.MessagingEndUserId + ' not found.'
            );
        }
        MessagingEndUser eu = euList[0];
        System.debug('[UC5][resolveRep] endUser: Id=' + eu.Id
            + ' MessagingPlatformKey="' + eu.MessagingPlatformKey + '"'
            + ' Name=' + eu.Name);

        String normalizedKey = normalizePhone(eu.MessagingPlatformKey);
        System.debug('[UC5][resolveRep] normalizedKey=' + normalizedKey);
        if (String.isBlank(normalizedKey)) {
            throw new ProcessExpenseFromImageException(
                'Could not read a phone number from MessagingPlatformKey.'
            );
        }

        Integer scanned = 0;
        for (User u : [
            SELECT Id, Name, MobilePhone
            FROM User
            WHERE IsActive = true AND MobilePhone != null
        ]) {
            scanned++;
            String normalizedUser = normalizePhone(u.MobilePhone);
            if (normalizedUser == normalizedKey) {
                System.debug('[UC5][resolveRep] MATCH after ' + scanned + ' scans: user=' + u.Id
                    + ' (' + u.Name + ') MobilePhone="' + u.MobilePhone + '" normalized=' + normalizedUser);
                return u.Id;
            }
        }
        System.debug('[UC5][resolveRep] NO MATCH after scanning ' + scanned + ' users with non-null MobilePhone');
        throw new ProcessExpenseFromImageException(
            'Please ask your admin to add your WhatsApp mobile number to your Salesforce user record (User.MobilePhone). (Searched ' + scanned + ' active users, none matched normalized key ' + normalizedKey + ')'
        );
    }

    private static String normalizePhone(String raw) {
        if (String.isBlank(raw)) return null;
        String digits = raw.replaceAll('[^0-9]', '');
        if (digits.length() < 10) return digits;
        return digits.substring(digits.length() - 10);
    }

    private static ContentDocumentLink findLatestImageLink(String messagingSessionId) {
        System.debug('[UC5][findImage] BEGIN sessionId=' + messagingSessionId + ' now=' + Datetime.now());

        // Step 1: total links on the session (diagnostic)
        Integer totalLinks = [
            SELECT count() FROM ContentDocumentLink WHERE LinkedEntityId = :messagingSessionId
        ];
        System.debug('[UC5][findImage] total ContentDocumentLinks on session = ' + totalLinks);

        // Step 2: all links with their doc details (diagnostic — up to 10)
        List<ContentDocumentLink> allLinks = [
            SELECT Id, ContentDocumentId,
                   ContentDocument.Title, ContentDocument.FileType, ContentDocument.CreatedDate
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :messagingSessionId
            ORDER BY ContentDocument.CreatedDate DESC
            LIMIT 10
        ];
        for (ContentDocumentLink l : allLinks) {
            System.debug('[UC5][findImage]   link cdId=' + l.ContentDocumentId
                + ' fileType=' + l.ContentDocument.FileType
                + ' title=' + l.ContentDocument.Title
                + ' created=' + l.ContentDocument.CreatedDate
                + ' isImageType=' + IMAGE_FILE_TYPES.contains(l.ContentDocument.FileType));
        }

        // Step 3: actual filter query — latest image, no time window
        List<ContentDocumentLink> links = [
            SELECT Id, ContentDocumentId,
                   ContentDocument.Title, ContentDocument.FileType, ContentDocument.CreatedDate
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :messagingSessionId
              AND ContentDocument.FileType IN :IMAGE_FILE_TYPES
            ORDER BY ContentDocument.CreatedDate DESC
            LIMIT 1
        ];
        System.debug('[UC5][findImage] filtered query returned ' + links.size() + ' rows');
        if (!links.isEmpty()) {
            System.debug('[UC5][findImage] chosen: cdId=' + links[0].ContentDocumentId
                + ' title=' + links[0].ContentDocument.Title
                + ' created=' + links[0].ContentDocument.CreatedDate);
        }
        return links.isEmpty() ? null : links[0];
    }

    public  static Extraction extractViaPromptTemplate(Id contentDocumentId) {
        System.debug('[UC5][extract] BEGIN cdId=' + contentDocumentId
            + ' templateName=' + PROMPT_TEMPLATE_API_NAME);

        // The Prompt Template's file fetch runs in the INVOKING user's security context
        // (not Apex system mode). When invoked by the einsteinAgent user, that user needs
        // a direct ContentDocumentLink to the receipt. Without it, the runtime can't resolve
        // the binary and falls back to the template's placeholder text.
        Id currentUserId = UserInfo.getUserId();
        List<ContentDocumentLink> existingShares = [
            SELECT Id FROM ContentDocumentLink
            WHERE ContentDocumentId = :contentDocumentId
              AND LinkedEntityId = :currentUserId
            LIMIT 1
        ];
        if (existingShares.isEmpty()) {
            try {
                insert new ContentDocumentLink(
                    ContentDocumentId = contentDocumentId,
                    LinkedEntityId = currentUserId,
                    ShareType = 'V',
                    Visibility = 'AllUsers'
                );
                System.debug('[UC5][extract] Shared CD with running user ' + currentUserId);
            } catch (Exception shareEx) {
                System.debug(LoggingLevel.WARN, '[UC5][extract] Direct share insert failed: '
                    + shareEx.getTypeName() + ' | ' + shareEx.getMessage());
            }
        } else {
            System.debug('[UC5][extract] CD already shared with running user ' + currentUserId);
        }

        ConnectApi.EinsteinPromptTemplateGenerationsInput pin =
            new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        pin.inputParams = new Map<String, ConnectApi.WrappedValue>();

        // Pattern per Salesforce Stack Exchange #438423: key is 'type' (not 'sobjectType'),
        // value is Map<String, String>, pass the ContentDocument Id directly.
        ConnectApi.WrappedValue receiptWv = new ConnectApi.WrappedValue();
        Map<String, String> receiptRef = new Map<String, String>{
            'id' => contentDocumentId,
            'type' => 'ContentDocument'
        };
        receiptWv.value = receiptRef;
        pin.inputParams.put('Input:Receipt', receiptWv);
        System.debug('[UC5][extract] Input:Receipt value=' + receiptRef);

        ConnectApi.WrappedValue dateWv = new ConnectApi.WrappedValue();
        String todayStr = Date.today().format();
        dateWv.value = todayStr;
        pin.inputParams.put('Input:CurrentDate', dateWv);
        System.debug('[UC5][extract] Input:CurrentDate value=' + todayStr);

        pin.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        pin.additionalConfig.applicationName = 'PromptBuilderPreview';
        pin.isPreview = false;

        System.debug('[UC5][extract] calling ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate...');
        ConnectApi.EinsteinPromptTemplateGenerationsRepresentation resp =
            ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(
                PROMPT_TEMPLATE_API_NAME, pin
            );
        System.debug('[UC5][extract] response received. generations='
            + (resp == null || resp.generations == null ? 'null' : String.valueOf(resp.generations.size()))
            + ' errors=' + (resp == null ? 'null' : String.valueOf(resp.generationErrors)));

        if (resp == null || resp.generations == null || resp.generations.isEmpty()) {
            throw new ProcessExpenseFromImageException(
                'Prompt template returned no generations. Resp=' + JSON.serialize(resp)
            );
        }
        String raw = resp.generations[0].text;
        System.debug('[UC5][extract] raw response text=' + raw);

        Map<String, Object> parsed;
        try {
            parsed = (Map<String, Object>) JSON.deserializeUntyped(raw);
        } catch (Exception ex) {
            throw new ProcessExpenseFromImageException(
                'Could not parse receipt extraction JSON: ' + ex.getMessage() + ' | raw=' + raw
            );
        }
        System.debug('[UC5][extract] parsed=' + parsed);

        Extraction e = new Extraction();
        Object amt = parsed.get('amount');
        if (amt instanceof Decimal) e.amount = (Decimal) amt;
        else if (amt instanceof Integer) e.amount = Decimal.valueOf((Integer) amt);
        else if (amt instanceof Double) e.amount = Decimal.valueOf(String.valueOf(amt));
        else if (amt instanceof String && String.isNotBlank((String) amt)) e.amount = Decimal.valueOf((String) amt);
        e.expenseType = (String) parsed.get('expense_type');
        String dateStr = (String) parsed.get('transaction_date');
        e.transactionDate = String.isNotBlank(dateStr) ? Date.valueOf(dateStr) : Date.today();
        e.venue = (String) parsed.get('venue');
        e.descriptionClean = (String) parsed.get('description_clean');

        System.debug('[UC5][extract] END extraction built');
        return e;
    }
}