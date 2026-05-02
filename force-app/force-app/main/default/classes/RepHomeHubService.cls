public with sharing class RepHomeHubService {

    public class HomeData {
        @AuraEnabled public KpiData kpi;
        @AuraEnabled public TaskGroups tasks;
        @AuraEnabled public List<VisitCard> visits;
        @AuraEnabled public ExpenseData expenses;
        @AuraEnabled public List<AlertCard> alerts;
        @AuraEnabled public BriefingData briefing;
    }

    public class KpiData {
        @AuraEnabled public Integer visitsToday;
        @AuraEnabled public Integer tasksDueToday;
        @AuraEnabled public Integer overdueTasks;
        @AuraEnabled public Decimal expenseWeekTotal;
        @AuraEnabled public Integer unlinkedExpenseCount;
        @AuraEnabled public Integer missingVisitNotes;
    }

    public class TaskGroups {
        @AuraEnabled public List<TaskItem> overdue;
        @AuraEnabled public List<TaskItem> today;
        @AuraEnabled public List<TaskItem> upcoming;
        @AuraEnabled public List<TaskItem> recentCompleted;
    }

    public class TaskItem {
        @AuraEnabled public Id id;
        @AuraEnabled public String subject;
        @AuraEnabled public String status;
        @AuraEnabled public String priority;
        @AuraEnabled public Date activityDate;
        @AuraEnabled public Id whoId;
        @AuraEnabled public String whoName;
        @AuraEnabled public Id whatId;
        @AuraEnabled public String whatType;
    }

    public class VisitCard {
        @AuraEnabled public Id visitId;
        @AuraEnabled public String physicianName;
        @AuraEnabled public String clinicName;
        @AuraEnabled public String visitTypeName;
        @AuraEnabled public Datetime visitTime;
        @AuraEnabled public String sentiment;
        @AuraEnabled public String summary;
        @AuraEnabled public Boolean hasNotes;
        @AuraEnabled public Boolean needsFollowup;
    }

    public class ExpenseData {
        @AuraEnabled public Decimal weekTotal;
        @AuraEnabled public Integer weekCount;
        @AuraEnabled public Decimal monthTotal;
        @AuraEnabled public Integer monthCount;
        @AuraEnabled public Integer unlinkedCount;
        @AuraEnabled public List<MyExpensesController.RecentExpense> recent;
    }

    public class AlertCard {
        @AuraEnabled public String type;
        @AuraEnabled public String title;
        @AuraEnabled public String detail;
        @AuraEnabled public String ctaLabel;
        @AuraEnabled public String ctaAction;
        @AuraEnabled public String targetId;
    }

    public class BriefingData {
        @AuraEnabled public String body;
        @AuraEnabled public List<String> nextBestActions;
    }

    public class ActionResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String message;
    }

    private static final Integer TASK_LIMIT = 50;
    private static final Integer VISIT_LIMIT = 8;

    @AuraEnabled(cacheable=true)
    public static HomeData getHomeData() {
        Id userId = UserInfo.getUserId();
        HomeData data = new HomeData();
        data.kpi = buildKpi(userId);
        data.tasks = buildTasks(userId);
        data.visits = buildVisits(userId);
        data.expenses = buildExpenses();
        data.alerts = buildAlerts(data);
        //data.briefing = buildBriefing(userId, data.alerts);
        return data;
    }

    @AuraEnabled
    public static ActionResult completeTask(Id taskId) {
        ActionResult result = new ActionResult();
        if (taskId == null) {
            result.success = false;
            result.message = 'Task Id is required.';
            return result;
        }
        List<Task> rows = [
            SELECT Id, Status
            FROM Task
            WHERE Id = :taskId AND OwnerId = :UserInfo.getUserId()
            WITH USER_MODE
            LIMIT 1
        ];
        if (rows.isEmpty()) {
            result.success = false;
            result.message = 'Task not found.';
            return result;
        }
        Task t = rows[0];
        t.Status = 'Completed';
        update as user t;
        result.success = true;
        result.message = 'Task marked as completed.';
        return result;
    }

    @AuraEnabled
    public static ActionResult rescheduleTask(Id taskId, Date newDate) {
        ActionResult result = new ActionResult();
        if (taskId == null || newDate == null) {
            result.success = false;
            result.message = 'Task Id and date are required.';
            return result;
        }
        List<Task> rows = [
            SELECT Id, ActivityDate
            FROM Task
            WHERE Id = :taskId AND OwnerId = :UserInfo.getUserId()
            WITH USER_MODE
            LIMIT 1
        ];
        if (rows.isEmpty()) {
            result.success = false;
            result.message = 'Task not found.';
            return result;
        }
        Task t = rows[0];
        t.ActivityDate = newDate;
        update as user t;
        result.success = true;
        result.message = 'Task rescheduled.';
        return result;
    }

    @AuraEnabled
    public static ActionResult linkExpenseToVisit(Id expenseId, Id visitId) {
        ActionResult result = new ActionResult();
        if (expenseId == null || visitId == null) {
            result.success = false;
            result.message = 'Expense Id and Visit Id are required.';
            return result;
        }
        List<WorkOrder> woRows = [
            SELECT Id
            FROM WorkOrder
            WHERE Visit__c = :visitId
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (woRows.isEmpty()) {
            result.success = false;
            result.message = 'No work order found for the selected visit.';
            return result;
        }
        List<Expense> expRows = [
            SELECT Id, OwnerId
            FROM Expense
            WHERE Id = :expenseId
            WITH USER_MODE
            LIMIT 1
        ];
        if (expRows.isEmpty() || expRows[0].OwnerId != UserInfo.getUserId()) {
            result.success = false;
            result.message = 'Expense not found.';
            return result;
        }
        Expense exp = expRows[0];
        exp.WorkOrderId = woRows[0].Id;
        update as user exp;
        result.success = true;
        result.message = 'Expense linked to visit.';
        return result;
    }

    private static KpiData buildKpi(Id userId) {
        KpiData kpi = new KpiData();
        Date today = Date.today();
        Date weekStart = today.toStartOfWeek();

        kpi.visitsToday = [
            SELECT COUNT()
            FROM Visit
            WHERE VisitorId = :userId
              AND PlannedVisitStartTime = TODAY
            WITH USER_MODE
        ];
        kpi.tasksDueToday = [
            SELECT COUNT()
            FROM Task
            WHERE OwnerId = :userId
              AND Status != 'Completed'
              AND ActivityDate = :today
            WITH USER_MODE
        ];
        kpi.overdueTasks = [
            SELECT COUNT()
            FROM Task
            WHERE OwnerId = :userId
              AND Status != 'Completed'
              AND ActivityDate < :today
            WITH USER_MODE
        ];
        kpi.unlinkedExpenseCount = [
            SELECT COUNT()
            FROM Expense
            WHERE OwnerId = :userId
              AND WorkOrderId = null
              AND TransactionDate >= :weekStart
            WITH USER_MODE
        ];
        List<AggregateResult> notesAgg = [
            SELECT COUNT(Id) cnt
            FROM Visit
            WHERE VisitorId = :userId
              AND ActualVisitStartTime = THIS_WEEK
              AND (StatusRemarks = null OR StatusRemarks = '')
            WITH USER_MODE
        ];
        kpi.missingVisitNotes = (Integer) notesAgg[0].get('cnt');
        MyExpensesController.Summary s = MyExpensesController.getWeekTotal();
        kpi.expenseWeekTotal = s == null || s.weekTotal == null ? 0 : s.weekTotal;
        return kpi;
    }

    private static TaskGroups buildTasks(Id userId) {
        Date today = Date.today();
        TaskGroups groups = new TaskGroups();
        groups.overdue = new List<TaskItem>();
        groups.today = new List<TaskItem>();
        groups.upcoming = new List<TaskItem>();
        groups.recentCompleted = new List<TaskItem>();

        List<Task> rows = [
            SELECT Id, Subject, Status, Priority, ActivityDate, WhoId, Who.Name, WhatId, What.Type
            FROM Task
            WHERE OwnerId = :userId
            WITH USER_MODE
            ORDER BY ActivityDate ASC NULLS LAST, LastModifiedDate DESC
            LIMIT :TASK_LIMIT
        ];

        for (Task t : rows) {
            TaskItem item = toTaskItem(t);
            if (t.Status == 'Completed') {
                groups.recentCompleted.add(item);
            } else if (t.ActivityDate != null && t.ActivityDate < today) {
                groups.overdue.add(item);
            } else if (t.ActivityDate == today) {
                groups.today.add(item);
            } else {
                groups.upcoming.add(item);
            }
        }
        groups.recentCompleted = trim(groups.recentCompleted, 8);
        groups.overdue = trim(groups.overdue, 8);
        groups.today = trim(groups.today, 8);
        groups.upcoming = trim(groups.upcoming, 8);
        return groups;
    }

    private static List<VisitCard> buildVisits(Id userId) {
        List<VisitCard> out = new List<VisitCard>();
        Set<Id> visitIds = new Set<Id>();
        for (Visit v : [
            SELECT Id, Account.Name, VisitType.Name, ActualVisitStartTime, PlannedVisitStartTime, StatusRemarks, Rep_Sentiment__c
            FROM Visit
            WHERE VisitorId = :userId
            WITH USER_MODE
            ORDER BY ActualVisitStartTime DESC NULLS LAST, PlannedVisitStartTime DESC NULLS LAST
            LIMIT :VISIT_LIMIT
        ]) {
            visitIds.add(v.Id);
            VisitCard c = new VisitCard();
            c.visitId = v.Id;
            c.clinicName = v.Account == null ? null : v.Account.Name;
            c.visitTypeName = v.VisitType == null ? null : v.VisitType.Name;
            c.visitTime = v.ActualVisitStartTime == null ? v.PlannedVisitStartTime : v.ActualVisitStartTime;
            c.sentiment = (String) v.get('Rep_Sentiment__c');
            c.summary = v.StatusRemarks;
            c.hasNotes = !String.isBlank(v.StatusRemarks);
            c.needsFollowup = false;
            out.add(c);
        }

        Map<Id, String> visitToDoctor = new Map<Id, String>();
        if (!visitIds.isEmpty()) {
            for (VisitedParty vp : [
                SELECT VisitId, Contact.Name
                FROM VisitedParty
                WHERE VisitId IN :visitIds
                  AND IsPrimaryContact = true
                WITH USER_MODE
            ]) {
                visitToDoctor.put(vp.VisitId, vp.Contact == null ? null : vp.Contact.Name);
            }
            Set<Id> withTasks = new Set<Id>();
            for (Task t : [
                SELECT Id, WhatId
                FROM Task
                WHERE OwnerId = :userId
                  AND WhatId IN :visitIds
                  AND Status != 'Completed'
                WITH USER_MODE
                LIMIT 200
            ]) {
                if (t.WhatId != null) withTasks.add(t.WhatId);
            }
            for (VisitCard card : out) {
                card.physicianName = visitToDoctor.get(card.visitId);
                card.needsFollowup = !withTasks.contains(card.visitId);
            }
        }
        return out;
    }

    private static ExpenseData buildExpenses() {
        ExpenseData data = new ExpenseData();
        MyExpensesController.Summary s = MyExpensesController.getWeekTotal();
        data.weekTotal = s == null || s.weekTotal == null ? 0 : s.weekTotal;
        data.weekCount = s == null || s.weekCount == null ? 0 : s.weekCount;
        data.monthTotal = s == null || s.monthTotal == null ? 0 : s.monthTotal;
        data.monthCount = s == null || s.monthCount == null ? 0 : s.monthCount;
        data.recent = MyExpensesController.getRecentExpenses(6);
        data.unlinkedCount = [
            SELECT COUNT()
            FROM Expense
            WHERE OwnerId = :UserInfo.getUserId()
              AND WorkOrderId = null
              AND TransactionDate = THIS_MONTH
            WITH USER_MODE
        ];
        return data;
    }

    private static List<AlertCard> buildAlerts(HomeData data) {
        List<AlertCard> alerts = new List<AlertCard>();
        for (TaskItem t : data.tasks.overdue) {
            AlertCard a = new AlertCard();
            a.type = 'task_overdue';
            a.title = 'Overdue Task';
            a.detail = t.subject + (t.activityDate == null ? '' : ' (due ' + String.valueOf(t.activityDate) + ')');
            a.ctaLabel = 'Complete';
            a.ctaAction = 'completeTask';
            a.targetId = String.valueOf(t.id);
            alerts.add(a);
        }
        for (VisitCard v : data.visits) {
            if (!v.hasNotes) {
                AlertCard a = new AlertCard();
                a.type = 'visit_missing_notes';
                a.title = 'Visit Notes Missing';
                a.detail = 'Add notes for ' + safeLabel(v.physicianName) + ' at ' + safeLabel(v.clinicName) + '.';
                a.ctaLabel = 'Open Visit';
                a.ctaAction = 'openVisit';
                a.targetId = String.valueOf(v.visitId);
                alerts.add(a);
            }
        }
        for (MyExpensesController.RecentExpense e : data.expenses.recent) {
            if (e.linkedToVisit == false) {
                AlertCard a = new AlertCard();
                a.type = 'expense_unlinked';
                a.title = 'Unlinked Expense';
                a.detail = 'Attach "' + safeLabel(e.title) + '" to a visit.';
                a.ctaLabel = 'Open Expense';
                a.ctaAction = 'openExpense';
                a.targetId = e.id;
                alerts.add(a);
            }
        }

        try {
            ReferralROIService.RepROISummary roi = ReferralROIService.getRepROISummary(UserInfo.getUserId());
            if (roi != null && roi.needsAttention != null && !roi.needsAttention.isEmpty()) {
                ReferralROIService.PhysicianROIRow p = roi.needsAttention[0];
                AlertCard a = new AlertCard();
                a.type = 'high_value_stale';
                a.title = 'High Value Follow-up';
                a.detail = p.physicianName + ' has referral potential. Schedule a touchpoint.';
                a.ctaLabel = 'Open Physician';
                a.ctaAction = 'openContact';
                a.targetId = p.contactId;
                alerts.add(a);
            }
        } catch (Exception ignored) {
            // Data Cloud-derived section is optional.
        }

        return trimAlerts(alerts, 8);
    }

    private static BriefingData buildBriefing(Id userId, List<AlertCard> alerts) {
        BriefingData b = new BriefingData();
        b.nextBestActions = new List<String>();
        try {
            List<MorningBriefingService.Briefing> rows = MorningBriefingService.generateBriefings(
                new List<String>{ String.valueOf(userId) }
            );
            if (!rows.isEmpty()) {
                b.body = rows[0].briefingBody;
            }
        } catch (Exception ignored) {
            b.body = null;
        }
        for (Integer i = 0; i < alerts.size() && i < 3; i++) {
            b.nextBestActions.add(alerts[i].detail);
        }
        if (String.isBlank(b.body)) {
            b.body = b.nextBestActions.isEmpty()
                ? 'No urgent actions. Focus on relationship-building visits.'
                : 'Top priorities: ' + String.join(b.nextBestActions, ' | ');
        }
        return b;
    }

    private static TaskItem toTaskItem(Task t) {
        TaskItem i = new TaskItem();
        i.id = t.Id;
        i.subject = t.Subject;
        i.status = t.Status;
        i.priority = t.Priority;
        i.activityDate = t.ActivityDate;
        i.whoId = t.WhoId;
        i.whoName = t.Who == null ? null : t.Who.Name;
        i.whatId = t.WhatId;
        i.whatType = t.What == null ? null : t.What.Type;
        return i;
    }

    private static List<TaskItem> trim(List<TaskItem> inRows, Integer size) {
        if (inRows.size() <= size) return inRows;
        List<TaskItem> out = new List<TaskItem>();
        for (Integer i = 0; i < size; i++) out.add(inRows[i]);
        return out;
    }

    private static List<AlertCard> trimAlerts(List<AlertCard> inRows, Integer size) {
        if (inRows.size() <= size) return inRows;
        List<AlertCard> out = new List<AlertCard>();
        for (Integer i = 0; i < size; i++) out.add(inRows[i]);
        return out;
    }

    private static String safeLabel(String s) {
        return String.isBlank(s) ? 'Unknown' : s;
    }
}