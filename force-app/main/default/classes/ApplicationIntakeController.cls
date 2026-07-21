/**
 * Thin adapter between the public LWC form and the intake service.
 *
 * Its only responsibilities are stamping the source (never trusted from the
 * client) and translating domain exceptions into AuraHandledException so the
 * component receives a usable message instead of a raw stack trace.
 */
public without sharing class ApplicationIntakeController {

    @AuraEnabled
    public static ApplicationIntakeService.Result submitApplication(ApplicationIntakeRequest request) {
        try {
            request.source = ApplicationIntakeConstants.SOURCE_COMMUNITY;
            return ApplicationIntakeService.submit(request);

        } catch (ApplicationIntakeException e) {
            throw new AuraHandledException(e.getMessage());

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Intake form failure: ' + e);
            throw new AuraHandledException('Unexpected error processing the application.');
        }
    }
}
