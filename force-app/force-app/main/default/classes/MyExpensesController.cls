public with sharing class MyExpensesController {

    public class RecentExpense {
        @AuraEnabled public String id;
        @AuraEnabled public Decimal amount;
        @AuraEnabled public Date transactionDate;
        @AuraEnabled public String title;
        @AuraEnabled public String physicianFullName;
        @AuraEnabled public Boolean linkedToVisit;
    }

    public class Summary {
        @AuraEnabled public Decimal weekTotal;
        @AuraEnabled public Integer weekCount;
        @AuraEnabled public Decimal monthTotal;
        @AuraEnabled public Integer monthCount;
    }

    @AuraEnabled(cacheable=true)
    public static List<RecentExpense> getRecentExpenses(Integer limitCount) {
        Integer lim = (limitCount == null || limitCount <= 0) ? 5 : limitCount;
        List<Expense> rows = [
            SELECT Id, Amount, TransactionDate, Title, WorkOrderId
            FROM Expense
            WHERE OwnerId = :UserInfo.getUserId()
            WITH USER_MODE
            ORDER BY TransactionDate DESC, CreatedDate DESC
            LIMIT :lim
        ];
        Set<Id> workOrderIds = new Set<Id>();
        for (Expense e : rows) if (e.WorkOrderId != null) workOrderIds.add(e.WorkOrderId);
        Map<Id, String> woToPhysicianName = resolveWorkOrderPhysicians(workOrderIds);
        List<RecentExpense> out = new List<RecentExpense>();
        for (Expense e : rows) {
            RecentExpense r = new RecentExpense();
            r.id = e.Id;
            r.amount = e.Amount;
            r.transactionDate = e.TransactionDate;
            r.title = e.Title;
            r.physicianFullName = woToPhysicianName.get(e.WorkOrderId);
            r.linkedToVisit = (e.WorkOrderId != null);
            out.add(r);
        }
        return out;
    }

    @AuraEnabled(cacheable=true)
    public static Summary getWeekTotal() {
        Date weekStart = Date.today().toStartOfWeek();
        Date monthStart = Date.today().toStartOfMonth();
        AggregateResult[] wk = [
            SELECT SUM(Amount) tot, COUNT(Id) cnt
            FROM Expense
            WHERE OwnerId = :UserInfo.getUserId() AND TransactionDate >= :weekStart
            WITH USER_MODE
        ];
        AggregateResult[] mo = [
            SELECT SUM(Amount) tot, COUNT(Id) cnt
            FROM Expense
            WHERE OwnerId = :UserInfo.getUserId() AND TransactionDate >= :monthStart
            WITH USER_MODE
        ];
        Summary s = new Summary();
        Object wkTot = wk[0].get('tot');
        Object moTot = mo[0].get('tot');
        s.weekTotal = wkTot == null ? 0 : (Decimal) wkTot;
        s.weekCount = (Integer) wk[0].get('cnt');
        s.monthTotal = moTot == null ? 0 : (Decimal) moTot;
        s.monthCount = (Integer) mo[0].get('cnt');
        return s;
    }

    private static Map<Id, String> resolveWorkOrderPhysicians(Set<Id> workOrderIds) {
        Map<Id, String> out = new Map<Id, String>();
        if (workOrderIds.isEmpty()) return out;
        Map<Id, Id> woToVisit = new Map<Id, Id>();
        for (WorkOrder wo : [
            SELECT Id, Visit__c FROM WorkOrder
            WHERE Id IN :workOrderIds AND Visit__c != null
            WITH USER_MODE
        ]) {
            woToVisit.put(wo.Id, wo.Visit__c);
        }
        if (woToVisit.isEmpty()) return out;
        Map<Id, Id> visitToContact = new Map<Id, Id>();
        for (VisitedParty vp : [
            SELECT VisitId, ContactId FROM VisitedParty
            WHERE VisitId IN :woToVisit.values() AND IsPrimaryContact = true
            WITH USER_MODE
        ]) {
            visitToContact.put(vp.VisitId, vp.ContactId);
        }
        Map<Id, String> contactIdToName = new Map<Id, String>();
        for (Contact c : [
            SELECT Id, Name FROM Contact
            WHERE Id IN :visitToContact.values()
            WITH USER_MODE
        ]) {
            contactIdToName.put(c.Id, c.Name);
        }
        for (Id woId : workOrderIds) {
            Id visitId = woToVisit.get(woId);
            if (visitId == null) continue;
            Id contactId = visitToContact.get(visitId);
            if (contactId == null) continue;
            out.put(woId, contactIdToName.get(contactId));
        }
        return out;
    }
}