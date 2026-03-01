import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import DButton from "discourse/components/d-button";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import KeyValueStore from "discourse/lib/key-value-store";
import { i18n } from "discourse-i18n";

const store = new KeyValueStore("discourse_insights_");
import AddReportModal from "./add-report-modal";
import InsightsExploreSection from "./insights-explore-section";
import InsightsReportChart from "./insights-report-chart";

export default class InsightsReportsSection extends Component {
  @service modal;
  @service router;

  @tracked reports = null;
  @tracked loading = true;
  @tracked expanded = !!store.getObject("reports_expanded");

  _draggedReport = null;

  constructor() {
    super(...arguments);
    this.loadReports();
  }

  get hasReports() {
    return !this.loading && this.reports?.length > 0;
  }

  async loadReports() {
    try {
      const result = await ajax("/insights/reports.json");
      this.reports = result.reports;
    } catch {
      this.reports = [];
    } finally {
      this.loading = false;
    }
  }

  @action
  toggle() {
    this.expanded = !this.expanded;
    store.setObject({ key: "reports_expanded", value: this.expanded });
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
    this.loading = true;
    await this.loadReports();
  }

  @action
  async removeReport(reportId) {
    try {
      await ajax(`/insights/reports/${reportId}.json`, { type: "DELETE" });
      this.reports = this.reports.filter((r) => r.id !== reportId);
    } catch (e) {
      popupAjaxError(e);
    }
  }

  @action
  setDraggedReport(report) {
    this._draggedReport = report;
  }

  @action
  openEditor() {
    this.router.transitionTo("insights.reports");
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

    ajax("/insights/reports/reorder.json", {
      type: "PUT",
      data: { report_ids: list.map((r) => r.id) },
    }).catch(popupAjaxError);
  }

  <template>
    {{#if this.hasReports}}
      <InsightsExploreSection
        @expanded={{this.expanded}}
        @summary={{i18n "discourse_insights.reports.summary"}}
        @onToggle={{this.toggle}}
        @bodyClass="insights-explore__body--reports"
      >
        <:title>
          {{i18n "discourse_insights.reports.title"}}
          {{#if this.expanded}}
            <DButton
              class="btn-transparent btn-small insights-reports-editor-link"
              @action={{this.openEditor}}
              @icon="pen-to-square"
              @label="discourse_insights.editor.open_editor"
            />
          {{/if}}
        </:title>
        <:body>
          {{#each this.reports as |report|}}
            <InsightsReportChart
              @report={{report}}
              @startDate={{@startDate}}
              @endDate={{@endDate}}
              @initialParams={{report.params}}
              @onRemove={{this.removeReport}}
              @onDragStart={{this.setDraggedReport}}
              @onReorder={{this.reorderReport}}
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
        </:body>
      </InsightsExploreSection>
    {{/if}}
  </template>
}
