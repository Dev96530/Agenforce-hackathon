import { LightningElement, api } from 'lwc';

export default class ClinicalBriefingCard1 extends LightningElement {
    @api value;

    // ---------- Header ----------
    get physicianName() { return this.value?.physicianName ?? ''; }
    get hasPhysicianName() { return !!this.value?.physicianName; }
    get department() { return this.value?.department ?? ''; }
    get hasDepartment() { return !!this.value?.department; }

    // ---------- Parse status ----------
    get parseSucceeded() { return !!this.value?.parseSucceeded; }
    get talkingPointTitles() {
        return Array.isArray(this.value?.talkingPointTitles) ? this.value.talkingPointTitles : [];
    }
    get talkingPointBodies() {
        return Array.isArray(this.value?.talkingPointBodies) ? this.value.talkingPointBodies : [];
    }
    get hasTalkingPoints() { return this.talkingPointTitles.length > 0; }

    // ---------- Decorated talking points ----------
    get decoratedPoints() {
        const titles = this.talkingPointTitles;
        const bodies = this.talkingPointBodies;
        const palette = [
            'cb1-accent-blue',
            'cb1-accent-purple',
            'cb1-accent-teal',
            'cb1-accent-orange',
            'cb1-accent-pink'
        ];
        return titles.map((title, idx) => ({
            key: `tp-${idx}`,
            position: idx + 1,
            title: title ?? '',
            body: bodies[idx] ?? '',
            accentClass: `cb1-point-card ${palette[idx % palette.length]}`
        }));
    }

    // ---------- Intro / closing ----------
    get hasIntroLine() { return !!this.value?.introLine; }
    get introLine() { return this.value?.introLine ?? ''; }
    get hasClosingQuestion() { return !!this.value?.closingQuestion; }
    get closingQuestion() { return this.value?.closingQuestion ?? ''; }

    // ---------- Count label ----------
    get countLabel() {
        const n = this.talkingPointTitles.length;
        const words = ['One', 'Two', 'Three', 'Four', 'Five', 'Six'];
        return n >= 1 && n <= words.length ? words[n - 1] : String(n);
    }

    // ---------- Fallback ----------
    get hasBriefingText() { return !!this.value?.briefingText; }
    get briefingText() { return this.value?.briefingText ?? ''; }
    get showFullTextFallback() {
        return !this.hasTalkingPoints && this.hasBriefingText;
    }
}
