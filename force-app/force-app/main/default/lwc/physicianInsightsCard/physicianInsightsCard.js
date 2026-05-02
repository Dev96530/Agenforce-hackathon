import { LightningElement, api } from 'lwc';

export default class PhysicianInsightsCard extends LightningElement {
    @api value;

    // ---------- Existing primitive getters (preserved) ----------
    get physicianFullName() { return this.value?.physicianFullName ?? ''; }
    get hasDepartment() { return !!(this.value?.department); }
    get department() { return this.value?.department ?? ''; }
    get hasSpecialty() { return !!(this.value?.specialty); }
    get specialty() { return this.value?.specialty ?? ''; }
    get hasPracticesAt() { return !!(this.value?.practicesAt); }
    get practicesAt() { return this.value?.practicesAt ?? ''; }
    get departmentLine() {
        const parts = [];
        if (this.hasDepartment) parts.push(this.department);
        if (this.hasSpecialty) parts.push(this.specialty);
        return parts.join(' · ');
    }
    get showSubtitle() { return this.hasDepartment || this.hasSpecialty; }

    get physicianFound() { return !!this.value?.physicianFound; }

    get showVisitCountTile() {
        const v = this.value?.visitCountThisYear;
        return v !== null && v !== undefined && v > 0;
    }
    get visitCountThisYear() { return this.value?.visitCountThisYear ?? 0; }

    get showOpenTaskTile() {
        const v = this.value?.openTaskCount;
        return v !== null && v !== undefined && v > 0;
    }
    get openTaskCount() { return this.value?.openTaskCount ?? 0; }

    get showDaysSinceTile() {
        const v = this.value?.daysSinceLastVisit;
        return v !== null && v !== undefined;
    }
    get daysSinceLastVisit() { return this.value?.daysSinceLastVisit ?? 0; }
    get daysSinceLabel() {
        const d = this.value?.daysSinceLastVisit;
        if (d === null || d === undefined) return '';
        if (d === 0) return 'today';
        if (d === 1) return 'yesterday';
        return `${d} days ago`;
    }

    get showRoiTile() {
        const v = this.value?.roiAttributedRevenue;
        return v !== null && v !== undefined && v > 0;
    }
    get roiFormatted() {
        const v = this.value?.roiAttributedRevenue;
        if (!v) return '—';
        if (v >= 1_000_000) return `$${(v / 1_000_000).toFixed(1)}M`;
        return `$${Math.round(v / 1000)}K`;
    }

    get hasAnyKpi() {
        return this.showVisitCountTile || this.showOpenTaskTile
            || this.showDaysSinceTile || this.showRoiTile;
    }

    // ---------- Sentiment (existing) ----------
    get hasSentimentTrend() {
        const t = this.value?.sentimentTrend;
        if (!Array.isArray(t) || t.length === 0) return false;
        return t.some(s => s && s !== '—');
    }
    get sentimentDots() {
        // Legacy (with lightning-icon) — retained for safety, no longer used by v2 HTML.
        const t = this.value?.sentimentTrend ?? [];
        return t.map((s, idx) => {
            const sentiment = s ?? '—';
            let cssClass = 'pic-dot pic-dot-empty';
            let iconName = 'utility:dash';
            if (sentiment === 'Positive') {
                cssClass = 'pic-dot pic-dot-positive';
                iconName = 'utility:smiley_and_people';
            } else if (sentiment === 'Negative') {
                cssClass = 'pic-dot pic-dot-negative';
                iconName = 'utility:frown';
            } else if (sentiment === 'Neutral') {
                cssClass = 'pic-dot pic-dot-neutral';
                iconName = 'utility:dash';
            }
            return { key: `s-${idx}`, label: sentiment, cssClass, iconName };
        });
    }
    get sentimentLabelLine() {
        const t = this.value?.sentimentTrend ?? [];
        return t.filter(s => s && s !== '—').join(' · ');
    }

    // ---------- Last visit / open task / referrals (existing) ----------
    get showLastVisit() { return !!this.value?.hasRelationshipHistory && !!this.value?.lastVisitSummary; }
    get lastVisitSummary() { return this.value?.lastVisitSummary ?? ''; }

    get showOpenTask() { return !!this.value?.openTaskSummary; }
    get openTaskSummary() { return this.value?.openTaskSummary ?? ''; }

    get showReferralRow() { return !!this.value?.hasReferralHistory; }
    get referralsThisYear() { return this.value?.referralsThisYear ?? 0; }
    get referralsConvertedToAppointments() { return this.value?.referralsConvertedToAppointments ?? 0; }
    get appointmentsArrived() { return this.value?.appointmentsArrived ?? 0; }
    get hasFacilityBreakdown() { return !!(this.value?.facilityBreakdown); }
    get facilityBreakdown() { return this.value?.facilityBreakdown ?? ''; }
    get hasLastReferral() { return !!(this.value?.lastReferralSummary); }
    get lastReferralSummary() { return this.value?.lastReferralSummary ?? ''; }

    get showRoiRow() { return !!(this.value?.roiSummaryLine); }
    get roiSummaryLine() { return this.value?.roiSummaryLine ?? ''; }

