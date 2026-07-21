/**
 * Public webhook endpoint for external systems.
 *
 * Exposed anonymously through the Experience Cloud site
 *
 * Site URL: https://<domain>.my.site.com/services/apexrest/intake/applications
 */
@RestResource(urlMapping='/intake/applications/*')
global without sharing class ApplicationIntakeRestResource {

    global class ApiResponse {
        public Boolean success;
        public Id      applicationId;
        public Id      recordId;
        public String  recordType;
        public String  message;
    }

    @HttpPost
    global static void doPost() {

        RestRequest  req = RestContext.request;
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');

        ApiResponse out = new ApiResponse();

        try {
            String body = req.requestBody == null ? null : req.requestBody.toString();

            if (String.isBlank(body)) {
                throw new ApplicationIntakeException('Request body is required.');
            }
            if (body.length() > ApplicationIntakeConstants.MAX_PAYLOAD_BYTES) {
                throw new ApplicationIntakeException('Payload exceeds maximum allowed size.');
            }

            Map<String, Object> payload;
            try {
                payload = (Map<String, Object>) JSON.deserializeUntyped(body);
            } catch (Exception parseError) {
                throw new ApplicationIntakeException('Malformed JSON payload.');
            }

            ApplicationIntakeRequest intake = ApplicationIntakeParser.parse(payload);
            intake.source     = ApplicationIntakeConstants.SOURCE_WEBHOOK;
            intake.rawPayload = body;

            ApplicationIntakeService.Result result = ApplicationIntakeService.submit(intake);

            out.success       = result.success;
            out.applicationId = result.applicationId;
            out.recordId      = result.recordId;
            out.recordType    = result.recordType;
            out.message       = result.success
                ? 'Application processed.'
                : result.errorMessage;

            res.statusCode = result.success ? 201 : 500;

        } catch (ApplicationIntakeException e) {
            // Caller's fault: bad or missing data. Safe to echo the message.
            out.success = false;
            out.message = e.getMessage();
            res.statusCode = 400;

        } catch (Exception e) {
            // Our fault. Log server-side, return something generic.
            System.debug(LoggingLevel.ERROR, 'Intake webhook failure: ' + e);
            out.success = false;
            out.message = 'Unexpected error processing the application.';
            res.statusCode = 500;
        }

        res.responseBody = Blob.valueOf(JSON.serialize(out));
    }
}