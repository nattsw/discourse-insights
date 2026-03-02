import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import DButton from "discourse/components/d-button";
import icon from "discourse/helpers/d-icon";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import getURL from "discourse/lib/get-url";
import discourseLater from "discourse/lib/later";
import { not } from "discourse/truth-helpers";
import { i18n } from "discourse-i18n";
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

export default class InsightsSharedReportPage extends Component {
  @service router;
  @service dialog;

  @tracked title;
  @tracked reports = [];
  @tracked saving = false;
  @tracked dirty = false;
  @tracked linkCopied = false;

  _savedState = null;

  constructor() {
    super(...arguments);
    const model = this.args.model;
    this.title = model.title || "";
    this.reports = (model.reports || []).map((r) => ({
      ...r,
      params: { ...(r.params || {}) },
    }));
    this._savedState = this._serializeState();
  }

  get isOwner() {
    return this.args.model.is_owner;
  }

  get shareUrl() {
    return getURL(`/insights/reports/${this.args.model.key}`);
  }

  get fullShareUrl() {
    return `${window.location.origin}${this.shareUrl}`;
  }

  get startDate() {
    return periodToDates("30d").start;
  }

  get endDate() {
    return periodToDates("30d").end;
  }

  _serializeState() {
    return JSON.stringify({
      title: this.title,
      reports: this.reports.map((r) => ({ id: r.id, params: r.params })),
    });
  }

  _checkDirty() {
    this.dirty = this._serializeState() !== this._savedState;
  }

  @action
  updateTitle(event) {
    this.title = event.target.value;
    this._checkDirty();
  }

  @action
  onParamsChange(reportId, params) {
    const report = this.reports.find((r) => r.id === reportId);
    if (report) {
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
  async save() {
    this.saving = true;
    try {
      await ajax(`/insights/shared-reports/${this.args.model.key}.json`, {
        type: "PUT",
        contentType: "application/json",
        data: JSON.stringify({
          title: this.title,
          reports: this.reports.map((r) => ({
            query_id: r.id,
            params: r.params || {},
          })),
        }),
      });
      this._savedState = this._serializeState();
      this.dirty = false;
    } catch (e) {
      popupAjaxError(e);
    } finally {
      this.saving = false;
    }
  }

  @action
  confirmDelete() {
    this.dialog.yesNoConfirm({
      message: i18n("discourse_insights.shared_report.delete_confirm"),
      didConfirm: () => this._delete(),
    });
  }

  async _delete() {
    try {
      await ajax(`/insights/shared-reports/${this.args.model.key}.json`, {
        type: "DELETE",
      });
      this.router.transitionTo("insights.reports");
    } catch (e) {
      popupAjaxError(e);
    }
  }

  @action
  async copyLink() {
    try {
      await navigator.clipboard.writeText(this.fullShareUrl);
      this.linkCopied = true;
      discourseLater(() => (this.linkCopied = false), 2000);
    } catch {
      // clipboard not available
    }
  }

  @action
  print() {
    window.print();
  }

  @action
  goBack() {
    this.router.transitionTo("insights.reports");
  }

  <template>
    <div class="insights insights-shared-report">
      <div class="insights-shared-report__header">
        <div class="insights-shared-report__title-row">
          <DButton
            class="btn-transparent btn-small"
            @action={{this.goBack}}
            @icon="chevron-left"
          />
          {{#if this.isOwner}}
            <input
              type="text"
              value={{this.title}}
              placeholder={{i18n "discourse_insights.shared_report.edit_title"}}
              class="insights-shared-report__title-input"
              {{on "input" this.updateTitle}}
            />
          {{else}}
            <h2 class="insights-shared-report__title">{{if
                this.title
                this.title
                (i18n "discourse_insights.shared_report.untitled")
              }}</h2>
            <span class="insights-shared-report__meta">{{i18n
                "discourse_insights.shared_report.by"
                username=@model.owner.username
              }}</span>
          {{/if}}
          {{#if this.dirty}}
            <span
              class="insights-shared-report__unsaved"
            >{{i18n "discourse_insights.shared_report.unsaved"}}</span>
          {{/if}}
        </div>
        <div class="insights-shared-report__actions">
          <DButton
            class="btn-default"
            @action={{this.print}}
            @icon="print"
            @title="discourse_insights.shared_report.print"
          />
          {{#if this.isOwner}}
            <DButton
              class="btn-primary"
              @action={{this.save}}
              @icon="floppy-disk"
              @label={{if
                this.saving
                "discourse_insights.shared_report.saving"
                "discourse_insights.shared_report.save"
              }}
              @disabled={{this.saving}}
            />
            <DButton
              class="btn-danger"
              @action={{this.confirmDelete}}
              @icon="trash-can"
              @label="discourse_insights.shared_report.delete"
            />
          {{/if}}
        </div>
      </div>

      <div class="insights-shared-report__share-url">
        <span class="insights-shared-report__share-url-label">{{icon
            "link"
          }}</span>
        <input
          type="text"
          readonly="true"
          value={{this.fullShareUrl}}
          class="insights-shared-report__share-url-input"
        />
        <DButton
          class="btn-default btn-small"
          @action={{this.copyLink}}
          @icon={{if this.linkCopied "check" "copy"}}
          @label={{if
            this.linkCopied
            "discourse_insights.shared_report.link_copied"
            "discourse_insights.shared_report.copy_link"
          }}
        />
      </div>

      {{#if this.reports.length}}
        <div class="insights-shared-report__grid">
          {{#each this.reports as |report|}}
            <InsightsReportChart
              @report={{report}}
              @startDate={{this.startDate}}
              @endDate={{this.endDate}}
              @initialParams={{report.params}}
              @readonly={{not this.isOwner}}
              @onRemove={{if this.isOwner this.removeReport}}
              @onParamsChange={{if this.isOwner this.onParamsChange}}
            />
          {{/each}}
        </div>
      {{else}}
        <div class="insights-shared-report__empty">
          {{i18n "discourse_insights.shared_report.no_accessible_charts"}}
        </div>
      {{/if}}
    </div>
  </template>
}
