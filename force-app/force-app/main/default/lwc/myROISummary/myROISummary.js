import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getRepROISummary from '@salesforce/apex/ReferralROIService.getRepROISummary';
import USER_ID from '@salesforce/user/Id';

const USD_COMPACT = new Intl.NumberFormat('en-US', {
    notation: 'compact',
    maximumFractionDigits: 1
});

function formatUSD(val) {
    const n = Number(val || 0);
    return '$' + USD_COMPACT.format(n);
}

export default class MyRoiSummary extends NavigationMixin(LightningElement) {
    rawData;
    errorMessage;

    @wire(getRepROISummary, { userId: USER_ID })
    wiredROI({ data, error }) {
        if (data) {
            this.rawData = data;
            this.errorMessage = undefined;
        } else if (error) {
            this.rawData = undefined;
            this.errorMessage = error?.body?.message || error?.message || 'Unknown error';
        }
    }

    get summary() {
        return this.rawData || {
            quarter: '',
            totalAttributedRevenue: 0,
            totalArrivedPatients: 0,
            totalContributingPhysicians: 0,
            topByROI: [],
            needsAttention: [],
            topPhysiciansCompanyWide: []
        };
    }

    get formattedTotalRevenue() {
        return formatUSD(this.summary.totalAttributedRevenue);
    }

    get topRows() {
        return (this.summary.topByROI || []).map(r => ({
            ...r,
            formattedRevenue: formatUSD(r.attributedRevenue)
        }));
    }

    get attentionRows() {
        return this.summary.needsAttention || [];
    }

    get companyTopRows() {
        return (this.summary.topPhysiciansCompanyWide || []).map(r => ({
            ...r,
            formattedRevenue: formatUSD(r.attributedRevenue)
        }));
    }

    get showContent() {
        return this.rawData && !this.hasError;
    }

    get hasTopByROI() {
        return this.topRows.length > 0;
    }

    get hasNeedsAttention() {
        return this.attentionRows.length > 0;
    }

    get hasCompanyTop() {
        return this.companyTopRows.length > 0;
    }

    get isEmpty() {
        return this.rawData && !this.hasTopByROI && !this.hasNeedsAttention && !this.hasCompanyTop && !this.hasError;
    }

    get hasError() {
        return !!this.errorMessage;
    }

    navigateToPhysician(event) {
        const contactId = event.currentTarget.dataset.id;
        if (!contactId) return;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: contactId,
                objectApiName: 'Contact',
                actionName: 'view'
            }
        });
    }
}
