/**
 * UC9 — text-only fallback variant.
 *
 * Takes only physicianName as input. SOQL-resolves the Contact + Department,
 * then delegates to the existing GetClinicalBriefingAction (which invokes the
 * Generate_Clinical_Briefing prompt template) and returns the briefing as a
 * plain String — no Custom Lightning Type, no nested data shapes.
 *
 * The ClinicalBriefingCard inner class is kept declared (unused) so the
 * deployed lightningTypes/clinicalBriefingCard schema continues to compile
 * cleanly. We can revive a CLT-based path later by switching the Response
 * back to expose a structured object.
 */
public with sharing class GetClinicalBriefingActionLWC {

    public class Request {
        @InvocableVariable(Label='Physician Name' Description='Physician name (any common form: "Dr. Mehta", "Priya Mehta", "Mehta"). The action SOQL-resolves the Contact and pulls Department internally, then delegates to GetClinicalBriefingAction.' Required=true)
        public String physicianName;
    }

    public class Response {
        @InvocableVariable(Label='Briefing Text' Description='Generated clinical briefing — already formatted with numbered talking points and a closing question. Relay verbatim.')
        public String briefingText;
    }

    /**
     * Kept declared (unused) so the existing lightningTypes/clinicalBriefingCard
     * schema (`@apexClassType/c__GetClinicalBriefingActionLWC$ClinicalBriefingCard`)
     * still resolves at deploy time. Future iteration may switch Response back
     * to exposing this CLT instead of a flat String.
     */
    @SuppressWarnings('PMD.UnusedLocalVariable')
    public class ClinicalBriefingCard {
        @InvocableVariable public String physicianName;
        @InvocableVariable public String department;
        @InvocableVariable public String briefingText;
    }

    @InvocableMethod(
        Label='Get Clinical Briefing (LWC card)'
        Description='Generates an ADL-grounded clinical briefing for a physician specialty. Resolves Department from physicianName via SOQL, delegates to GetClinicalBriefingAction.'
        Category='Onco Global'
    )
    public static List<Response> getBriefingForCard(List<Request> requests) {
        List<Response> out = new List<Response>();
        for (Request req : requests) {
            Response wrapper = new Response();
            wrapper.briefingText = generateBriefing(req.physicianName);
            out.add(wrapper);
        }
        return out;
    }

    private static String generateBriefing(String physicianName) {
        if (String.isBlank(physicianName)) {
            return 'No physician name provided. Cannot generate briefing.';
        }
        Contact resolved = tryResolvePhysician(physicianName);
        if (resolved == null) {
            return 'I could not find a physician matching "' + physicianName + '" in the system. Please double-check the name and try again.';
        }
        if (String.isBlank(resolved.Department)) {
            return resolved.Name + ' does not have a specialty / Department on file. Cannot generate a specialty-specific clinical briefing.';
        }

        // Delegate to the existing GetClinicalBriefingAction — proven working
        // path that invokes the Generate_Clinical_Briefing prompt template and
        // returns text. Reuse instead of re-implementing.
        GetClinicalBriefingAction.Request oldReq = new GetClinicalBriefingAction.Request();
        oldReq.department = resolved.Department;
        oldReq.physicianName = resolved.Name;

        List<GetClinicalBriefingAction.Response> oldResp =
            GetClinicalBriefingAction.getBriefing(
                new List<GetClinicalBriefingAction.Request>{ oldReq }
            );

        if (oldResp == null || oldResp.isEmpty() || String.isBlank(oldResp[0].briefingText)) {
            return 'Briefing service is temporarily unavailable. Please contact the medical liaison team for ' + resolved.Department + '.';
        }
        return oldResp[0].briefingText;
    }

    private static Contact tryResolvePhysician(String physicianName) {
        if (String.isBlank(physicianName)) return null;
        String normalized = stripHonorific(physicianName);
        if (String.isBlank(normalized)) return null;
        String pattern = '%' + String.escapeSingleQuotes(normalized) + '%';
        List<Contact> matches = [
            SELECT Id, Name, Department FROM Contact
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
}