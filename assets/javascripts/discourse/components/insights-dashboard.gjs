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
import CookText from "discourse/components/cook-text";
import DButton from "discourse/components/d-button";
import { bind } from "discourse/lib/decorators";
import number from "discourse/helpers/number";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import getURL from "discourse/lib/get-url";
import { eq } from "discourse/truth-helpers";
import { i18n } from "discourse-i18n";
import DTooltip from "discourse/float-kit/components/d-tooltip";
import AddReportModal from "./add-report-modal";
import InsightsDateRangeModal from "./insights-date-range-modal";
import InsightsGeoMap from "./insights-geo-map";
import InsightsReportChart from "./insights-report-chart";

const AI_TIMEOUT_MS = 30000;

const METRIC_KEYS = [
  "visitors",
  "page_views",
  "new_members",
  "contributors",
  "posts",
  "likes",
  "solved",
  "response_rate",
];

function formatTrendText(pct, isPercentage) {
  if (isPercentage) {
    if (pct > 0) {
      return `↑ ${pct}pts`;
    }
    if (pct < 0) {
      return `↓ ${Math.abs(pct)}pts`;
    }
    return "— flat";
  }
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
  @tracked expandedMetric = null;
  @tracked expandedQuestion = null;
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
  @tracked customQuestion = "";
  _aiSummaryTimer = null;
  _aiAnswerTimer = null;
  _aiCache = new Map();

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

  get periodOptions() {
    return [
      { id: "7d", label: i18n("discourse_insights.periods.7d") },
      { id: "30d", label: i18n("discourse_insights.periods.30d") },
      { id: "3m", label: i18n("discourse_insights.periods.3m") },
    ];
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

  get comparisonLabel() {
    if (!this.data?.period) {
      return "";
    }
    const start = moment(this.data.period.comparison_start);
    const end = moment(this.data.period.comparison_end);
    return `${start.format("MMM D")}–${end.format("MMM D, YYYY")}`;
  }

  get metrics() {
    if (!this.data?.metrics) {
      return [];
    }
    return METRIC_KEYS.map((key) => {
      const m = this.data.metrics[key];
      if (!m || (key === "solved" && m.available === false)) {
        return null;
      }
      return {
        key,
        label: i18n(`discourse_insights.metrics.${key}`),
        current: m.current,
        isPercentage: !!m.is_percentage,
        trendText: formatTrendText(m.trend_pct, m.is_percentage),
        trendClass: trendCssClass(m.trend_pct),
      };
    }).filter(Boolean);
  }

  get isGrowing() {
    return (this.data?.metrics?.visitors?.trend_pct ?? 0) > 5;
  }

  get isDeclining() {
    return (this.data?.metrics?.visitors?.trend_pct ?? 0) < -5;
  }

  get absVisitorsTrend() {
    return Math.abs(this.data?.metrics?.visitors?.trend_pct ?? 0);
  }

  get membersCount() {
    return this.data?.metrics?.new_members?.current ?? 0;
  }

  get membersTrend() {
    return this.data?.metrics?.new_members?.trend_pct ?? 0;
  }

  get visitorsCount() {
    return this.data?.metrics?.visitors?.current ?? 0;
  }

  get topReferrer() {
    return this.data?.traffic_sources?.[0] ?? null;
  }

  get topTopic() {
    return this.data?.top_topics?.[0] ?? null;
  }

  get decliningCategories() {
    return (this.data?.categories ?? []).filter((c) => c.trend_pct < -3);
  }

  get contentGaps() {
    return (this.data?.search_terms ?? []).filter((s) => s.content_gap);
  }

  get decliningCategoryNames() {
    return this.decliningCategories.map((c) => c.name).join(", ");
  }

  get contentGapTerms() {
    return this.contentGaps.map((g) => `"${g.term}"`).join(", ");
  }

  get expandedMetricData() {
    if (!this.expandedMetric || !this.data?.metrics) {
      return null;
    }
    return this.data.metrics[this.expandedMetric];
  }

  get expandedMetricTitle() {
    if (!this.expandedMetric) {
      return "";
    }
    return i18n(`discourse_insights.metrics.${this.expandedMetric}`);
  }

  get sparklinePath() {
    const daily = this.expandedMetricData?.daily;
    if (!daily?.length) {
      return null;
    }
    const values = daily.map((d) => d.value);
    const max = Math.max(...values, 1);
    const w = 300;
    const h = 60;
    const pad = 2;
    const stepX = values.length > 1 ? w / (values.length - 1) : 0;

    const points = values.map((v, i) => {
      const x = i * stepX;
      const y = pad + (h - 2 * pad) * (1 - v / max);
      return `${x},${y}`;
    });

    return htmlSafe(
      `M${points.join(" L")}`
    );
  }

  get sparklineFillPath() {
    const daily = this.expandedMetricData?.daily;
    if (!daily?.length) {
      return null;
    }
    const values = daily.map((d) => d.value);
    const max = Math.max(...values, 1);
    const w = 300;
    const h = 60;
    const pad = 2;
    const stepX = values.length > 1 ? w / (values.length - 1) : 0;

    const points = values.map((v, i) => {
      const x = i * stepX;
      const y = pad + (h - 2 * pad) * (1 - v / max);
      return `${x},${y}`;
    });

    return htmlSafe(
      `M0,${h} L${points.join(" L")} L${w},${h} Z`
    );
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
      trendText: formatTrendText(cat.trend_pct, false),
      trendClass: trendCssClass(cat.trend_pct),
    }));
  }

  get questions() {
    return [
      {
        key: "categories",
        label: i18n("discourse_insights.questions.categories"),
      },
      {
        key: "content",
        label: i18n("discourse_insights.questions.content"),
      },
      {
        key: "deflection",
        label: i18n("discourse_insights.questions.deflection"),
      },
      {
        key: "stakeholder",
        label: i18n("discourse_insights.questions.stakeholder"),
      },
    ];
  }

  get questionAnswer() {
    if (!this.expandedQuestion || !this.data) {
      return null;
    }

    switch (this.expandedQuestion) {
      case "categories": {
        const declining = this.decliningCategories;
        if (declining.length === 0) {
          return i18n("discourse_insights.answers.categories_healthy");
        }
        return i18n("discourse_insights.answers.categories_declining", {
          names: this.decliningCategoryNames,
        });
      }
      case "content": {
        const gaps = this.contentGaps;
        if (gaps.length === 0) {
          return i18n("discourse_insights.answers.content_no_gaps");
        }
        return i18n("discourse_insights.answers.content_gaps", {
          terms: this.contentGapTerms,
        });
      }
      case "deflection": {
        const solved = this.data.metrics?.solved;
        if (!solved || solved.available === false) {
          return i18n("discourse_insights.answers.deflection_unavailable");
        }
        return i18n("discourse_insights.answers.deflection", {
          solved: solved.current,
          solve_rate: solved.solve_rate ?? 0,
          response_rate: this.data.metrics?.response_rate?.current ?? 0,
          avg_hours:
            this.data.metrics?.response_rate?.avg_first_response_hours ?? 0,
        });
      }
      case "stakeholder":
        return i18n("discourse_insights.answers.stakeholder", {
          visitors: this.data.metrics?.visitors?.current ?? 0,
          visitors_trend: this.data.metrics?.visitors?.trend_pct ?? 0,
          members: this.data.metrics?.new_members?.current ?? 0,
          members_trend: this.data.metrics?.new_members?.trend_pct ?? 0,
          posts: this.data.metrics?.posts?.current ?? 0,
          response_rate: this.data.metrics?.response_rate?.current ?? 0,
        });
      default:
        return null;
    }
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

  @action
  async changePeriod(periodId) {
    if (this.period === periodId && !this.isCustomPeriod) {
      return;
    }
    this.period = periodId;
    this.customStartDate = null;
    this.customEndDate = null;
    this.loading = true;
    this.expandedMetric = null;
    this.expandedQuestion = null;
    this.aiSummary = "";
    this.aiSummaryDone = false;
    this.aiAnswer = "";
    this.aiAnswerDone = false;
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
    this.expandedMetric = null;
    this.expandedQuestion = null;
    this.aiSummary = "";
    this.aiSummaryDone = false;
    this.aiAnswer = "";
    this.aiAnswerDone = false;
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
    this.expandedMetric = null;
    this.expandedQuestion = null;
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

  @action
  toggleMetric(key) {
    this.expandedMetric = this.expandedMetric === key ? null : key;
  }

  @action
  closeMetric() {
    this.expandedMetric = null;
  }

  @action
  toggleQuestion(key) {
    if (this.expandedQuestion === key) {
      this.expandedQuestion = null;
      return;
    }
    this.expandedQuestion = key;
    if (this.aiAvailable) {
      this.triggerAiAnswer(key);
    }
  }

  @action
  submitCustomQuestion(event) {
    event.preventDefault();
    const q = this.customQuestion.trim();
    if (!q || !this.aiAvailable) {
      return;
    }
    this.expandedQuestion = "custom";
    this.triggerAiAnswer("custom", q);
  }

  @action
  updateCustomQuestion(event) {
    this.customQuestion = event.target.value;
  }

  @action
  toggleExplore(key) {
    this.expandedSections = {
      ...this.expandedSections,
      [key]: !this.expandedSections[key],
    };
  }

  // ai methods

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

    this._aiSummaryTimer = later(
      this,
      () => {
        if (!this.aiSummaryDone && this.aiSummary.length === 0) {
          this.aiSummaryLoading = false;
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
    this.aiAnswerType = type;

    this._aiAnswerTimer = later(
      this,
      () => {
        if (!this.aiAnswerDone && this.aiAnswer.length === 0) {
          this.aiAnswerLoading = false;
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

  <template>
    <div
      class="insights"
      {{didInsert this.subscribeAi}}
      {{willDestroy this.unsubscribeAi}}
    >
      <div class="insights-header">
        <h2 class="insights-header__title">{{i18n
            "discourse_insights.title"
          }}</h2>
        <div class="insights-header__controls">
          {{#each this.periodOptions as |opt|}}
            <DButton
              class={{if
                (eq this.period opt.id)
                "btn-primary insights-period-btn"
                "btn-default insights-period-btn"
              }}
              @action={{fn this.changePeriod opt.id}}
              @translatedLabel={{opt.label}}
            />
          {{/each}}
          <DButton
            class={{if
              this.isCustomPeriod
              "btn-primary insights-period-btn"
              "btn-default insights-period-btn"
            }}
            @action={{this.openCustomDateRange}}
            @icon="calendar-days"
            @translatedLabel={{if
              this.isCustomPeriod
              this.customDateLabel
              (i18n "discourse_insights.periods.custom")
            }}
          />
          <DButton
            class="btn-default btn-small btn-icon no-text insights-refresh-btn"
            @action={{this.refresh}}
            @icon="arrows-rotate"
            @title="discourse_insights.refresh_tooltip"
            @disabled={{this.loading}}
          />
        </div>
      </div>

      {{#if this.loading}}
        <div class="insights-loading">
          <div class="spinner medium"></div>
        </div>
      {{else if this.data.error}}
        <div class="insights-error">
          {{i18n "discourse_insights.error"}}
        </div>
      {{else}}
        <div class="insights-summary">
          <div class="insights-summary__header">
            <span class="insights-summary__icon">✦</span>
            <span class="insights-summary__title">{{i18n
                "discourse_insights.insights.title"
              }}</span>
          </div>

          {{#if this.aiSummaryLoading}}
            <div class="insights-ai-loading">
              <span class="insights-ai-loading__dots">
                <span></span><span></span><span></span>
              </span>
            </div>
          {{else if this.aiSummary}}
            <div class="insights-ai-narrative">
              <CookText @rawText={{this.aiSummary}} />
            </div>
          {{else}}
            <p class="insights-summary__narrative">
              {{#if this.isGrowing}}
                {{i18n
                  "discourse_insights.insights.growing"
                  visitors_trend=this.absVisitorsTrend
                  members_count=this.membersCount
                  members_trend=this.membersTrend
                }}
              {{else if this.isDeclining}}
                {{i18n
                  "discourse_insights.insights.declining"
                  visitors_trend=this.absVisitorsTrend
                }}
              {{else}}
                {{i18n
                  "discourse_insights.insights.steady"
                  visitors=this.visitorsCount
                  members_count=this.membersCount
                }}
              {{/if}}
              {{#if this.topReferrer}}

                {{i18n
                  "discourse_insights.insights.top_referrer"
                  domain=this.topReferrer.domain
                  clicks=this.topReferrer.clicks
                }}
              {{/if}}
              {{#if this.topTopic}}

                {{i18n
                  "discourse_insights.insights.top_topic"
                  title=this.topTopic.title
                  views=this.topTopic.views
                }}
              {{/if}}
            </p>
          {{/if}}

          <div class="insights-metrics">
            {{#each this.metrics as |metric|}}
              <button
                type="button"
                class="insights-metric
                  {{if
                    (eq this.expandedMetric metric.key)
                    'insights-metric--active'
                  }}"
                {{on "click" (fn this.toggleMetric metric.key)}}
              >
                <span class="insights-metric__label">{{metric.label}}</span>
                <span class="insights-metric__value">
                  {{#if metric.isPercentage}}
                    {{metric.current}}%
                  {{else}}
                    {{number metric.current}}
                  {{/if}}
                </span>
                <span
                  class="insights-metric__trend {{metric.trendClass}}"
                >{{metric.trendText}}</span>
              </button>
            {{/each}}
            {{#if this.comparisonLabel}}
              <span class="insights-metrics__compare">{{i18n
                  "discourse_insights.compare_to"
                  dates=this.comparisonLabel
                }}</span>
            {{/if}}
          </div>

          {{#if this.expandedMetricData}}
            <div class="insights-detail-panel">
              <div class="insights-detail-panel__header">
                <span
                  class="insights-detail-panel__title"
                >{{this.expandedMetricTitle}}</span>
                <DButton
                  class="btn-transparent insights-detail-panel__close"
                  @action={{this.closeMetric}}
                  @icon="xmark"
                />
              </div>
              <div class="insights-detail-panel__body">
                {{#if this.sparklinePath}}
                  <svg
                    class="insights-sparkline"
                    viewBox="0 0 300 60"
                    preserveAspectRatio="none"
                  >
                    <path
                      class="insights-sparkline__fill"
                      d={{this.sparklineFillPath}}
                    />
                    <path
                      class="insights-sparkline__line"
                      d={{this.sparklinePath}}
                    />
                  </svg>
                {{/if}}

                <div class="insights-detail-panel__stats">
                  <span class="insights-detail-panel__stat">
                    {{i18n "discourse_insights.detail.current"}}
                    <strong>{{number this.expandedMetricData.current}}</strong>
                  </span>
                  <span class="insights-detail-panel__stat">
                    {{i18n "discourse_insights.detail.previous"}}
                    <strong>{{number this.expandedMetricData.previous}}</strong>
                  </span>
                  {{#if this.expandedMetricData.avg_per_day}}
                    <span class="insights-detail-panel__stat">
                      {{i18n "discourse_insights.detail.avg_per_day"}}
                      <strong>{{number
                          this.expandedMetricData.avg_per_day
                        }}</strong>
                    </span>
                  {{/if}}
                  {{#if this.expandedMetricData.like_to_post_ratio}}
                    <span class="insights-detail-panel__stat">
                      {{i18n "discourse_insights.detail.like_ratio"}}
                      <strong
                      >{{this.expandedMetricData.like_to_post_ratio}}</strong>
                    </span>
                  {{/if}}
                  {{#if this.expandedMetricData.avg_first_response_hours}}
                    <span class="insights-detail-panel__stat">
                      {{i18n "discourse_insights.detail.avg_response_time"}}
                      <strong
                      >{{this.expandedMetricData.avg_first_response_hours}}h</strong>
                    </span>
                  {{/if}}
                  {{#if this.expandedMetricData.unanswered_count}}
                    <span class="insights-detail-panel__stat">
                      {{i18n "discourse_insights.detail.unanswered"}}
                      <strong
                      >{{this.expandedMetricData.unanswered_count}}</strong>
                    </span>
                  {{/if}}
                  {{#if this.expandedMetricData.solve_rate}}
                    <span class="insights-detail-panel__stat">
                      {{i18n "discourse_insights.detail.solve_rate"}}
                      <strong>{{this.expandedMetricData.solve_rate}}%</strong>
                    </span>
                  {{/if}}
                </div>

                {{#if (eq this.expandedMetric "contributors")}}
                  <div class="insights-detail-panel__extra">
                    <span>{{i18n "discourse_insights.detail.dau"}}
                      {{this.data.dau_wau_mau.dau}}</span>
                    <span>{{i18n "discourse_insights.detail.wau"}}
                      {{this.data.dau_wau_mau.wau}}</span>
                    <span>{{i18n "discourse_insights.detail.mau"}}
                      {{this.data.dau_wau_mau.mau}}</span>
                    <span>{{i18n "discourse_insights.detail.dau_mau"}}
                      {{this.data.dau_wau_mau.dau_mau_ratio}}%</span>
                  </div>
                {{/if}}

                {{#if (eq this.expandedMetric "posts")}}
                  <div class="insights-detail-panel__extra">
                    <span>{{i18n "discourse_insights.detail.new_topics"}}:
                      {{this.data.posts_breakdown.topics}}</span>
                    <span>{{i18n "discourse_insights.detail.replies"}}:
                      {{this.data.posts_breakdown.replies}}</span>
                  </div>
                {{/if}}
              </div>
            </div>
          {{/if}}

          <div class="insights-questions">
            {{#each this.questions as |q|}}
              <button
                type="button"
                class="insights-question-chip
                  {{if
                    (eq this.expandedQuestion q.key)
                    'insights-question-chip--active'
                  }}"
                {{on "click" (fn this.toggleQuestion q.key)}}
              >
                {{q.label}}
              </button>
            {{/each}}
          </div>

          {{#if this.aiAvailable}}
            <form
              class="insights-ask"
              {{on "submit" this.submitCustomQuestion}}
            >
              <input
                type="text"
                class="insights-ask__input"
                placeholder={{i18n
                  "discourse_insights.questions.custom_placeholder"
                }}
                value={{this.customQuestion}}
                {{on "input" this.updateCustomQuestion}}
              />
            </form>
          {{/if}}

          {{#if this.expandedQuestion}}
            <div class="insights-answer">
              {{#if this.aiAnswerLoading}}
                <div class="insights-ai-loading">
                  <span class="insights-ai-loading__dots">
                    <span></span><span></span><span></span>
                  </span>
                </div>
              {{else if this.aiAnswer}}
                <div class="insights-ai-answer">
                  <CookText @rawText={{this.aiAnswer}} />
                </div>
              {{else if this.questionAnswer}}
                <div class="insights-answer__text">{{this.questionAnswer}}</div>
              {{/if}}
            </div>
          {{/if}}
        </div>

        {{! My Reports }}
        {{#unless this.reportsLoading}}
          {{#if this.reports.length}}
            <div class="insights-explore">
              <button
                type="button"
                class="insights-explore__toggle
                  {{if this.isReportsExpanded 'insights-explore__toggle--open'}}"
                aria-expanded={{if this.isReportsExpanded "true" "false"}}
                {{on "click" (fn this.toggleExplore "reports")}}
              >
                <span class="insights-explore__icon">›</span>
                <span class="insights-explore__title">
                  {{i18n "discourse_insights.reports.title"}}
                  <DTooltip
                    class="insights-reports-info"
                    @icon="circle-info"
                    @content={{i18n "discourse_insights.reports.personal_hint"}}
                  />
                </span>
                <span class="insights-explore__summary">{{i18n
                    "discourse_insights.reports.summary"
                  }}</span>
              </button>
              {{#if this.isReportsExpanded}}
                <div
                  class="insights-explore__body insights-explore__body--reports"
                >
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
                    + {{i18n "discourse_insights.reports.add_report"}}
                  </button>
                </div>
              {{/if}}
            </div>
          {{/if}}
        {{/unless}}

        {{! Explore: Content Performance }}
        <div class="insights-explore">
          <button
            type="button"
            class="insights-explore__toggle
              {{if this.isContentExpanded 'insights-explore__toggle--open'}}"
            aria-expanded={{if this.isContentExpanded "true" "false"}}
            {{on "click" (fn this.toggleExplore "content")}}
          >
            <span class="insights-explore__icon">›</span>
            <span class="insights-explore__title">{{i18n
                "discourse_insights.explore.content"
              }}</span>
            <span class="insights-explore__summary">{{i18n
                "discourse_insights.explore.content_summary"
              }}</span>
          </button>
          {{#if this.isContentExpanded}}
            <div class="insights-explore__body insights-explore__body--grid-2">
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
            </div>
          {{/if}}
        </div>

        {{! Explore: Traffic Sources }}
        <div class="insights-explore">
          <button
            type="button"
            class="insights-explore__toggle
              {{if this.isTrafficExpanded 'insights-explore__toggle--open'}}"
            aria-expanded={{if this.isTrafficExpanded "true" "false"}}
            {{on "click" (fn this.toggleExplore "traffic")}}
          >
            <span class="insights-explore__icon">›</span>
            <span class="insights-explore__title">{{i18n
                "discourse_insights.explore.traffic"
              }}</span>
            <span class="insights-explore__summary">{{i18n
                "discourse_insights.explore.traffic_summary"
              }}</span>
          </button>
          {{#if this.isTrafficExpanded}}
            <div class="insights-explore__body">
              {{#if this.geoBreakdown.length}}
                <div class="insights-card insights-card--full">
                  <div class="insights-card__title">{{i18n
                      "discourse_insights.explore.geography"
                    }}</div>
                  <InsightsGeoMap @data={{this.geoBreakdown}} />
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
            </div>
          {{/if}}
        </div>

        {{! Explore: Categories }}
        <div class="insights-explore">
          <button
            type="button"
            class="insights-explore__toggle
              {{if this.isCategoriesExpanded 'insights-explore__toggle--open'}}"
            aria-expanded={{if this.isCategoriesExpanded "true" "false"}}
            {{on "click" (fn this.toggleExplore "categories")}}
          >
            <span class="insights-explore__icon">›</span>
            <span class="insights-explore__title">{{i18n
                "discourse_insights.explore.categories"
              }}</span>
            <span class="insights-explore__summary">{{i18n
                "discourse_insights.explore.categories_summary"
              }}</span>
          </button>
          {{#if this.isCategoriesExpanded}}
            <div class="insights-explore__body">
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
            </div>
          {{/if}}
        </div>
      {{/if}}
    </div>
  </template>
}
