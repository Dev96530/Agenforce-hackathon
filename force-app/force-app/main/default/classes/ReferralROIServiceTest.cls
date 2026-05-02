/**
 * Unit tests for ReferralROIService.
 * Tests focus on deterministic helpers (quarter, summary builder, sorting)
 * that don't hit the Data Cloud endpoint. Integration testing happens via
 * anonymous Apex scripts (see scripts/verify-referralroi.apex).
 */
@IsTest
public class ReferralROIServiceTest {

    @IsTest
    static void computeCurrentQuarter_returnsMatchingFormat() {
        String q = ReferralROIService.computeCurrentQuarter();
        Integer year = Date.today().year();
        Integer month = Date.today().month();
        Integer expectedQ = ((month - 1) / 3) + 1;
        System.assertEquals('Q' + expectedQ + '-' + year, q);
    }

    @IsTest
    static void buildSummary_emptyInputs_returnsZeroedSummary() {
        List<ReferralROIService.PhysicianROIRow> empty = new List<ReferralROIService.PhysicianROIRow>();
        ReferralROIService.RepROISummary s = ReferralROIService.buildSummary(empty, empty, empty, 'Q2-2026');
        System.assertEquals('Q2-2026', s.quarter);
        System.assertEquals(0, s.totalAttributedRevenue);
        System.assertEquals(0, s.totalArrivedPatients);
        System.assertEquals(0, s.totalContributingPhysicians);
        System.assert(s.topByROI.isEmpty());
        System.assert(s.needsAttention.isEmpty());
    }

    @IsTest
    static void buildSummary_twoAttributed_topByROISortedDesc() {
        List<ReferralROIService.PhysicianROIRow> attributed = new List<ReferralROIService.PhysicianROIRow>();
        attributed.add(makeRow(fakeContactId(1), 'Dr. Mehta', 630000, 3, 6));
        attributed.add(makeRow(fakeContactId(2), 'Dr. Sharma', 210000, 1, 0));

        ReferralROIService.RepROISummary s = ReferralROIService.buildSummary(
            attributed, new List<ReferralROIService.PhysicianROIRow>(), new List<ReferralROIService.PhysicianROIRow>(), 'Q2-2026');
        System.assertEquals(840000, s.totalAttributedRevenue);
        System.assertEquals(4, s.totalArrivedPatients);
        System.assertEquals(2, s.totalContributingPhysicians);
        System.assertEquals(2, s.topByROI.size());
        System.assertEquals('Dr. Mehta', s.topByROI[0].physicianName);
        System.assertEquals('Dr. Sharma', s.topByROI[1].physicianName);
    }

    @IsTest
    static void buildSummary_fourAttributed_topByROICappedAtThree() {
        List<ReferralROIService.PhysicianROIRow> attributed = new List<ReferralROIService.PhysicianROIRow>();
        for (Integer i = 1; i <= 4; i++) {
            attributed.add(makeRow(fakeContactId(i), 'Dr. ' + i, i * 100000, 1, 0));
        }
        ReferralROIService.RepROISummary s = ReferralROIService.buildSummary(
            attributed, new List<ReferralROIService.PhysicianROIRow>(), new List<ReferralROIService.PhysicianROIRow>(), 'Q2-2026');
        System.assertEquals(3, s.topByROI.size());
        System.assertEquals(400000, s.topByROI[0].attributedRevenue);
    }

    @IsTest
    static void buildSummary_needsAttentionWithReferralsTakesPrecedence() {
        List<ReferralROIService.PhysicianROIRow> needs = new List<ReferralROIService.PhysicianROIRow>();
        needs.add(makeRow(fakeContactId(10), 'Dr. Reddy', 0, 0, 2));   // 2 referrals
        needs.add(makeRow(fakeContactId(11), 'Dr. Other', 0, 0, 0));   // 0 referrals

        ReferralROIService.RepROISummary s = ReferralROIService.buildSummary(
            new List<ReferralROIService.PhysicianROIRow>(), needs, new List<ReferralROIService.PhysicianROIRow>(), 'Q2-2026');
        System.assertEquals(1, s.needsAttention.size());
        System.assertEquals('Dr. Reddy', s.needsAttention[0].physicianName);
    }

    @IsTest
    static void buildSummary_needsAttentionFallbackWhenNoReferrals() {
        List<ReferralROIService.PhysicianROIRow> needs = new List<ReferralROIService.PhysicianROIRow>();
        needs.add(makeRow(fakeContactId(20), 'Dr. Reddy', 0, 0, 0));
        needs.add(makeRow(fakeContactId(21), 'Dr. Other', 0, 0, 0));

        ReferralROIService.RepROISummary s = ReferralROIService.buildSummary(
            new List<ReferralROIService.PhysicianROIRow>(), needs, new List<ReferralROIService.PhysicianROIRow>(), 'Q2-2026');
        System.assertEquals(2, s.needsAttention.size());
    }

    /**
     * Generate a valid-shape Contact Id (18 chars) for use in unit tests.
     * Id.valueOf() validates format, so test fixtures need proper Id structure.
     */
    private static String fakeContactId(Integer seed) {
        // Id format: 18 chars = 3 prefix + 12 middle + 3 checksum-ish
        String hex = String.valueOf(seed);
        String padded = '000000000000'.substring(0, 12 - hex.length()) + hex;
        return '003' + padded + 'AAA';
    }

    private static ReferralROIService.PhysicianROIRow makeRow(String cid, String name, Decimal rev, Integer arrived, Integer refs) {
        ReferralROIService.PhysicianROIRow r = new ReferralROIService.PhysicianROIRow();
        r.contactId = cid;
        r.physicianName = name;
        r.specialty = 'Test Specialty';
        r.attributedRevenue = rev;
        r.arrivedCount = arrived;
        r.referralCount = refs;
        return r;
    }
}