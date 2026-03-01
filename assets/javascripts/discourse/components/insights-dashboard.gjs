import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import willDestroy from "@ember/render-modifiers/modifiers/will-destroy";
import { cancel, later } from "@ember/runloop";
import { service } from "@ember/service";
import { htmlSafe } from "@ember/template";
import DTooltip from "discourse/float-kit/components/d-tooltip";
import number from "discourse/helpers/number";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { bind } from "discourse/lib/decorators";
import getURL from "discourse/lib/get-url";
import { i18n } from "discourse-i18n";
import AddReportModal from "./add-report-modal";
import InsightsDateRangeModal from "./insights-date-range-modal";
import InsightsExploreSection from "./insights-explore-section";
import InsightsGeoMap from "./insights-geo-map";
import InsightsHeader from "./insights-header";
import InsightsLiveSection from "./insights-live-section";
import InsightsReportChart from "./insights-report-chart";
import InsightsSummary from "./insights-summary";

const AI_TIMEOUT_MS = 30000;
const LIVE_POLL_INTERVAL_MS = 30000;

function formatTrendText(pct) {
  if (pct > 0) {
    return `↑ ${pct}%`;
  }
  if (pct < 0) {
    return `↓ ${Math.abs(pct)}%`;
  }
  return "— flat";
}

function trendCssClass(pct) {
  if (pct > 2) {
    return "insights-trend--up";
  }
  if (pct < -2) {
    return "insights-trend--down";
  }
  return "insights-trend--flat";
}

export default class InsightsDashboard extends Component {
  @service modal;
  @service messageBus;

  @tracked period = "30d";
  @tracked customStartDate = null;
  @tracked customEndDate = null;
  @tracked data = null;
  @tracked loading = false;
  @tracked expandedSections = {};
  @tracked reports = null;
  @tracked reportsLoading = true;

  // ai state
  @tracked aiSummary = "";
  @tracked aiSummaryLoading = false;
  @tracked aiSummaryDone = false;
  @tracked aiAnswer = "";
  @tracked aiAnswerLoading = false;
  @tracked aiAnswerDone = false;
  @tracked aiAnswerType = null;
  @tracked aiSummaryError = false;
  @tracked aiAnswerError = false;
  @tracked customQuestion = "";
  @tracked liveData = null;
  @tracked liveLoading = false;
  _aiSummaryTimer = null;
  _aiAnswerTimer = null;
  _aiCache = new Map();
  _livePollTimer = null;

  constructor() {
    super(...arguments);
    this.data = this.args.initialData;

    const ctrl = this.args.controller;
    if (ctrl?.start_date && ctrl?.end_date) {
      this.period = "custom";
      this.customStartDate = moment(ctrl.start_date);
      this.customEndDate = moment(ctrl.end_date);
    } else if (ctrl?.period) {
      this.period = ctrl.period;
    }

    this.loadReports();
  }

