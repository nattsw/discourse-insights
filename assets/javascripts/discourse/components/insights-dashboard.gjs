import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { action } from "@ember/object";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { bind } from "discourse/lib/decorators";
import KeyValueStore from "discourse/lib/key-value-store";
import { i18n } from "discourse-i18n";

const STORE_NAMESPACE = "discourse_insights_";
const store = new KeyValueStore(STORE_NAMESPACE);
import InsightsCategoriesSection from "./insights-categories-section";
import InsightsContentSection from "./insights-content-section";
import InsightsDateRangeModal from "./insights-date-range-modal";
import InsightsExploreSection from "./insights-explore-section";
import InsightsFeedback from "./insights-feedback";
import InsightsHeader from "./insights-header";
import InsightsLiveSection from "./insights-live-section";
import InsightsReportsSection from "./insights-reports-section";
import InsightsSummary from "./insights-summary";
import InsightsTrafficSection from "./insights-traffic-section";

export default class InsightsDashboard extends Component {
  @service modal;

  @tracked period = "30d";
  @tracked customStartDate = null;
  @tracked customEndDate = null;
  @tracked data = null;
  @tracked loading = true;
  @tracked expandedSections = store.getObject("expanded") || {};

  constructor() {
    super(...arguments);

    const p = this.args.routeParams;
    if (p?.start_date && p?.end_date) {
      this.period = "custom";
      this.customStartDate = moment(p.start_date);
      this.customEndDate = moment(p.end_date);
    } else if (p?.period) {
      this.period = p.period;
    }
  }

  get isCustomPeriod() {
    return this.period === "custom";
  }

  get customDateLabel() {
    if (!this.data?.period) {
      return "";
    }
    const start = moment(this.data.period.start_date);
    const end = moment(this.data.period.end_date);
    return `${start.format("MMM D")}–${end.format("MMM D, YYYY")}`;
  }

  get isContentExpanded() {
    return !!this.expandedSections.content;
  }

  get isTrafficExpanded() {
    return !!this.expandedSections.traffic;
  }

  get isCategoriesExpanded() {
    return !!this.expandedSections.categories;
  }

  @bind
  async fetchInitialData() {
    this.loading = true;
    try {
      this.data = await ajax("/insights/health.json", {
        data: this._currentPeriodParams(),
      });
    } catch {
      this.data = { error: true };
    } finally {
      this.loading = false;
    }
  }

  // period actions

  @action
  async changePeriod(periodId) {
    if (this.period === periodId && !this.isCustomPeriod) {
      return;
    }
    this.period = periodId;
    this.customStartDate = null;
    this.customEndDate = null;
    this.loading = true;
    this._syncQueryParams({ period: periodId });
    try {
      this.data = await ajax("/insights/health.json", {
        data: { period: periodId },
      });
    } catch (e) {
      popupAjaxError(e);
    } finally {
      this.loading = false;
    }
  }

  @action
  openCustomDateRange() {
    this.modal.show(InsightsDateRangeModal, {
      model: {
        startDate: this.customStartDate || moment().subtract(30, "days"),
        endDate: this.customEndDate || moment(),
        setCustomDateRange: this.setCustomDateRange,
      },
    });
  }

  @action
  async setCustomDateRange(startDate, endDate) {
    this.period = "custom";
    this.customStartDate = startDate;
    this.customEndDate = endDate;
    this.loading = true;
    const sd = moment(startDate).format("YYYY-MM-DD");
    const ed = moment(endDate).format("YYYY-MM-DD");
    this._syncQueryParams({ start_date: sd, end_date: ed });
    try {
      this.data = await ajax("/insights/health.json", {
        data: { start_date: sd, end_date: ed },
      });
    } catch (e) {
      popupAjaxError(e);
    } finally {
      this.loading = false;
    }
  }

  @action
  async refresh() {
    this.loading = true;
    try {
      const data = { force: true };
      if (this.isCustomPeriod && this.customStartDate && this.customEndDate) {
        data.start_date = moment(this.customStartDate).format("YYYY-MM-DD");
        data.end_date = moment(this.customEndDate).format("YYYY-MM-DD");
      } else {
        data.period = this.period;
      }
      this.data = await ajax("/insights/health.json", { data });
    } catch (e) {
      popupAjaxError(e);
    } finally {
      this.loading = false;
    }
  }

  // explore toggle

  @action
  toggleExplore(key) {
    this.expandedSections = {
      ...this.expandedSections,
      [key]: !this.expandedSections[key],
    };
    store.setObject({ key: "expanded", value: this.expandedSections });
  }

  // helpers

  _syncQueryParams({ period, start_date, end_date } = {}) {
    const ctrl = this.args.controller;
    if (!ctrl) {
      return;
    }
    ctrl.set("period", period || null);
    ctrl.set("start_date", start_date || null);
    ctrl.set("end_date", end_date || null);
  }

  _currentPeriodParams() {
    if (this.isCustomPeriod && this.customStartDate && this.customEndDate) {
      return {
        start_date: moment(this.customStartDate).format("YYYY-MM-DD"),
        end_date: moment(this.customEndDate).format("YYYY-MM-DD"),
      };
    }
    return { period: this.period };
  }

  <template>
    <div class="insights" {{didInsert this.fetchInitialData}}>
      <InsightsHeader
        @period={{this.period}}
        @isCustomPeriod={{this.isCustomPeriod}}
        @customDateLabel={{this.customDateLabel}}
        @loading={{this.loading}}
        @onChangePeriod={{this.changePeriod}}
        @onOpenCustomDateRange={{this.openCustomDateRange}}
        @onRefresh={{this.refresh}}
      />

      {{#if this.loading}}
        <div class="insights-loading">
          <div class="spinner medium"></div>
        </div>
      {{else if this.data.error}}
        <div class="insights-error">
          {{i18n "discourse_insights.error"}}
        </div>
      {{else if this.data}}
        <InsightsSummary @data={{this.data}} />

        {{! Live View }}
        <InsightsLiveSection />

        {{! My Reports }}
        <InsightsReportsSection
          @startDate={{this.data.period.start_date}}
          @endDate={{this.data.period.end_date}}
        />

        {{! Explore: Traffic Sources }}
        <InsightsExploreSection
          @expanded={{this.isTrafficExpanded}}
          @summary={{i18n "discourse_insights.explore.traffic_summary"}}
          @onToggle={{fn this.toggleExplore "traffic"}}
        >
          <:title>{{i18n "discourse_insights.explore.traffic"}}</:title>
          <:body>
            <InsightsTrafficSection @data={{this.data}} />
          </:body>
        </InsightsExploreSection>

        {{! Explore: Content Performance }}
        <InsightsExploreSection
          @expanded={{this.isContentExpanded}}
          @summary={{i18n "discourse_insights.explore.content_summary"}}
          @onToggle={{fn this.toggleExplore "content"}}
          @bodyClass="insights-explore__body--grid-2"
        >
          <:title>{{i18n "discourse_insights.explore.content"}}</:title>
          <:body>
            <InsightsContentSection @data={{this.data}} />
          </:body>
        </InsightsExploreSection>

        {{! Explore: Categories }}
        <InsightsExploreSection
          @expanded={{this.isCategoriesExpanded}}
          @summary={{i18n "discourse_insights.explore.categories_summary"}}
          @onToggle={{fn this.toggleExplore "categories"}}
        >
          <:title>{{i18n "discourse_insights.explore.categories"}}</:title>
          <:body>
            <InsightsCategoriesSection @data={{this.data}} />
          </:body>
        </InsightsExploreSection>

        <InsightsFeedback />
      {{/if}}
    </div>
  </template>
}
