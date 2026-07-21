/**
 * Orchestrates application intake from the public Experience Cloud site (LWC)
 * and from the external webhook (REST).
 *
 * `without sharing` is deliberate: the guest user cannot see any Account, so a
 * `with sharing` class would silently turn every submission into a Lead.
 */
public without sharing class ApplicationIntakeService {

    private static final String MATCH_TAX_ID       = 'Tax ID';
    private static final String MATCH_COMPANY_NAME = 'Company Name';
    private static final String MATCH_NONE         = 'No Match';


    // -------------------------------------------------------------------
    // Result returned to the adapters (LWC controller / REST resource).
    // -------------------------------------------------------------------
    public class Result {
        @AuraEnabled public Id      applicationId;
        @AuraEnabled public Id      recordId;
        @AuraEnabled public String  recordType;
        @AuraEnabled public String  matchedBy;
        @AuraEnabled public Boolean success;
        @AuraEnabled public String  errorMessage;
    }


    /**
     *
     * Validation runs before the insert. Once the Application__c exists, any failure is caught and
     * recorded on the record itself — no Savepoint is being used.
     */
    public static Result submit(ApplicationIntakeRequest req) {

        ApplicationIntakeValidator.validate(req);

        Application__c app = buildApplication(req);
        insert app;

        Result res = new Result();
        res.applicationId = app.Id;

        try {
            Account matched = findAccount(req, app);

            if (matched != null) {
                Opportunity opp = buildOpportunity(req, matched.Id);
                insert opp;

                app.Opportunity__c = opp.Id;
                app.Account__c     = matched.Id;
                res.recordId   = opp.Id;
                res.recordType = 'Opportunity';
            } else {
                Lead ld = buildLead(req);
                insert ld;

                app.Lead__c = ld.Id;
                res.recordId   = ld.Id;
                res.recordType = 'Lead';
            }

            res.success   = true;

        } catch (Exception e) {
            app.ErrorMessage__c = e.getTypeName() + ': ' + e.getMessage();

            res.success      = false;
            res.errorMessage = e.getMessage();
        }

        res.matchedBy = app.MatchedBy__c;
        update app;

        return res;
    }


    /**
     * Matching rule from the spec: prefer Federal Tax ID, fall back to Company Name.
     *
     * Intentional side effect: populates app.Matched_By__c.
     */
    private static Account findAccount(ApplicationIntakeRequest req, Application__c app) {

        String taxId = ApplicationIntakeParser.normalizeTaxId(req.federalTaxId);

        if (String.isNotBlank(taxId)) {
            List<Account> byTaxId = [
                SELECT Id FROM Account WHERE FederalTaxID__c = :taxId LIMIT 1
            ];
            if (!byTaxId.isEmpty()) {
                app.MatchedBy__c = MATCH_TAX_ID;
                return byTaxId[0];
            }
        }

        if (String.isNotBlank(req.companyName)) {
            List<Account> byName = [
                SELECT Id FROM Account WHERE Name = :req.companyName LIMIT 1
            ];
            if (!byName.isEmpty()) {
                app.MatchedBy__c = MATCH_COMPANY_NAME;
                return byName[0];
            }
        }

        app.MatchedBy__c = MATCH_NONE;
        return null;
    }


    /**
     * Builds the staging record. No DML.
     */
    private static Application__c buildApplication(ApplicationIntakeRequest req) {
        return new Application__c(
            CompanyName__c      = req.companyName,
            Email__c            = req.email,
            Phone__c            = req.phone,
            ContactFirstName__c = req.contactFirstName,
            ContactLastName__c  = req.contactLastName,
            FederalTaxID__c     = ApplicationIntakeParser.normalizeTaxId(req.federalTaxId),
            AnnualRevenue__c    = req.annualRevenue,
            Source__c           = req.source,
            Payload__c          = req.rawPayload
        );
    }


    /**
     * Builds the Lead. No DML.
     * AnnualRevenue maps directly — same semantics on the target object.
     * Lead assignment rules do not fire on Apex inserts by default (see README).
     */
    private static Lead buildLead(ApplicationIntakeRequest req) {
        return new Lead(
            FirstName             = req.contactFirstName,
            LastName              = req.contactLastName,
            Company               = req.companyName,
            Email                 = req.email,
            Phone                 = req.phone,
            AnnualRevenue         = req.annualRevenue,
            ApplicationSource__c = req.source
        );
    }


    /**
     * Builds the Opportunity. No DML.
     *
     * StageName and CloseDate are platform-required. The values below only satisfy the insert.
     *
     * Amount is intentionally left
     */
    private static Opportunity buildOpportunity(ApplicationIntakeRequest req, Id accountId) {
        return new Opportunity(
            AccountId             = accountId,
            Name                  = req.companyName + ' - Application',
            StageName             = 'Prospecting',
            CloseDate             = Date.today().addDays(30),
            ApplicationSource__c = req.source
        );
    }
}