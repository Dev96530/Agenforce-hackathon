@IsTest
private class RepHomeHubServiceTest {

    @IsTest
    static void getHomeData_returnsPayload() {
        Test.startTest();
        RepHomeHubService.HomeData data = RepHomeHubService.getHomeData();
        Test.stopTest();

        System.assertNotEquals(null, data);
        System.assertNotEquals(null, data.kpi);
        System.assertNotEquals(null, data.tasks);
        System.assertNotEquals(null, data.visits);
        System.assertNotEquals(null, data.expenses);
        System.assertNotEquals(null, data.alerts);
        System.assertNotEquals(null, data.briefing);
    }

    @IsTest
    static void completeTask_nullInput_returnsError() {
        RepHomeHubService.ActionResult res = RepHomeHubService.completeTask(null);
        System.assertEquals(false, res.success);
        System.assert(res.message.contains('required'));
    }

    @IsTest
    static void completeTask_success() {
        Task t = new Task(
            Subject = 'Follow up physician',
            OwnerId = UserInfo.getUserId(),
            Status = 'Not Started',
            Priority = 'Normal',
            ActivityDate = Date.today()
        );
        insert t;

        Test.startTest();
        RepHomeHubService.ActionResult res = RepHomeHubService.completeTask(t.Id);
        Test.stopTest();

        System.assertEquals(true, res.success);
        Task updated = [SELECT Status FROM Task WHERE Id = :t.Id LIMIT 1];
        System.assertEquals('Completed', updated.Status);
    }

    @IsTest
    static void rescheduleTask_nullInput_returnsError() {
        RepHomeHubService.ActionResult res = RepHomeHubService.rescheduleTask(null, null);
        System.assertEquals(false, res.success);
    }

    @IsTest
    static void rescheduleTask_success() {
        Task t = new Task(
            Subject = 'Visit prep',
            OwnerId = UserInfo.getUserId(),
            Status = 'Not Started',
            Priority = 'Normal',
            ActivityDate = Date.today()
        );
        insert t;

        Date tomorrow = Date.today().addDays(1);
        Test.startTest();
        RepHomeHubService.ActionResult res = RepHomeHubService.rescheduleTask(t.Id, tomorrow);
        Test.stopTest();

        System.assertEquals(true, res.success);
        Task updated = [SELECT ActivityDate FROM Task WHERE Id = :t.Id LIMIT 1];
        System.assertEquals(tomorrow, updated.ActivityDate);
    }

    @IsTest
    static void linkExpenseToVisit_nullInput_returnsError() {
        RepHomeHubService.ActionResult res = RepHomeHubService.linkExpenseToVisit(null, null);
        System.assertEquals(false, res.success);
    }
}