public with sharing class GetClinicalBriefingAction {

    public class Request {
        @InvocableVariable(Label='Department' Description='Physician department/specialty, e.g. "Medical Oncology - Hematology"' Required=true)
        public String department;

        @InvocableVariable(Label='Physician Name' Description='Optional physician name for natural-sounding output, e.g. "Dr. Mehta"')
        public String physicianName;
    }

    public class Response {
        @InvocableVariable(Label='Briefing Text' Description='Generated clinical briefing — relay to user verbatim')
        public String briefingText;

        @InvocableVariable(Label='Source Department' Description='Echo of the input department')
        public String department;
    }

    private static final String PROMPT_TEMPLATE_API_NAME = 'Generate_Clinical_Briefing';

    @InvocableMethod(
        Label='Get Clinical Briefing'
        Description='Generates an ADL-grounded clinical briefing for a physician specialty using the onco_documents Data Library.'
        Category='Onco Global'
    )
    public static List<Response> getBriefing(List<Request> requests) {
        List<Response> out = new List<Response>();
        for (Request req : requests) {
            Response resp = new Response();
            resp.department = req.department;
            if (String.isBlank(req.department)) {
                resp.briefingText = 'No specialty provided. Cannot generate briefing.';
                out.add(resp);
                continue;
            }
            try {
                resp.briefingText = invokePromptTemplate(req.department, req.physicianName);
            } catch (Exception ex) {
                System.debug('[UC9] GetClinicalBriefingAction failed: ' + ex.getMessage());
                resp.briefingText = 'Briefing service is temporarily unavailable. Please refer to the Onco Global capability documents directly or contact the medical liaison team for ' + req.department + '.';
            }
            out.add(resp);
        }
        return out;
    }

    private static String invokePromptTemplate(String department, String physicianName) {
        ConnectApi.EinsteinPromptTemplateGenerationsInput genInput =
            new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        genInput.inputParams = new Map<String, ConnectApi.WrappedValue>();

        ConnectApi.WrappedValue deptWrap = new ConnectApi.WrappedValue();
        deptWrap.value = department;
        genInput.inputParams.put('Input:Department', deptWrap);

        ConnectApi.WrappedValue nameWrap = new ConnectApi.WrappedValue();
        nameWrap.value = String.isNotBlank(physicianName) ? physicianName : 'the physician';
        genInput.inputParams.put('Input:PhysicianName', nameWrap);

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
        throw new IllegalArgumentException('Prompt template returned empty generations.');
    }
}