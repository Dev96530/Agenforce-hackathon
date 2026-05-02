@IsTest
private class LogVisitFromTranscriptActionTest {

    @IsTest
    static void invoke_blankTranscript_throws() {
        Boolean threw = false;
        try {
            LogVisitFromTranscriptAction.invoke(new List<String>{ '' });
        } catch (LogVisitFromTranscriptAction.LogVisitException e) {
            threw = true;
            System.assert(
                e.getMessage().toLowerCase().contains('transcript'),
                'Expected a transcript-required message, got: ' + e.getMessage()
            );
        }
        System.assertEquals(true, threw, 'Blank transcript must throw LogVisitException.');
    }
}