# Salesforce Application Intake

## Overview

The Salesforce Application Intake solution handles partner applications submitted through two channels:

* An Experience Cloud form.
* A REST webhook for external systems.

Both entry points follow the same process:

1. Validate the request.
2. Store the submission in `Application__c`.
3. Try to find an existing Account.
4. Create an Opportunity when an Account is found.
5. Create a Lead when no Account is found.
6. Store the processing result or error on `Application__c`.

The main business logic is centralized in `ApplicationIntakeService`, while the LWC and REST resource act as lightweight entry points.

---

## Architecture

```text
LWC Form ──► ApplicationIntakeController ──┐
                                           ├──► ApplicationIntakeService ──► Application__c
REST POST ─► ApplicationIntakeRestResource ─┘                              └──► Lead | Opportunity
```

Supporting classes have focused responsibilities:

* `ApplicationIntakeParser` – Parses and normalizes incoming JSON.
* `ApplicationIntakeValidator` – Validates required fields.
* `ApplicationIntakeRequest` – DTO for incoming requests.
* `ApplicationIntakeException` – Handles expected request and validation errors.

Keeping the business logic in the service layer also makes the core rules easier to test without depending on HTTP or UI-specific logic.

---

## Application__c as a Staging Record

Every submission is stored in `Application__c` before any Lead or Opportunity is created.

This provides an audit trail containing:

* Original submission data.
* Application source.
* Matching rule used.
* Created Lead or Opportunity.
* Processing errors.

This is especially useful for support and troubleshooting. Even if processing fails, the original application remains available for investigation.

---

## Account Matching

The matching strategy follows the specification:

1. Tax ID.
2. Company Name as a fallback.

All queries use bind variables because the REST endpoint can be publicly accessible. This prevents potential SOQL injection issues.

The matching strategy is also stored in `MatchedBy__c`, making it easy to understand why an application resulted in an Opportunity or Lead.

The current Company Name matching is exact. Fuzzy matching was intentionally left out because false positives are more dangerous than missed matches. A future implementation could introduce normalized names and similarity scoring based on real customer data.

If multiple Accounts share the same Tax ID, the current implementation uses the first match. This could be improved by flagging the application for manual review.

---

## Security

The service uses `without sharing` because the process can run as an Experience Cloud Guest User, who does not have visibility into Account records.

Without this approach, Account matching would always return no results and every application would become a Lead.

The elevated access is intentionally limited to the operations required by the intake process.

The response does not expose the matched Account Id. This prevents callers from using the endpoint to infer which companies exist in the Salesforce org.

The Guest User should only have access to:

* Required Apex classes.
* Create and Read access to `Application__c`.
* Field-level access limited to the required submission fields.

No direct Guest User access should be granted to Account, Lead, or Opportunity.

---

## Error Handling

The `Application__c` record is intentionally not rolled back when processing fails.

This ensures the original submission and error information remain available for troubleshooting.

The processing result can currently be identified through:

* `Lead__c` populated → Lead created.
* `Opportunity__c` populated → Opportunity created.
* `ErrorMessage__c` populated → Processing failed.

A dedicated Status field could be added in the future to simplify reporting and monitoring.

The REST API also validates the request body size and handles:

* Invalid JSON → HTTP 400.
* Invalid request data → HTTP 400.
* Unexpected errors → HTTP 500 with a generic message.

---

## Key Trade-offs

### Synchronous Processing

The REST request currently performs the complete matching and record creation process before returning.

A future improvement would be to create the `Application__c` record first and process the remaining steps asynchronously with Queueable Apex. This would improve response times and make partner retries safer.

### Matching Strategy

The current matching logic is implemented directly in the service.

If additional matching strategies are required, an `IAccountMatcher` interface could be introduced to make the matching process more extensible.

### Validation

Validation currently stops at the first error. Returning all validation errors at once would provide a better experience for external partners.

### Lead Assignment Rules

Apex inserts do not automatically execute Lead Assignment Rules. If required, `Database.DMLOptions` should be used to explicitly enable them.

---

## Deployment and Setup

Deploy the metadata with:

```bash
sf project deploy start --manifest manifest/package.xml --target-org <alias>
```

The deployment includes the Apex classes, LWC, `Application__c`, related fields, Global Value Set, and `Application__c` layout.

The following configuration must be completed separately:

1. Enable Digital Experiences.
2. Create and publish an Experience Cloud LWR site.
3. Configure Guest User access through a Permission Set.
4. Add the LWC to the Experience Builder page.
5. Add the required fields to Account, Lead, and Opportunity layouts.

The REST endpoint will be available at:

```text
https://<domain>.my.site.com/services/apexrest/intake/applications
```

The REST resource can be tested through an authenticated Salesforce session, and the LWC can be tested on a Lightning App Page before the Experience Cloud site is configured.

---

## Testing

Run the tests with:

```bash
sf apex run test --tests ApplicationIntakeServiceTest --code-coverage --result-format human --wait 10
```

The test suite covers:

* Tax ID Account matching.
* Company Name fallback matching.
* No match resulting in a Lead.
* Invalid requests.
* `snake_case` webhook payloads.
* Malformed JSON returning HTTP 400.

Tests do not use `SeeAllData=true`; all test data is created within the test class.

---

## Example Request

```bash
curl -X POST "https://<domain>.my.site.com/services/apexrest/intake/applications" \
  -H "Content-Type: application/json" \
  -d '{
        "company_name": "Acme Corporation",
        "email": "partner@acme.com",
        "phone": "11999999999",
        "first_name": "Joao",
        "last_name": "Silva",
        "tax_id": "12.345.678/0001-99",
        "annual_revenue": 500000
      }'
```

The parser normalizes field names, so variations such as `companyName`, `company_name`, and `Company Name` are handled consistently. Tax IDs are also normalized to digits before matching.

## Example Response

```json
{
  "success": true,
  "applicationId": "a01...",
  "recordId": "006...",
  "recordType": "Opportunity",
  "message": "Application processed."
}
```
