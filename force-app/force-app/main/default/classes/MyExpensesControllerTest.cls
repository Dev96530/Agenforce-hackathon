@IsTest
private class MyExpensesControllerTest {
    @IsTest
    static void getRecentExpenses_returnsList() {
        List<MyExpensesController.RecentExpense> rows =
            MyExpensesController.getRecentExpenses(5);
        System.assertNotEquals(null, rows);
    }
    @IsTest
    static void getWeekTotal_returnsSummary() {
        MyExpensesController.Summary s = MyExpensesController.getWeekTotal();
        System.assertNotEquals(null, s);
        System.assertNotEquals(null, s.weekTotal);
    }
}