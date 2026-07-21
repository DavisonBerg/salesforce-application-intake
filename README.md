# Salesforce DX Project: Next Steps

Now that you’ve created a Salesforce DX project, what’s next? Here are some documentation resources to get you started.

## How Do You Plan to Deploy Your Changes?

Do you want to deploy a set of changes, or create a self-contained application? Choose a [development model](https://developer.salesforce.com/tools/vscode/en/user-guide/development-models).

## Configure Your Salesforce DX Project

The `sfdx-project.json` file contains useful configuration information for your project. See [Salesforce DX Project Configuration](https://developer.salesforce.com/docs/atlas.en-us.sfdx_dev.meta/sfdx_dev/sfdx_dev_ws_config.htm) in the _Salesforce DX Developer Guide_ for details about this file.

## Read All About It

- [Salesforce Extensions Documentation](https://developer.salesforce.com/tools/vscode/)
- [Salesforce CLI Setup Guide](https://developer.salesforce.com/docs/atlas.en-us.sfdx_setup.meta/sfdx_setup/sfdx_setup_intro.htm)
- [Salesforce DX Developer Guide](https://developer.salesforce.com/docs/atlas.en-us.sfdx_dev.meta/sfdx_dev/sfdx_dev_intro.htm)
- [Salesforce CLI Command Reference](https://developer.salesforce.com/docs/atlas.en-us.sfdx_cli_reference.meta/sfdx_cli_reference/cli_reference.htm)


# Salesforce Application Intake

Partner applications come in from two places — a public form on an Experience
Cloud site, and a webhook for external systems. Either way the system tries to
find an existing Account. If it finds one, you get an Opportunity. If it
doesn't, you get a Lead.

## How it's put together

```
LWC form  ──► ApplicationIntakeController ──┐
                                            ├──► ApplicationIntakeService ──► Application__c
REST POST ──► ApplicationIntakeRestResource ┘                              └─► Lead | Opportunity
```

The two entry points don't do much: they turn whatever they received into a DTO,
stamp where it came from, and call the service. Everything interesting happens
in `ApplicationIntakeService`. The main payoff is that the tests for the actual
business rules don't have to go anywhere near HTTP or Aura.

The rest of the classes are small. `ApplicationIntakeParser` deals with the
messy JSON, `ApplicationIntakeValidator` checks the required fields,
`ApplicationIntakeRequest` is a plain DTO, and `ApplicationIntakeException`
exists so the REST layer can tell "you sent me garbage" apart from "I broke".

## The Application__c object

This is the piece I'd defend hardest. Every submission gets written to a staging
record before anything else happens.

Without it, a submission that blows up halfway leaves nothing behind. Someone
emails support saying they submitted an application yesterday and you have no
way to check. With it, you've got the raw payload, which matching rule fired,
what got created, and the error if there was one.

The brief mentions support requests, and this is the thing that actually answers
that.

## Matching

Tax ID first, company name as a fallback. Straight out of the spec.

Both queries use bind variables — this is reachable anonymously from a public
endpoint, so building the query with string concatenation would be a SOQL
injection hole.

`findAccount` sets `Matched_By__c` as a side effect, which isn't the prettiest
design, but it means you can look at any Application record and immediately see
why it became a Lead instead of an Opportunity. Worth the slightly impure method
in my opinion.

## Why the service is `without sharing`

The guest user can't see any Account at all. So if the service ran `with
sharing`, the matching query would come back empty every single time and
everything would become a Lead. And it would pass all your tests, because you
run those as an admin.

So it's `without sharing`, but kept narrow — one query and one insert. The
`Result` object deliberately doesn't include the Account Id it matched on.
Otherwise someone could sit there submitting tax IDs and use the response to
work out which companies are in your org.

## Failures

No `Savepoint` anywhere in the processing block. That's on purpose — rolling
back would delete the staging record, which is the exact thing you want to keep
when something goes wrong. The error message goes on the record and the
transaction commits.

I didn't add a status field. You can tell what happened from whether
`Created_Lead__c` / `Created_Opportunity__c` is populated, or whether
`Error_Message__c` has something in it. A proper status picklist would be nicer
in a list view and would be the first thing I'd add.

## Some smaller calls

`StageName` and `CloseDate` on the Opportunity are only there because the
platform demands them. The opportunity lifecycle isn't part of this, so the
values don't mean anything.

I left `Amount` empty. Annual revenue is a fact about the company, not the size
of the deal, and putting it in `Amount` would drop a wrong number into a field
sales people actually rely on. It's still on the Application record, and on the
Lead where `AnnualRevenue` genuinely means the same thing.

The webhook assumes people will send it rubbish. Body size gets capped before
anything is deserialized — parsing an unbounded payload is the easiest way to
DoS a public endpoint. Bad JSON gets a 400. Anything unexpected gets a 500 with
a generic message; the caller never sees an exception or a field name.

## Tradeoffs

**Validation stops at the first error.** So a partner with three problems finds
out about them one at a time. Collecting all the errors and returning them
together would be better and isn't hard, it just wasn't where I wanted to spend
the time.

**Matching is a private method rather than a plugin.** An `IAccountMatcher`
interface with one class per rule is honestly the right shape for something
described as "expected to evolve", and pulling it out later is mechanical. I ran
out of runway. It's the first thing I'd reintroduce.

**Everything is synchronous.** The webhook does the whole match-and-create before
it responds. Writing the staging record and handing off to a Queueable would be
better — the endpoint would stay fast and partner retries would be less
dangerous. Since the staging record is written first regardless, that change is
fairly contained.

**Extra JSON keys are ignored** rather than rejected. Nested payloads aren't
supported; the parser wants a flat object.

**Only the Application__c layout is deployed.** Pushing a layout over someone's
Account page on install felt too invasive. The new fields have to be added
manually, which is called out below.

**Lead assignment rules won't fire** — Apex inserts skip them unless you set
`DmlOptions`. Whether they should run is really the customer's call.

## The thing I deliberately didn't build

Fuzzy matching on company name.

Right now the fallback is an exact match, which in practice will miss most of
what it should catch. Real submissions will have "Acme Corp", "Acme
Corporation", and "ACME CORP., INC." all meaning the same account.

I left it out on purpose rather than because I ran out of time. Getting it right
means normalizing legal suffixes and scoring similarity, and you can't tune that
without looking at a specific customer's Account data. The failure modes aren't
symmetric either: miss a match and you create a duplicate Lead that someone
merges later, no real harm. Match wrongly and you've attached an Opportunity to
the wrong customer's account, which is hard to spot and much harder to explain.
Shipping a guessed heuristic into someone's CRM didn't seem like the right call.

Related, and part of the same job: if several Accounts share a Tax ID, this
currently just takes the first one. It should really create a Lead flagged for
someone to look at.

## Setup

Worth being upfront: I built and tested this against a Developer Edition org,
but I stopped at the Apex and the LWC. The Experience Cloud site, the guest user
permissions and the page layout changes were not done. They're configuration
rather than code, and with the time I had I'd rather hand over working, tested
logic than a half-wired site.

Everything below is what someone would need to do to actually expose it.

### What deploys

```bash
sf project deploy start --manifest manifest/package.xml --target-org <alias>
```

That's the Apex, the LWC bundle, `Application__c` with its fields, the fields
added to Account / Lead / Opportunity, and the global value set.

### What still needs doing

**1. Enable Digital Experiences.** Setup → Digital Experiences → Settings, pick
a domain. Org setting, doesn't travel in metadata, can't be undone.

**2. Create and publish a site.** All Sites → New, Build Your Own (LWR). Publish
it once even if empty — this is also what creates the guest user.

**3. Guest user access.** I'd put this in a permission set rather than editing
the Guest User Profile directly: the guest profile is generated by the org with
a name derived from the site, so it doesn't version well, whereas a permission
set ships in the repo. Either way it needs Apex Class access to
`ApplicationIntakeController` and `ApplicationIntakeRestResource`, plus Create
and Read on `Application__c` with field access limited to the submission fields.

Read has to be on — the platform won't grant Create without it. With the object
on a Private sharing model that's harmless in practice.

Nothing on Account, Lead or Opportunity. Those are created by the service in
elevated context, and a guest user with Create on Opportunity on a public site
would be a genuine hole.

**4. Put the component on a page.** Switch the LWC targets from
`lightning__AppPage` to `lightningCommunity__Page` and
`lightningCommunity__Default`, redeploy, then drag `applicationIntakeForm` into
Experience Builder and publish.

**5. Layouts.** Add `Federal_Tax_ID__c` to Account and `Application_Source__c` to
Lead and Opportunity. I only ship the `Application__c` layout — pushing a layout
over a customer's Account page on install felt more invasive than asking for two
minutes of clicking.

Once the site is up the webhook is at:

```
https://<domain>.my.site.com/services/apexrest/intake/applications
```

Until then both paths are still testable. The REST resource works through an
authenticated session (Workbench, or `sf api request rest`), and the LWC can be
dropped on a Lightning App Page, which is what the metadata currently targets —
that's how I verified both.

## Tests

```bash
sf apex run test --tests ApplicationIntakeServiceTest --code-coverage --result-format human --wait 10
```

Six scenarios: Tax ID match producing an Opportunity, company name fallback
producing an Opportunity, no match producing a Lead, an invalid request being
rejected before anything is written, the webhook handling a snake_case payload,
and the webhook rejecting malformed JSON with a 400.

Two bits of the setup are doing real work. In the Tax ID test the Account is
given a deliberately different name — if both matched, the test would still pass
with the Tax ID rule completely broken, because the fallback would quietly save
it. And in the fallback test neither side has a Tax ID at all, so the first rule
short-circuits and only the second one can produce the match.

Nothing uses `SeeAllData=true`, so the org's real Accounts are invisible in there
and every match comes from data the test class creates itself.

## Example request

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

Keys are lowercased with separators stripped before lookup, so `companyName`,
`company_name` and `Company Name` all land in the same place. The tax ID is
reduced to digits before matching.

```json
{
  "success": true,
  "applicationId": "a01...",
  "recordId": "006...",
  "recordType": "Opportunity",
  "message": "Application processed."
}
```