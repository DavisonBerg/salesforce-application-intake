import { LightningElement, track } from 'lwc';
import submitApplication from '@salesforce/apex/ApplicationIntakeController.submitApplication';

const FIELDS = [
    'companyName',
    'email',
    'phone',
    'contactFirstName',
    'contactLastName'
];

export default class ApplicationIntakeForm extends LightningElement {
    @track form = {};
    isLoading = false;
    isSubmitted = false;
    errorMessage = '';
    result;

    handleChange(event) {
        this.form[event.target.dataset.field] = event.target.value;
    }

    handleSubmit() {
        this.errorMessage = '';

        // Native required validation. Server-side validation still runs —
        // this only spares the user a round trip.
        const inputs = [...this.template.querySelectorAll('lightning-input')];
        const valid = inputs.reduce((acc, input) => input.reportValidity() && acc, true);
        if (!valid) {
            return;
        }

        this.isLoading = true;

        submitApplication({ request: this.buildRequest() })
            .then((result) => {
                this.result = result;
                this.isSubmitted = true;
            })
            .catch((error) => {
                this.errorMessage =
                    error?.body?.message || 'Unexpected error. Please try again.';
            })
            .finally(() => {
                this.isLoading = false;
            });
    }

    buildRequest() {
        const request = {};
        FIELDS.forEach((field) => {
            request[field] = this.form[field];
        });
        request.federalTaxId = this.form.federalTaxId || null;
        request.annualRevenue = this.form.annualRevenue
            ? parseFloat(this.form.annualRevenue)
            : null;
        return request;
    }
}
