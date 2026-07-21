/**
 * Tests for the LWC adapter.
 *
 * The controller is deliberately thin, so there are only two things worth
 * proving: that it stamps the source as Community regardless of what the client
 * sent, and that domain errors come back as AuraHandledException rather than as
 * a raw stack trace on a public site.
 */
@IsTest
private class ApplicationIntakeControllerTest {

    private static ApplicationIntakeRequest buildRequest() {
        ApplicationIntakeRequest req = new ApplicationIntakeRequest();
        req.companyName      = 'Acme Corporation';
        req.email            = 'partner@acme.com';
        req.phone            = '11999999999';
        req.contactFirstName = 'Joao';
        req.contactLastName  = 'Silva';
        return req;
    }


    /**
     * Happy path with no matching Account: the submission becomes a Lead and the
     * source is recorded as Community.
     */
    @IsTest
    static void submitsFromCommunityAndCreatesLead() {
        ApplicationIntakeRequest req = buildRequest();
        req.companyName = 'Nobody Knows Ltd';

        Test.startTest();
        ApplicationIntakeService.Result result =
            ApplicationIntakeController.submitApplication(req);
        Test.stopTest();

        Assert.isTrue(result.success);
        Assert.areEqual('Lead', result.recordType);
        Assert.isNotNull(result.applicationId);

        Lead ld = [SELECT ApplicationSource__c FROM Lead LIMIT 1];
        Assert.areEqual(
            ApplicationIntakeConstants.SOURCE_COMMUNITY,
            ld.ApplicationSource__c,
            'Controller must stamp the source itself'
        );
    }


    /**
     * A client that tries to declare itself as the webhook must be overridden.
     * `source` is not @AuraEnabled, so the framework should already drop it —
     * this pins that behaviour down rather than trusting it.
     */
    @IsTest
    static void ignoresClientSuppliedSource() {
        ApplicationIntakeRequest req = buildRequest();
        req.companyName = 'Nobody Knows Ltd';
        req.source      = ApplicationIntakeConstants.SOURCE_WEBHOOK;

        Test.startTest();
        ApplicationIntakeController.submitApplication(req);
        Test.stopTest();

        Application__c app = [SELECT Source__c FROM Application__c LIMIT 1];
        Assert.areEqual(
            ApplicationIntakeConstants.SOURCE_COMMUNITY,
            app.Source__c,
            'A community submission must not be able to pass itself off as a webhook call'
        );
    }


    /**
     * A matching Account produces an Opportunity through this path too.
     */
    @IsTest
    static void matchedAccountCreatesOpportunity() {
        insert new Account(Name = 'Acme Corporation');

        Test.startTest();
        ApplicationIntakeService.Result result =
            ApplicationIntakeController.submitApplication(buildRequest());
        Test.stopTest();

        Assert.areEqual('Opportunity', result.recordType);
        Assert.areEqual('Company Name', result.matchedBy);
    }


    /**
     * Invalid input surfaces as AuraHandledException, not as the domain
     * exception and not as an unhandled failure.
     *
     * Note: AuraHandledException.getMessage() returns a generic string in test
     * context, so the assertion is on the type rather than on the wording.
     */
    @IsTest
    static void invalidRequestThrowsAuraHandledException() {
        ApplicationIntakeRequest req = buildRequest();
        req.email = 'not-an-email';

        Test.startTest();
        Boolean threw = false;
        try {
            ApplicationIntakeController.submitApplication(req);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Validation failures must reach the component as AuraHandledException');
        Assert.areEqual(0, [SELECT COUNT() FROM Application__c], 'Nothing should be written');
        Assert.areEqual(0, [SELECT COUNT() FROM Lead]);
    }
}