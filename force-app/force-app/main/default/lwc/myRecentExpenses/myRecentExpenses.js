import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import FORM_FACTOR from '@salesforce/client/formFactor';
import getRecentExpenses from '@salesforce/apex/MyExpensesController.getRecentExpenses';
import getWeekTotal from '@salesforce/apex/MyExpensesController.getWeekTotal';

export default class MyRecentExpenses extends NavigationMixin(LightningElement) {
    rows;
    rowsError;
    summary;
    summaryError;

    @wire(getRecentExpenses, { limitCount: 5 })
    wiredRows({ data, error }) {
        if (data) {
            const fmt = new Intl.NumberFormat('en-IN');
            this.rows = data.map((r) => ({
                ...r,
                amountLabel: fmt.format(r.amount),
                dateLabel: r.transactionDate,
                physicianLabel: r.physicianFullName || '—'
            }));
            this.rowsError = undefined;
        } else if (error) {
            this.rowsError = error.body ? error.body.message : 'Error loading expenses';
            this.rows = undefined;
        }
    }

    @wire(getWeekTotal)
    wiredSummary({ data, error }) {
        if (data) {
            const fmt = new Intl.NumberFormat('en-IN');
            this.summary = {
                weekLabel: fmt.format(data.weekTotal),
                weekCount: data.weekCount,
                monthLabel: fmt.format(data.monthTotal),
                monthCount: data.monthCount
            };
            this.summaryError = undefined;
        } else if (error) {
            this.summaryError = error.body ? error.body.message : 'Error loading summary';
        }
    }

    get isMobile() {
        return FORM_FACTOR === 'Small';
    }

    get hasRows() {
        return this.rows && this.rows.length > 0;
    }

    handleRowClick(event) {
        const expenseId = event.currentTarget.dataset.id;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: expenseId,
                objectApiName: 'Expense',
                actionName: 'view'
            }
        });
    }
}
