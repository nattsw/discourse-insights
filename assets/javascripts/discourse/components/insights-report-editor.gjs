import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import DButton from "discourse/components/d-button";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { i18n } from "discourse-i18n";
import AddReportModal from "./add-report-modal";
import InsightsReportChart from "./insights-report-chart";

function periodToDates(period) {
  const end = moment().format("YYYY-MM-DD");
  let start;
  switch (period) {
    case "7d":
      start = moment().subtract(7, "days").format("YYYY-MM-DD");
      break;
    case "3m":
      start = moment().subtract(3, "months").format("YYYY-MM-DD");
      break;
    default:
      start = moment().subtract(30, "days").format("YYYY-MM-DD");
  }
  return { start, end };
}

export default class InsightsReportEditor extends Component {
  @service modal;
  @service router;

  @tracked reports = [];
  @tracked saving = false;
  @tracked dirty = false;

  _savedState = null;
  _draggedReport = null;

  constructor() {
    super(...arguments);
    const initial = this.args.model?.reports || [];
    this.reports = initial.map((r) => ({ ...r, params: { ...(r.params || {}) } }));
    this._savedState = JSON.stringify(this.reports.map((r) => ({ id: r.id, params: r.params })));
  }

  get startDate() {
    if (this.args.model?.start_date) {
      return this.args.model.start_date;
    }
    return periodToDates(this.args.model?.period).start;
  }

  get endDate() {
    if (this.args.model?.end_date) {
      return this.args.model.end_date;
    }
    return periodToDates(this.args.model?.period).end;
  }

  _checkDirty() {
    const current = JSON.stringify(this.reports.map((r) => ({ id: r.id, params: r.params })));
    this.dirty = current !== this._savedState;
  }

  @action
  onParamsChange(reportId, params) {
    const report = this.reports.find((r) => r.id === reportId);
    if (report) {
      // strip date params
      const filtered = {};
      for (const [k, v] of Object.entries(params)) {
        if (!k.match(/date/)) {
          filtered[k] = v;
        }
      }
      report.params = filtered;
      this.reports = [...this.reports];
      this._checkDirty();
    }
  }

  @action
  removeReport(reportId) {
    this.reports = this.reports.filter((r) => r.id !== reportId);
    this._checkDirty();
  }

  @action
  openAddReport() {
    this.modal.show(AddReportModal, {
      model: {
        onAdd: this.onReportAdded,
      },
    });
  }

  @action
  async onReportAdded() {
    try {
      const result = await ajax("/insights/reports.json");
      const newReports = result.reports;
      // find reports that are in the new list but not current
      const currentIds = new Set(this.reports.map((r) => r.id));
      for (const r of newReports) {
        if (!currentIds.has(r.id)) {
          this.reports = [...this.reports, { ...r, params: r.params || {} }];
        }
      }
      this._checkDirty();
    } catch (e) {
      popupAjaxError(e);
    }
  }

  @action
  setDraggedReport(report) {
    this._draggedReport = report;
  }

  @action
  reorderReport(targetReport, above) {
    if (!this._draggedReport || this._draggedReport === targetReport) {
      return;
    }

    const list = [...this.reports];
    const fromIdx = list.findIndex((r) => r.id === this._draggedReport.id);
    if (fromIdx === -1) {
      return;
    }
    list.splice(fromIdx, 1);
    const toIdx = list.findIndex((r) => r.id === targetReport.id);
    list.splice(above ? toIdx : toIdx + 1, 0, this._draggedReport);
    this.reports = list;
    this._checkDirty();
  }

  @action
  async save() {
    this.saving = true;
    try {
      await ajax("/insights/reports/save.json", {
        type: "PUT",
        contentType: "application/json",
        data: JSON.stringify({
          reports: this.reports.map((r) => ({
            query_id: r.id,
            params: r.params || {},
          })),
        }),
      });
      this._savedState = JSON.stringify(this.reports.map((r) => ({ id: r.id, params: r.params })));
      this.dirty = false;
    } catch (e) {
      popupAjaxError(e);
    } finally {
      this.saving = false;
    }
  }

  @action
  goBack() {
    this.router.transitionTo("insights");
  }

  <template>
    <div class="insights insights-report-editor">
      <div class="insights-report-editor__header">
        <div class="insights-report-editor__title-row">
          <DButton
            class="btn-transparent btn-small"
            @action={{this.goBack}}
            @icon="chevron-left"
          />
          <h2 class="insights-report-editor__title">{{i18n
              "discourse_insights.editor.title"
            }}</h2>
          {{#if this.dirty}}
            <span
              class="insights-report-editor__unsaved"
            >{{i18n "discourse_insights.editor.unsaved"}}</span>
          {{/if}}
        </div>
        <div class="insights-report-editor__actions">
          <DButton
            class="btn-primary"
            @action={{this.save}}
            @icon="floppy-disk"
            @label={{if
              this.saving
              "discourse_insights.editor.saving"
              "discourse_insights.editor.save"
            }}
            @disabled={{this.saving}}
          />
        </div>
      </div>

      <div class="insights-report-editor__grid">
        {{#each this.reports as |report|}}
          <InsightsReportChart
            @report={{report}}
            @startDate={{this.startDate}}
            @endDate={{this.endDate}}
            @initialParams={{report.params}}
            @onRemove={{this.removeReport}}
            @onDragStart={{this.setDraggedReport}}
            @onReorder={{this.reorderReport}}
            @onParamsChange={{this.onParamsChange}}
          />
        {{/each}}
        <button
          type="button"
          class="insights-add-report-btn"
          {{on "click" this.openAddReport}}
        >
          +
          {{i18n "discourse_insights.reports.add_report"}}
        </button>
      </div>
    </div>
  </template>
}
