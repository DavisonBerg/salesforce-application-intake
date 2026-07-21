public class ApplicationIntakeRequest {
    @AuraEnabled public String  companyName      { get; set; }
    @AuraEnabled public String  email            { get; set; }
    @AuraEnabled public String  phone            { get; set; }
    @AuraEnabled public String  contactFirstName { get; set; }
    @AuraEnabled public String  contactLastName  { get; set; }
    @AuraEnabled public String  federalTaxId     { get; set; }
    @AuraEnabled public Decimal annualRevenue    { get; set; }
    @AuraEnabled public String  rawPayload       { get; set; }
    public String source;
}