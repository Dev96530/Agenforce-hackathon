import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import FORM_FACTOR from '@salesforce/client/formFactor';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import getHomeData from '@salesforce/apex/RepHomeHubService.getHomeData';
import completeTask from '@salesforce/apex/RepHomeHubService.completeTask';
import rescheduleTask from '@salesforce/apex/RepHomeHubService.rescheduleTask';
import linkExpenseToVisit from '@salesforce/apex/RepHomeHubService.linkExpenseToVisit';

export default class RepHomeHub extends NavigationMixin(LightningElement) {
    wiredResult;
    data;
    error;
    busy = false;

    @wire(getHomeData)
    wiredHomeData(value) {
        this.wiredResult = value;
        const { data, error } = value;
        if (data) {
            this.data = data;
            this.error = undefined;
        } else if (error) {
            this.error = error?.body?.message || 'Failed to load dashboard data.';
            this.data = undefined;
        }
    }

    get isMobile() {
        return FORM_FACTOR === 'Small';
    }

    get hasData() {
        return !!this.data;
    }

    get kpi() {
        return this.data?.kpi || {};
    }

    get tasks() {
        return this.data?.tasks || {};
    }

    get visits() {
        return this.data?.visits || [];
    }

    get expenses() {
        return this.data?.expenses || {};
    }

    get alerts() {
        return this.data?.alerts || [];
    }

    get briefing() {
        return this.data?.briefing || {};
    }

    get totalExpensesWeekLabel() {
        return this.formatCurrency(this.expenses.weekTotal || 0);
    }

    get overdueCount() {
        return this.tasks?.overdue?.length || 0;
    }

    get todayCount() {
        return this.tasks?.today?.length || 0;
    }

    get upcomingCount() {
        return this.tasks?.upcoming?.length || 0;
    }

    get showEmptyTasks() {
        return this.overdueCount + this.todayCount + this.upcomingCount === 0;
    }

    get hasAlerts() {
        return this.alerts.length > 0;
    }

    formatCurrency(value) {
        return new Intl.NumberFormat('en-IN', {
            style: 'currency',
            currency: 'USD',
            maximumFractionDigits: 0
        }).format(Number(value || 0));
    }

    async refreshData() {
        if (!this.wiredResult) return;
        await refreshApex(this.wiredResult);
    }

    async handleCompleteTask(event) {
        const taskId = event.currentTarget.dataset.id;
        if (!taskId) return;
        this.busy = true;
        try {
            const result = await completeTask({ taskId });
            this.toast(result.success ? 'Success' : 'Error', result.message, result.success ? 'success' : 'error');
            if (result.success) await this.refreshData();
        } finally {
            this.busy = false;
        }
    }

    async handleRescheduleTomorrow(event) {
        const taskId = event.currentTarget.dataset.id;
        if (!taskId) return;
        const tomorrow = new Date();
        tomorrow.setDate(tomorrow.getDate() + 1);
        const yyyy = tomorrow.getFullYear();
        const mm = String(tomorrow.getMonth() + 1).padStart(2, '0');
        const dd = String(tomorrow.getDate()).padStart(2, '0');
        const newDate = `${yyyy}-${mm}-${dd}`;

        this.busy = true;
        try {
            const result = await rescheduleTask({ taskId, newDate });
            this.toast(result.success ? 'Success' : 'Error', result.message, result.success ? 'success' : 'error');
            if (result.success) await this.refreshData();
        } finally {
            this.busy = false;
        }
    }

    async handleLinkToLatestVisit(event) {
        const expenseId = event.currentTarget.dataset.id;
        const latestVisitId = this.visits?.[0]?.visitId;
        if (!expenseId || !latestVisitId) {
            this.toast('Error', 'Need an expense and at least one visit to link.', 'error');
            return;
        }
        this.busy = true;
        try {
            const result = await linkExpenseToVisit({ expenseId, visitId: latestVisitId });
            this.toast(result.success ? 'Success' : 'Error', result.message, result.success ? 'success' : 'error');
            if (result.success) await this.refreshData();
        } finally {
            this.busy = false;
        }
    }

    handleOpenRecord(event) {
        const recordId = event.currentTarget.dataset.id;
        const objectApiName = event.currentTarget.dataset.object;
        if (!recordId) return;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId,
                objectApiName,
                actionName: 'view'
            }
        });
    }

    handleAlertAction(event) {
        const action = event.currentTarget.dataset.action;
        const targetId = event.currentTarget.dataset.id;
        if (!action || !targetId) return;
        if (action === 'completeTask') {
            this.handleCompleteTask(event);
            return;
        }
        if (action === 'openVisit') {
            this.navigateToRecord(targetId, 'Visit');
            return;
        }
        if (action === 'openExpense') {
            this.navigateToRecord(targetId, 'Expense');
            return;
        }
        if (action === 'openContact') {
            this.navigateToRecord(targetId, 'Contact');
        }
    }

    navigateToRecord(recordId, objectApiName) {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId, objectApiName, actionName: 'view' }
        });
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}