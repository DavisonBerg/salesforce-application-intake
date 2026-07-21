/**
 * Validates the intake DTO before anything is written.
 *
 * Fails fast on the first problem. Accumulating every error and returning them
 * together would be a better API experience, and is the natural next step —
 * see README.
 *
 * Validation is not delegated to the platform's field types: a DmlException
 * surfaces too late, with a message we cannot control, on a public endpoint.
 */
public with sharing class ApplicationIntakeValidator {

    private static final String EMAIL_PATTERN =
        '^[a-zA-Z0-9._%+\\-]+@[a-zA-Z0-9.\\-]+\\.[a-zA-Z]{2,}$';

    public static void validate(ApplicationIntakeRequest req) {

        if (req == null) {
            throw new ApplicationIntakeException('Request is required.');
        }

        requireField(req.companyName,      'Company Name');
        requireField(req.email,            'Email');
        requireField(req.phone,            'Phone');
        requireField(req.contactFirstName, 'Contact First Name');
        requireField(req.contactLastName,  'Contact Last Name');

        if (!Pattern.matches(EMAIL_PATTERN, req.email)) {
            throw new ApplicationIntakeException('Email is not a valid address.');
        }

        // Phone format is intentionally unvalidated: international variation is
        // wide enough that any rule would reject legitimate numbers.

        if (req.annualRevenue != null && req.annualRevenue < 0) {
            throw new ApplicationIntakeException('Annual Revenue cannot be negative.');
        }
    }


    private static void requireField(String value, String label) {
        if (String.isBlank(value)) {
            throw new ApplicationIntakeException(label + ' is required.');
        }
    }
}