    get hasSuggestedNextAction() { return !!(this.value?.suggestedNextAction); }
    get suggestedNextAction() { return this.value?.suggestedNextAction ?? ''; }

    // ============================================================
    //                    v2 redesign getters
    // ============================================================

    // Avatar initials — strip honorific, take first letter of first + last word
    get avatarInitials() {
        const raw = this.value?.physicianFullName ?? '';
        if (!raw) return '';
        const cleaned = raw.replace(/^(Dr\.?|Prof\.?|Mr\.?|Ms\.?|Mrs\.?)\s+/i, '').trim();
        if (!cleaned) return '';
        const parts = cleaned.split(/\s+/).filter(p => p.length > 0);
        if (parts.length === 0) return '';
        if (parts.length === 1) return parts[0].charAt(0).toUpperCase();
        return (parts[0].charAt(0) + parts[parts.length - 1].charAt(0)).toUpperCase();
    }

    // Stale badge — "Stale 54d" when daysSinceLastVisit > 30
    get hasStaleBadge() {
        const d = this.value?.daysSinceLastVisit;
        return Number.isFinite(d) && d > 30;
    }
    get staleBadgeText() {
        const d = this.value?.daysSinceLastVisit ?? 0;
        return `Stale ${d}d`;
    }

    // Header subtitle: "Department · FirstClinic"
    get headerSubtitle() {
        const dept = this.value?.department || '';
        const practices = this.value?.practicesAt || '';
        let firstClinic = '';
        if (practices) {
            const split = practices.split(/\s+(?:—|-)\s+/);
            firstClinic = (split[0] || '').trim();
        }
        if (dept && firstClinic) return `${dept} · ${firstClinic}`;
        return dept || firstClinic;
    }
    get hasSubtitleV2() { return !!this.headerSubtitle; }

    // ROI tile caption "3 arrived"
    get arrivedCountCaption() {
        const c = this.value?.roiArrivedCount;
        return Number.isFinite(c) && c > 0 ? `${c} arrived` : '';
    }
    get hasArrivedCaption() { return !!this.arrivedCountCaption; }

    // Days Since caption "last: Mar 8"
    get lastVisitDateShort() {
        const d = this.value?.daysSinceLastVisit;
        if (!Number.isFinite(d)) return '';
        const dt = new Date();
        dt.setDate(dt.getDate() - d);
        try {
            return dt.toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
        } catch (_) {
            return '';
        }
    }
    get lastVisitCaption() {
        const date = this.lastVisitDateShort;
        return date ? `last: ${date}` : '';
    }
    get hasLastVisitCaption() { return !!this.lastVisitCaption; }

    // Days Since color class — amber when stale
    get daysSinceClass() {
        const d = this.value?.daysSinceLastVisit;
        return Number.isFinite(d) && d > 30 ? 'pic-tile-num pic-tile-stale' : 'pic-tile-num';
    }

    // Last visit section
    get lastVisitDaysLabel() {
        const d = this.value?.daysSinceLastVisit;
        return Number.isFinite(d) ? `Last visit · ${d} days ago` : 'Last visit';
    }
    get lastVisitBody() {
        const summary = this.value?.lastVisitSummary ?? '';
        return summary.replace(/^\d+\s*days?\s*ago\s*[,—-]?\s*/i, '').trim();
    }
    get hasLastVisitBody() { return !!this.lastVisitBody; }

    // Sentiment dots — simplified (no lightning-icon, just a colored circle)
    get sentimentDotsSimple() {
        const t = this.value?.sentimentTrend ?? [];
        return t.map((s, idx) => {
            const sentiment = s ?? '—';
            let cssClass = 'pic-dotV2 pic-dotV2-empty';
            if (sentiment === 'Positive') cssClass = 'pic-dotV2 pic-dotV2-positive';
            else if (sentiment === 'Negative') cssClass = 'pic-dotV2 pic-dotV2-negative';
            else if (sentiment === 'Neutral') cssClass = 'pic-dotV2 pic-dotV2-neutral';
            return { key: `sV2-${idx}`, cssClass };
        });
    }

    // Suggested next step text — "Prepare for a visit with Dr. Mehta — Medical Oncology (Hematology)?"
    get suggestedActionText() {
        const fullName = this.value?.physicianFullName ?? '';
        const dept = this.value?.department ?? '';
        const shortName = this._computeShortName(fullName);
        const formattedDept = this._formatDepartment(dept);
        if (formattedDept) {
            return `Prepare for a visit with ${shortName} — ${formattedDept}?`;
        }
        return `Prepare for a visit with ${shortName}?`;
    }

    _computeShortName(fullName) {
        if (!fullName) return 'this physician';
        const cleaned = fullName.trim();
        const m = cleaned.match(/^(Dr\.|Prof\.)\s+(.+)$/i);
        if (m) {
            const honorific = m[1];
            const rest = m[2].split(/\s+/);
            return `${honorific} ${rest[rest.length - 1]}`;
        }
        return cleaned;
    }

    _formatDepartment(dept) {
        if (!dept) return '';
        const parts = dept.split(/\s+(?:—|-)\s+/);
        if (parts.length === 2) {
            return `${parts[0]} (${parts[1]})`;
        }
        return dept;
    }
}
