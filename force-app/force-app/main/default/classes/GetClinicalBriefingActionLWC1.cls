/**
 * UC9 — LWC v1 isolated experiment.
 *
 * Same input/output shape as GetClinicalBriefingActionLWC (text variant), BUT
 * returns a Custom Lightning Type (`ClinicalBriefingCard`) so the
 * clinicalBriefingCard1 LWC renders a card instead of plain text.
 *
 * Delegates business logic to the working GetClinicalBriefingAction (text)
 * via the same SOQL → existing-action chain. Apex changes are pure shape
 * transformation: wrap the briefingText in a flat 3-String CLT object.
 *
 * Fully isolated — does NOT touch GetClinicalBriefingActionLWC. If the LWC
 * card fails to render, the agent script can be rolled back to the text
 * variant in one paste.
 */
public with sharing class GetClinicalBriefingActionLWC1 {

    public class Request {
        @InvocableVariable(Label='Physician Name' Description='Physician name (any common form: "Dr. Mehta", "Priya Mehta", "Mehta"). The action SOQL-resolves the Contact and pulls Department internally, then delegates to GetClinicalBriefingAction.' Required=true)
        public String physicianName;
    }

    public class Response {
        @InvocableVariable(Label='Clinical Briefing Card' Description='Structured ADL-grounded briefing for LWC card render — flat 3-String CLT.')
        public ClinicalBriefingCard briefing;
    }

    /**
     * Rich CLT shape — primitives + List<String> only (NO nested inner classes).
     * Lightning Type cannot introspect List<NestedInnerClass> — see memory
     * `feedback_lightning_type_no_nested_innerclass_in_list.md`. Parallel
     * List<String> arrays for talking-point rows is the supported pattern.
     *
     * `briefingText` is the raw LLM response — always populated, used by the
     * LWC as a fallback when the parser couldn't extract structured fields.
     * Adding fields is additive — the previous flat 3-String shape still works.
     */
    public class ClinicalBriefingCard {
        @InvocableVariable public String physicianName;
        @InvocableVariable public String department;
        @InvocableVariable public String introLine;
        @InvocableVariable public List<String> talkingPointTitles;
        @InvocableVariable public List<String> talkingPointBodies;
        @InvocableVariable public String closingQuestion;
        @InvocableVariable public String briefingText;
        @InvocableVariable public Boolean parseSucceeded;
    }

    @InvocableMethod(
        Label='Get Clinical Briefing (LWC v1)'
        Description='Generates an ADL-grounded clinical briefing for a physician, structured as a flat CLT for LWC card render. Resolves Department from physicianName via SOQL, delegates to GetClinicalBriefingAction.'
        Category='Onco Global'
    )
    public static List<Response> getBriefingForCard(List<Request> requests) {
        List<Response> out = new List<Response>();
        for (Request req : requests) {
            Response wrapper = new Response();
            wrapper.briefing = build(req.physicianName);
            out.add(wrapper);
        }
        return out;
    }

    private static ClinicalBriefingCard build(String physicianName) {
        ClinicalBriefingCard card = new ClinicalBriefingCard();
        card.parseSucceeded = false;

        if (String.isBlank(physicianName)) {
            card.physicianName = 'the physician';
            card.department = '';
            card.briefingText = 'No physician name provided. Cannot generate briefing.';
            return card;
        }

        Contact resolved = tryResolvePhysician(physicianName);
        if (resolved == null) {
            card.physicianName = physicianName;
            card.department = '';
            card.briefingText = 'I could not find a physician matching "' + physicianName + '" in the system. Please double-check the name and try again.';
            return card;
        }

        card.physicianName = resolved.Name;
        card.department = (resolved.Department == null) ? '' : resolved.Department;

        if (String.isBlank(card.department)) {
            card.briefingText = resolved.Name + ' does not have a specialty / Department on file. Cannot generate a specialty-specific clinical briefing.';
            return card;
        }

        // Delegate to the existing text path.
        GetClinicalBriefingAction.Request oldReq = new GetClinicalBriefingAction.Request();
        oldReq.department = card.department;
        oldReq.physicianName = card.physicianName;
        List<GetClinicalBriefingAction.Response> oldResp =
            GetClinicalBriefingAction.getBriefing(
                new List<GetClinicalBriefingAction.Request>{ oldReq }
            );

        if (oldResp == null || oldResp.isEmpty() || String.isBlank(oldResp[0].briefingText)) {
            card.briefingText = 'Briefing service is temporarily unavailable. Please contact the medical liaison team for ' + card.department + '.';
            return card;
        }
        card.briefingText = oldResp[0].briefingText;

        // Best-effort parse the LLM response into structured fields. If parsing
        // fails, the LWC falls back to rendering briefingText as plain text.
        parseInto(card, card.briefingText);
        return card;
    }

    /**
     * Parse LLM output of the form:
     *   <intro line ending in colon>
     *   <blank>
     *   1. **<title>.** <body>
     *   <blank>
     *   2. **<title>.** <body>
     *   ...
     *   <blank>
     *   <closing question>
     */
    private static void parseInto(ClinicalBriefingCard card, String text) {
        if (String.isBlank(text)) return;
        String normalized = text.trim();

        // 1) Intro = first non-empty line ending with ':'
        Matcher introMatcher = Pattern.compile('^([^\\n]+:)\\s*\\n').matcher(normalized);
        if (introMatcher.find()) {
            card.introLine = introMatcher.group(1).trim();
        }

        // 2) Closing = last paragraph if it ends with '?'
        String[] paragraphs = normalized.split('\\n\\n');
        if (paragraphs.size() > 0) {
            String last = paragraphs[paragraphs.size() - 1].trim();
            if (last.endsWith('?')) {
                card.closingQuestion = last;
            }
        }

        // 3) Talking points — match each "N. **title.** body" block. Populate
        // parallel List<String> arrays (titles[i] pairs with bodies[i]).
        List<String> titles = new List<String>();
        List<String> bodies = new List<String>();
        Pattern p = Pattern.compile('(?ms)^(\\d+)\\.\\s+\\*\\*([^*\\n]+?)\\*\\*\\s*(.+?)(?=\\n\\s*\\d+\\.\\s+\\*\\*|\\n\\n[A-Za-z][^\\n]*\\?\\s*$|\\Z)');
        Matcher m = p.matcher(normalized);
        while (m.find()) {
            titles.add(stripTrailingPeriod(m.group(2).trim()));
            bodies.add(collapseWhitespace(m.group(3).trim()));
        }

        if (!titles.isEmpty()) {
            card.talkingPointTitles = titles;
            card.talkingPointBodies = bodies;
            card.parseSucceeded = true;
        }
    }

    private static String stripTrailingPeriod(String s) {
        if (String.isBlank(s)) return s;
        return s.endsWith('.') ? s.substring(0, s.length() - 1) : s;
    }

    private static String collapseWhitespace(String s) {
        if (String.isBlank(s)) return s;
        return s.replaceAll('\\s+', ' ').trim();
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