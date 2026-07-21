/**
 * Functional tests for the intake pipeline.
 *
 * No @TestSetup: each scenario needs a different Account landscape, and one
 * shared fixture would make the "no match" case impossible to express.
 * SeeAllData is off, so the org's real Accounts are invisible here — every
 * match below is driven purely by data this class creates.
 */
@IsTest
private class ApplicationIntakeServiceTest {

    private static final String TAX_ID_RAW        = '12.345.678/0001-99';
    private static final String TAX_ID_NORMALIZED = '12345678000199';

    private static ApplicationIntakeRequest buildRequest() {
        ApplicationIntakeRequest req = new ApplicationIntakeRequest();
        req.companyName      = 'Acme Corporation';
        req.email            = 'partner@acme.com';
        req.phone            = '11999999999';
        req.contactFirstName = 'Joao';
        req.contactLastName  = 'Silva';
        req.annualRevenue    = 500000;
        req.source           = ApplicationIntakeConstants.SOURCE_WEBHOOK;
        return req;
    }


    /**
     * Scenario 1 — Tax ID match wins.
     * Setup: one Account carrying the normalized Tax ID, deliberately named
     * differently from the request so only the Tax ID can explain the match.
     * The request sends the masked form, exercising normalization end to end.
     */
    @IsTest
    static void taxIdMatchCreatesOpportunity() {
        insert new Account(Name = 'Totally Different Name', FederalTaxID__c = TAX_ID_NORMALIZED);

        ApplicationIntakeRequest req = buildRequest();
        req.federalTaxId = TAX_ID_RAW;

        Test.startTest();
        ApplicationIntakeService.Result result = ApplicationIntakeService.submit(req);
        Test.stopTest();

        Assert.isTrue(result.success, 'Submission should succeed');
        Assert.areEqual('Opportunity', result.recordType, 'Matched account must yield an Opportunity');
        Assert.areEqual('Tax ID', result.matchedBy, 'Tax ID must take precedence');
        Assert.areEqual(0, [SELECT COUNT() FROM Lead], 'No Lead should be created on a match');

        Application__c app = [
            SELECT MatchedBy__c, Opportunity__c, Lead__c,
                   Account__c, ErrorMessage__c
            FROM Application__c LIMIT 1
        ];
        Assert.isNull(app.ErrorMessage__c, 'A successful run leaves no error behind');
        Assert.areEqual(result.recordId, app.Opportunity__c);
        Assert.isNull(app.Lead__c);
        Assert.isNotNull(app.Account__c);
    }


    /**
     * Scenario 2 — Company Name fallback.
     * Setup: an Account whose name equals the request's company name and which
     * has NO Tax ID. The request omits the Tax ID entirely, so the first rule
     * short-circuits and the fallback is the only path to a match.
     */
    @IsTest
    static void companyNameMatchCreatesOpportunity() {
        insert new Account(Name = 'Acme Corporation');

        ApplicationIntakeRequest req = buildRequest();
        req.federalTaxId = null;

        Test.startTest();
        ApplicationIntakeService.Result result = ApplicationIntakeService.submit(req);
        Test.stopTest();

        Assert.isTrue(result.success);
        Assert.areEqual('Opportunity', result.recordType);
        Assert.areEqual('Company Name', result.matchedBy, 'Fallback rule should have matched');

        Opportunity opp = [SELECT AccountId, ApplicationSource__c, Amount FROM Opportunity LIMIT 1];
        Assert.isNotNull(opp.AccountId);
        Assert.areEqual(ApplicationIntakeConstants.SOURCE_WEBHOOK, opp.ApplicationSource__c);
        Assert.isNull(opp.Amount, 'Annual revenue must not be mapped onto Amount');
    }


    /**
     * Scenario 3 — no match at all.
     * Setup: intentionally empty. No Account is inserted, and the request's
     * Tax ID belongs to nobody, so both rules miss and the system falls back
     * to Lead creation.
     */
    @IsTest
    static void noMatchCreatesLead() {
        ApplicationIntakeRequest req = buildRequest();
        req.companyName  = 'Unknown Partner Ltd';
        req.federalTaxId = '99999999999999';

        Test.startTest();
        ApplicationIntakeService.Result result = ApplicationIntakeService.submit(req);
        Test.stopTest();

        Assert.isTrue(result.success);
        Assert.areEqual('Lead', result.recordType, 'Unmatched submission must become a Lead');
        Assert.areEqual('No Match', result.matchedBy);
        Assert.areEqual(0, [SELECT COUNT() FROM Opportunity], 'No Opportunity without an Account');

        Lead ld = [SELECT Company, LastName, Email, AnnualRevenue, ApplicationSource__c FROM Lead LIMIT 1];
        Assert.areEqual('Unknown Partner Ltd', ld.Company);
        Assert.areEqual('Silva', ld.LastName);
        Assert.areEqual(500000, ld.AnnualRevenue, 'Annual revenue maps directly on Lead');

        Application__c app = [SELECT Lead__c, ErrorMessage__c FROM Application__c LIMIT 1];
        Assert.isNull(app.ErrorMessage__c);
        Assert.areEqual(ld.Id, app.Lead__c);
    }


    /**
     * Scenario 4 — failure path.
     * Setup: none. A request missing a required field is rejected by the
     * validator before anything is written, so no staging record is created.
     */
    @IsTest
    static void invalidRequestIsRejected() {
        ApplicationIntakeRequest req = buildRequest();
        req.contactLastName = null;

        Test.startTest();
        Boolean threw = false;
        try {
            ApplicationIntakeService.submit(req);
        } catch (ApplicationIntakeException e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Validator should reject a missing required field');
        Assert.areEqual(0, [SELECT COUNT() FROM Application__c], 'Invalid payload must not reach staging');
        Assert.areEqual(0, [SELECT COUNT() FROM Lead]);
        Assert.areEqual(0, [SELECT COUNT() FROM Opportunity]);
    }


    /**
     * Scenario 5 — webhook adapter end to end, including alias handling.
     * Setup: none needed for the unmatched path. The JSON deliberately uses
     * snake_case keys that differ from the DTO property names.
     */
    @IsTest
    static void webhookAcceptsFlexiblePayload() {
        RestRequest req = new RestRequest();
        req.requestBody = Blob.valueOf(
            '{"company_name":"Webhook Partner","email":"hook@partner.com",' +
            '"phone":"11888888888","first_name":"Maria","last_name":"Souza"}'
        );
        RestContext.request  = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        ApplicationIntakeRestResource.doPost();
        Test.stopTest();

        Assert.areEqual(201, RestContext.response.statusCode);
        Lead ld = [SELECT Company, LastName, ApplicationSource__c FROM Lead LIMIT 1];
        Assert.areEqual('Webhook Partner', ld.Company, 'Alias mapping should have resolved company_name');
        Assert.areEqual(ApplicationIntakeConstants.SOURCE_WEBHOOK, ld.ApplicationSource__c);
    }


    /**
     * Scenario 6 — malformed body is rejected with a 400, not a 500.
     */
    @IsTest
    static void webhookRejectsMalformedJson() {
        RestRequest req = new RestRequest();
        req.requestBody = Blob.valueOf('this is not json');
        RestContext.request  = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        ApplicationIntakeRestResource.doPost();
        Test.stopTest();

        Assert.areEqual(400, RestContext.response.statusCode, 'Bad input is the caller\'s fault');
        Assert.areEqual(0, [SELECT COUNT() FROM Application__c]);
    }
}