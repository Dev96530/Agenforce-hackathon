import { LightningElement, api } from 'lwc';

export default class ClinicalBriefingCard extends LightningElement {
    @api value;

    get physicianName() { return this.value?.physicianName ?? ''; }
    get hasPhysicianName() { return !!this.value?.physicianName; }
    get department() { return this.value?.department ?? ''; }
    get hasDepartment() { return !!this.value?.department; }
    get briefingText() { return this.value?.briefingText ?? ''; }
}