  get aiAvailable() {
    return !!this.data?.ai_available;
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

  get topTopicsForDisplay() {
    return (this.data?.top_topics ?? []).map((topic) => ({
      ...topic,
      url: getURL(`/t/-/${topic.topic_id}`),
    }));
  }

  get geoBreakdown() {
    return this.data?.geo_breakdown ?? [];
  }

  get categoriesForDisplay() {
    return (this.data?.categories ?? []).map((cat) => ({
      ...cat,
      dotStyle: htmlSafe(`background-color: #${cat.color}`),
      trendText: formatTrendText(cat.trend_pct),
      trendClass: trendCssClass(cat.trend_pct),
    }));
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

  get isReportsExpanded() {
    return !!this.expandedSections.reports;
  }

  get isLiveExpanded() {
    return !!this.expandedSections.live;
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
    this._resetAiState();
    this._syncQueryParams({ period: periodId });
    try {
      this.data = await ajax("/insights/health.json", {
        data: { period: periodId },
      });
      this.triggerAiSummary();
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
    this._resetAiState();
    const sd = moment(startDate).format("YYYY-MM-DD");
    const ed = moment(endDate).format("YYYY-MM-DD");
    this._syncQueryParams({ start_date: sd, end_date: ed });
    try {
      this.data = await ajax("/insights/health.json", {
        data: { start_date: sd, end_date: ed },
      });
      this.triggerAiSummary();
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
    const willExpand = !this.expandedSections[key];
    this.expandedSections = {
      ...this.expandedSections,
      [key]: willExpand,
    };
    if (key === "live") {
      if (willExpand) {
        this.fetchLiveData();
      } else {
        this.stopLivePolling();
      }
    }
  }

  // live view

  async fetchLiveData() {
    this.liveLoading = !this.liveData;
    try {
      this.liveData = await ajax("/insights/live.json");
    } catch {
      // live view is best-effort
    } finally {
      this.liveLoading = false;
    }
    if (this.isLiveExpanded) {
      this._livePollTimer = later(
        this,
        this.fetchLiveData,
        LIVE_POLL_INTERVAL_MS
      );
    }
  }

  stopLivePolling() {
    cancel(this._livePollTimer);
    this._livePollTimer = null;
  }

  // ai

  @bind
  subscribeAi() {
    this.messageBus.subscribe("/insights/ai/stream", this._onAiStream);
    this.triggerAiSummary();
  }

  @bind
  unsubscribeAi() {
    this.messageBus.unsubscribe("/insights/ai/stream", this._onAiStream);
    cancel(this._aiSummaryTimer);
    cancel(this._aiAnswerTimer);
    this.stopLivePolling();
  }

  @bind
  _onAiStream(update) {
    const periodKey = this._periodCacheKey();
    if (update.type === "summary") {
      this.aiSummary = update.text;
      this.aiSummaryLoading = false;
      if (update.done) {
        this.aiSummaryDone = true;
        cancel(this._aiSummaryTimer);
        this._aiCache.set(`summary_${periodKey}`, update.text);
      }
    } else {
      if (update.type !== this.aiAnswerType) {
        return;
      }
      this.aiAnswer = update.text;
      this.aiAnswerLoading = false;
      if (update.done) {
        this.aiAnswerDone = true;
        cancel(this._aiAnswerTimer);
        if (update.type !== "custom") {
          this._aiCache.set(`${update.type}_${periodKey}`, update.text);
        }
      }
    }
  }

  triggerAiSummary() {
    if (!this.aiAvailable) {
      return;
    }

    const cached = this._aiCache.get(`summary_${this._periodCacheKey()}`);
    if (cached) {
      this.aiSummary = cached;
      this.aiSummaryDone = true;
      this.aiSummaryLoading = false;
      return;
    }

    this.aiSummary = "";
    this.aiSummaryLoading = true;
    this.aiSummaryDone = false;
    this.aiSummaryError = false;

    this._aiSummaryTimer = later(
      this,
      () => {
        if (!this.aiSummaryDone && this.aiSummary.length === 0) {
          this.aiSummaryLoading = false;
          this.aiSummaryError = true;
        }
      },
      AI_TIMEOUT_MS
    );

    ajax("/insights/ai/generate.json", {
      type: "POST",
      data: { type: "summary", ...this._currentPeriodParams() },
    })
      .then((result) => {
        if (result.text) {
          this.aiSummary = result.text;
          this.aiSummaryLoading = false;
          this.aiSummaryDone = true;
          cancel(this._aiSummaryTimer);
          this._aiCache.set(`summary_${this._periodCacheKey()}`, result.text);
        }
      })
      .catch(() => {
        this.aiSummaryLoading = false;
      });
  }

  triggerAiAnswer(type, question) {
    if (!this.aiAvailable) {
      return;
    }

    if (type !== "custom") {
      const cached = this._aiCache.get(`${type}_${this._periodCacheKey()}`);
      if (cached) {
        this.aiAnswer = cached;
        this.aiAnswerDone = true;
        this.aiAnswerLoading = false;
        this.aiAnswerType = type;
        return;
      }
    }

    this.aiAnswer = "";
    this.aiAnswerLoading = true;
    this.aiAnswerDone = false;
    this.aiAnswerError = false;
    this.aiAnswerType = type;

    this._aiAnswerTimer = later(
      this,
      () => {
        if (!this.aiAnswerDone && this.aiAnswer.length === 0) {
          this.aiAnswerLoading = false;
          this.aiAnswerError = true;
        }
      },
      AI_TIMEOUT_MS
    );

    const data = { type, ...this._currentPeriodParams() };
    if (type === "custom") {
      data.question = question;
    }

    ajax("/insights/ai/generate.json", {
      type: "POST",
      data,
    })
      .then((result) => {
        if (result.text) {
          this.aiAnswer = result.text;
          this.aiAnswerLoading = false;
          this.aiAnswerDone = true;
          this.aiAnswerType = type;
          cancel(this._aiAnswerTimer);
          if (type !== "custom") {
            this._aiCache.set(`${type}_${this._periodCacheKey()}`, result.text);
          }
        }
      })
      .catch(() => {
        this.aiAnswerLoading = false;
      });
  }

  @action
  onToggleQuestion(key) {
    if (this.aiAvailable) {
      this.triggerAiAnswer(key);
    }
  }

  @action
  onSubmitCustomQuestion(question) {
    this.triggerAiAnswer("custom", question);
  }

  @action
  updateCustomQuestion(event) {
    this.customQuestion = event.target.value;
  }

  // reports

  async loadReports() {
    try {
      const result = await ajax("/insights/reports.json");
      this.reports = result.reports;
    } catch {
      this.reports = [];
    } finally {
      this.reportsLoading = false;
    }
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
    this.reportsLoading = true;
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

  // helpers

  _resetAiState() {
    this.aiSummary = "";
    this.aiSummaryDone = false;
    this.aiSummaryError = false;
    this.aiAnswer = "";
    this.aiAnswerDone = false;
    this.aiAnswerError = false;
  }

  _syncQueryParams({ period, start_date, end_date } = {}) {
    const ctrl = this.args.controller;
    if (!ctrl) {
      return;
    }
    ctrl.set("period", period || null);
    ctrl.set("start_date", start_date || null);
    ctrl.set("end_date", end_date || null);
  }

  _periodCacheKey() {
    if (this.isCustomPeriod && this.customStartDate && this.customEndDate) {
      return `${moment(this.customStartDate).format("YYYY-MM-DD")}_${moment(this.customEndDate).format("YYYY-MM-DD")}`;
    }
    return this.period;
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
    <div
      class="insights"
      {{didInsert this.subscribeAi}}
      {{willDestroy this.unsubscribeAi}}
    >
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
      {{else}}
        <InsightsSummary
          @data={{this.data}}
          @aiAvailable={{this.aiAvailable}}
          @aiSummary={{this.aiSummary}}
          @aiSummaryLoading={{this.aiSummaryLoading}}
          @aiSummaryError={{this.aiSummaryError}}
          @aiAnswer={{this.aiAnswer}}
          @aiAnswerLoading={{this.aiAnswerLoading}}
          @aiAnswerError={{this.aiAnswerError}}
          @customQuestion={{this.customQuestion}}
          @onCustomQuestionInput={{this.updateCustomQuestion}}
          @onToggleQuestion={{this.onToggleQuestion}}
          @onSubmitCustomQuestion={{this.onSubmitCustomQuestion}}
        />

        {{! Live View }}
        <InsightsExploreSection
          @class="insights-live"
          @expanded={{this.isLiveExpanded}}
          @summary={{i18n "discourse_insights.live.summary"}}
          @onToggle={{fn this.toggleExplore "live"}}
          @bodyClass="insights-live__body"
        >
          <:title>
            <span class="insights-live__pulse"></span>
            {{i18n "discourse_insights.live.title"}}
          </:title>
          <:body>
            <InsightsLiveSection
              @liveData={{this.liveData}}
              @loading={{this.liveLoading}}
            />
          </:body>
        </InsightsExploreSection>

        {{! My Reports }}
        {{#unless this.reportsLoading}}
          {{#if this.reports.length}}
            <InsightsExploreSection
              @expanded={{this.isReportsExpanded}}
              @summary={{i18n "discourse_insights.reports.summary"}}
              @onToggle={{fn this.toggleExplore "reports"}}
              @bodyClass="insights-explore__body--reports"
            >
              <:title>
                {{i18n "discourse_insights.reports.title"}}
                <DTooltip
                  class="insights-reports-info"
                  @icon="circle-info"
                  @content={{i18n
                    "discourse_insights.reports.personal_hint"
                  }}
                />
              </:title>
              <:body>
                {{#each this.reports as |report|}}
                  <InsightsReportChart
                    @report={{report}}
                    @startDate={{this.data.period.start_date}}
                    @endDate={{this.data.period.end_date}}
                    @onRemove={{this.removeReport}}
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
        {{/unless}}

        {{! Explore: Content Performance }}
        <InsightsExploreSection
          @expanded={{this.isContentExpanded}}
          @summary={{i18n "discourse_insights.explore.content_summary"}}
          @onToggle={{fn this.toggleExplore "content"}}
          @bodyClass="insights-explore__body--grid-2"
        >
          <:title>{{i18n "discourse_insights.explore.content"}}</:title>
          <:body>
            <div class="insights-card">
              <div class="insights-card__title">{{i18n
                  "discourse_insights.explore.top_topics"
                }}</div>
              <table class="insights-rank-table">
                <tbody>
                  {{#each this.topTopicsForDisplay as |topic|}}
                    <tr>
                      <td class="insights-rank-table__name">
                        <a
                          href={{topic.url}}
                          class="insights-topic-link"
                        >{{topic.title}}</a>
                      </td>
                      <td class="insights-rank-table__value">{{number
                          topic.views
                        }}</td>
                    </tr>
                  {{/each}}
                </tbody>
              </table>
            </div>
            <div class="insights-card">
              <div class="insights-card__title">{{i18n
                  "discourse_insights.explore.search_terms"
                }}</div>
              <table class="insights-rank-table">
                <tbody>
                  {{#each this.data.search_terms as |term|}}
                    <tr>
                      <td class="insights-rank-table__name">
                        {{term.term}}
                        {{#if term.content_gap}}
                          <span
                            class="insights-badge insights-badge--gap"
                          >{{i18n
                              "discourse_insights.explore.content_gap_badge"
                            }}</span>
                        {{/if}}
                      </td>
                      <td
                        class="insights-rank-table__value"
                      >{{term.count}}</td>
                      <td class="insights-rank-table__meta">{{i18n
                          "discourse_insights.explore.ctr"
                          value=term.ctr
                        }}</td>
                    </tr>
                  {{/each}}
                </tbody>
              </table>
            </div>
          </:body>
        </InsightsExploreSection>

        {{! Explore: Traffic Sources }}
        <InsightsExploreSection
          @expanded={{this.isTrafficExpanded}}
          @summary={{i18n "discourse_insights.explore.traffic_summary"}}
          @onToggle={{fn this.toggleExplore "traffic"}}
        >
          <:title>{{i18n "discourse_insights.explore.traffic"}}</:title>
          <:body>
            {{#if this.geoBreakdown.length}}
              <div class="insights-card insights-card--full">
                <div class="insights-card__title">{{i18n
                    "discourse_insights.explore.geography"
                  }}</div>
                <InsightsGeoMap @data={{this.geoBreakdown}} />
              </div>
              <div class="insights-geo-upsell">
                <div class="insights-geo-upsell__text">
                  <span class="insights-geo-upsell__title">{{i18n
                      "discourse_insights.explore.geo_upsell_title"
                    }}</span>
                  <span class="insights-geo-upsell__desc">{{i18n
                      "discourse_insights.explore.geo_upsell_desc"
                    }}</span>
                </div>
                <a
                  href="https://discourse.org/enterprise"
                  target="_blank"
                  rel="noopener noreferrer"
                  class="btn btn-primary insights-geo-upsell__cta"
                >{{i18n "discourse_insights.explore.geo_upsell_cta"}}</a>
              </div>
            {{/if}}
            <div
              class="insights-explore__grid
                {{if this.geoBreakdown.length 'insights-explore__grid--2'}}"
            >
              <div class="insights-card">
                <div class="insights-card__title">{{i18n
                    "discourse_insights.explore.referrers"
                  }}</div>
                <table class="insights-rank-table">
                  <tbody>
                    {{#each this.data.traffic_sources as |source|}}
                      <tr>
                        <td
                          class="insights-rank-table__name"
                        >{{source.domain}}</td>
                        <td class="insights-rank-table__value">{{number
                            source.clicks
                          }}</td>
                      </tr>
                    {{/each}}
                  </tbody>
                </table>
              </div>
              {{#if this.geoBreakdown.length}}
                <div class="insights-card">
                  <div class="insights-card__title">{{i18n
                      "discourse_insights.explore.top_countries"
                    }}</div>
                  <table class="insights-rank-table">
                    <tbody>
                      {{#each this.geoBreakdown as |geo|}}
                        <tr>
                          <td class="insights-rank-table__name">
                            {{geo.country}}
                          </td>
                          <td class="insights-rank-table__value">{{number
                              geo.count
                            }}</td>
                          <td
                            class="insights-rank-table__meta"
                          >{{geo.pct}}%</td>
                        </tr>
                      {{/each}}
                    </tbody>
                  </table>
                </div>
              {{/if}}
            </div>
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
            <div class="insights-card">
              <table class="insights-cat-table">
                <thead>
                  <tr>
                    <th>{{i18n "discourse_insights.explore.category"}}</th>
                    <th>{{i18n "discourse_insights.explore.page_views"}}</th>
                    <th>{{i18n "discourse_insights.explore.new_topics"}}</th>
                    <th>{{i18n "discourse_insights.explore.replies"}}</th>
                    <th>{{i18n "discourse_insights.explore.trend"}}</th>
                  </tr>
                </thead>
                <tbody>
                  {{#each this.categoriesForDisplay as |cat|}}
                    <tr>
                      <td>
                        <span
                          class="insights-cat-dot"
                          style={{cat.dotStyle}}
                        ></span>
                        {{cat.name}}
                      </td>
                      <td>{{number cat.page_views}}</td>
                      <td>{{cat.new_topics}}</td>
                      <td>{{cat.replies}}</td>
                      <td>
                        <span
                          class={{cat.trendClass}}
                        >{{cat.trendText}}</span>
                      </td>
                    </tr>
                  {{/each}}
                </tbody>
              </table>
            </div>
          </:body>
        </InsightsExploreSection>
      {{/if}}
    </div>
  </template>
}
