/**
 * Translates a raw, loosely-shaped JSON payload into the intake DTO.
 *
 * The webhook contract is deliberately permissive: partners send different
 * casing and separators for the same concept. Rather than enumerating every
 * spelling, keys are normalized first (lowercased, separators stripped), which
 * collapses companyName / company_name / "Company Name" / COMPANYNAME into a
 * single lookup and keeps the alias map small.
 *
 * This class only translates. Validation lives in ApplicationIntakeValidator —
 * keeping them apart is what makes both trivially testable.
 */
public with sharing class ApplicationIntakeParser {

    // Field length caps come from the TARGET objects (Lead / Account), not from
    // the staging object, so truncation here prevents STRING_TOO_LONG later.
    private static final Integer LEN_COMPANY    = 255;
    private static final Integer LEN_EMAIL      = 80;
    private static final Integer LEN_PHONE      = 40;
    private static final Integer LEN_FIRST_NAME = 40;
    private static final Integer LEN_LAST_NAME  = 80;
    private static final Integer LEN_TAX_ID     = 20;

    // Normalized incoming key -> canonical DTO property
    private static final Map<String, String> ALIASES = new Map<String, String>{
        'companyname'      => 'companyName',
        'company'          => 'companyName',
        'name'             => 'companyName',
        'email'            => 'email',
        'emailaddress'     => 'email',
        'phone'            => 'phone',
        'phonenumber'      => 'phone',
        'firstname'        => 'contactFirstName',
        'contactfirstname' => 'contactFirstName',
        'lastname'         => 'contactLastName',
        'contactlastname'  => 'contactLastName',
        'taxid'            => 'federalTaxId',
        'federaltaxid'     => 'federalTaxId',
        'ein'              => 'federalTaxId',
        'annualrevenue'    => 'annualRevenue',
        'revenue'          => 'annualRevenue'
    };


    public static ApplicationIntakeRequest parse(Map<String, Object> payload) {

        Map<String, Object> canonical = canonicalize(payload);

        ApplicationIntakeRequest req = new ApplicationIntakeRequest();
        req.companyName      = readString(canonical, 'companyName',      LEN_COMPANY);
        req.email            = readString(canonical, 'email',            LEN_EMAIL);
        req.phone            = readString(canonical, 'phone',            LEN_PHONE);
        req.contactFirstName = readString(canonical, 'contactFirstName', LEN_FIRST_NAME);
        req.contactLastName  = readString(canonical, 'contactLastName',  LEN_LAST_NAME);
        req.federalTaxId     = readString(canonical, 'federalTaxId',     LEN_TAX_ID);
        req.annualRevenue    = readDecimal(canonical, 'annualRevenue');
        return req;
    }


    /**
     * Strips everything but digits. Matching only ever compares normalized
     * values, so the same helper must be used wherever a Tax ID is stored.
     */
    public static String normalizeTaxId(String raw) {
        if (String.isBlank(raw)) {
            return null;
        }
        String digits = raw.replaceAll('[^0-9]', '');
        return String.isBlank(digits) ? null : digits;
    }


    /**
     * Lowercases each incoming key and drops spaces, underscores and hyphens,
     * then resolves it through the alias map. Unknown keys are ignored rather
     * than rejected — a partner sending extra fields is not an error.
     */
    private static Map<String, Object> canonicalize(Map<String, Object> payload) {
        Map<String, Object> result = new Map<String, Object>();
        if (payload == null) {
            return result;
        }
        for (String key : payload.keySet()) {
            String normalized = key.toLowerCase().replaceAll('[ _\\-]', '');
            String canonicalKey = ALIASES.get(normalized);
            if (canonicalKey != null && !result.containsKey(canonicalKey)) {
                result.put(canonicalKey, payload.get(key));
            }
        }
        return result;
    }


    private static String readString(Map<String, Object> source, String key, Integer maxLength) {
        Object value = source.get(key);
        if (value == null) {
            return null;
        }
        String text = String.valueOf(value).trim();
        if (String.isBlank(text)) {
            return null;
        }
        return text.length() > maxLength ? text.substring(0, maxLength) : text;
    }


    /**
     * Accepts both JSON numbers and numeric strings. Unparseable input on an
     * optional field is dropped rather than failing the whole submission.
     */
    private static Decimal readDecimal(Map<String, Object> source, String key) {
        Object value = source.get(key);
        if (value == null) {
            return null;
        }
        try {
            return Decimal.valueOf(String.valueOf(value).trim());
        } catch (Exception e) {
            return null;
        }
    }
}